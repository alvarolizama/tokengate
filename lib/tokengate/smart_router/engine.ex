defmodule Tokengate.SmartRouter.Engine do
  @moduledoc """
  The layered decision engine behind `Tokengate.SmartRouter.decide/3`.

  It is pure with respect to the database: everything it needs is in the
  `snapshot` (config, use cases with their destinations, rules, fallback
  models). The only side effects are the two ETS caches — the session pin and
  the decision cache — and both are skipped by `dry_run`.

  ## Layers

    * **Layer 0 — session pin / tool loop.** A conversation that already has a
      live pin keeps its model, and a capability upgrade (the conversation now
      needs tools/vision/structured output that the pinned destination does not
      declare) breaks the pin instead of serving a request that would fail.
    * **Layer 1 — deterministic.** Capability and context-window pre-filters,
      `router_rules`, `fast_path` (a trivial prompt never pays for a
      classifier), and the single-viable-use-case shortcut.
    * **Layer 2 — classifier.** Only when two or more viable use cases remain,
      `decision_model_id` is set and no rule/pin/fast path answered first. See
      `Tokengate.SmartRouter.Classifier`.
    * **Layer 3 — ranking.** Cheapest healthy destination in the winning effort
      tier; `critical_accuracy` (or a `quality_first` policy) inverts the
      tie-break towards the potent tier. A classifier confidence below a
      destination's `min_confidence` escalates **up**, never down.

  ## Fallback chain

      same tier (cheapest first) -> more potent tier(s)
      -> less potent tier(s) ONLY if use_case.allow_downgrade
      -> use_case.fallback_model_id -> router_configs.default_model_id

  Every entry is deduplicated by model id: the same model may be bound twice
  under different tiers, and a fallback chain that repeats it wastes attempts.

  ## Metadata

  `decision_meta` is the billing/observability contract for S3: `source`,
  `classifier`, `confidence`, `cache_hit`, `latency_ms`, `classifier_ms`,
  `usage`, `model_id`, `rules`, `fallback_reason`, `escalated` and `timeout`.
  The decision's own cost is deliberately `nil`: S3 prices it with
  `CostCalculator` from the usage we return, outside the request budget.

  A session-pinned decision returns `fallbacks: []` on purpose: leaving the
  pinned model is exactly what the pin exists to prevent, and the upstream retry
  matrix can still rotate lanes **for the same model** without breaking the
  conversation's cache affinity.
  """

  alias Tokengate.Proxy.SessionId
  alias Tokengate.SmartRouter.{Classifier, CostRanker, DecisionCache, RuleEvaluator, SessionPin}

  @tier_any "any"
  @tiers ~w(low medium high)

  @spec decide(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, atom() | tuple()}
  def decide(snapshot, payload, context \\ %{}, opts \\ []) do
    started = System.monotonic_time(:millisecond)
    config = Map.get(snapshot, :config)

    if enabled?(config) do
      analysis = Tokengate.SmartRouter.RequestAnalyzer.analyze(payload, context)
      opts = merge_context(opts, context)
      resolve(snapshot, payload, analysis, opts, started)
    else
      {:error, :router_disabled}
    end
  end

  # ---------------------------------------------------------------------------
  # Layer 0 — session pin / tool loop
  # ---------------------------------------------------------------------------

  defp resolve(snapshot, payload, analysis, opts, started) do
    config = Map.get(snapshot, :config)
    dry_run? = Keyword.get(opts, :dry_run, false)

    session_key =
      Keyword.get(opts, :session_key) ||
        SessionId.derive(payload, Keyword.get(opts, :session_http))

    subject_id = Keyword.get(opts, :subject_id)

    case pinned_decision(snapshot, analysis, opts, session_key, subject_id, dry_run?) do
      {:ok, decision} ->
        {:ok, decision}

      :none ->
        layers(snapshot, config, analysis, opts, session_key, subject_id, dry_run?, started)
    end
  end

  defp pinned_decision(snapshot, analysis, opts, session_key, subject_id, dry_run?) do
    config = Map.get(snapshot, :config)
    ttl_ms = sticky_ttl_ms(config)

    # `lock_tool_loops: false` lets the operator re-decide mid-loop; the default
    # (`true`) keeps the pin authoritative for the duration of the loop.
    lock_tool_loops? = field(config, :lock_tool_loops) != false
    redecide_loop? = analysis.tool_loop and not lock_tool_loops?

    with false <- redecide_loop?,
         true <- is_binary(subject_id) and is_binary(session_key) and ttl_ms > 0,
         %{} = pin <- SessionPin.get(subject_id, session_key) do
      case compatible_pin(snapshot, pin, analysis) do
        {:ok, {use_case, candidate}} ->
          [candidate | _] =
            CostRanker.rank([candidate], analysis, health_fun: health_fun(opts))

          {:ok,
           decision(
             use_case,
             candidate,
             [],
             %{
               source: "session_pin",
               classifier: false,
               confidence: nil,
               cache_hit: false,
               latency_ms: 0,
               classifier_ms: nil,
               usage: nil,
               model_id: nil,
               rules: [],
               fallback_reason: nil,
               escalated: false,
               timeout: false,
               pinned: true,
               dry_run: dry_run?
             },
             field(candidate, :effort_tier)
           )}

        :capability_upgrade ->
          unless dry_run?, do: SessionPin.clear(subject_id, session_key)
          :none

        :stale ->
          :none
      end
    else
      _ -> :none
    end
  end

  # The upgrade is judged against the CANDIDATE's declared capabilities, not
  # against what the pin recorded when it was created: a conversation that
  # starts as plain text on a model that also does tools/vision must keep its
  # pin when the next turn adds an image or a tool call. Only a candidate that
  # genuinely cannot serve the new shape breaks the pin.
  defp compatible_pin(snapshot, pin, analysis) do
    with %{} = use_case <- find_use_case(snapshot, field(pin, :use_case_id)),
         true <- field(use_case, :pin_session) == true,
         %{} = candidate <-
           find_candidate(use_case, field(pin, :model_id), analysis) do
      upgrades =
        [
          analysis.has_tools and field(candidate, :supports_tools) != true,
          analysis.has_vision and field(candidate, :supports_vision) != true,
          analysis.has_structured_output and field(candidate, :supports_structured_output) != true
        ]

      if Enum.any?(upgrades, &(&1 == true)) do
        :capability_upgrade
      else
        {:ok, {use_case, candidate}}
      end
    else
      _ -> :stale
    end
  end

  # ---------------------------------------------------------------------------
  # Layer 1 — deterministic filters and rules
  # ---------------------------------------------------------------------------

  defp layers(snapshot, config, analysis, opts, session_key, subject_id, dry_run?, started) do
    rules = RuleEvaluator.evaluate(Map.get(snapshot, :rules, []), analysis)
    viable = viable_use_cases(Map.get(snapshot, :use_cases, []), analysis, opts)

    if viable == [] do
      {:error, :no_candidates}
    else
      {viable, force_ignored} = apply_force(viable, rules)
      {viable, restriction_ignored} = apply_restriction(viable, rules)

      cond do
        rules.force != nil and not force_ignored ->
          finish(
            snapshot,
            config,
            analysis,
            opts,
            [List.first(viable)],
            rules,
            "rule",
            session_key,
            subject_id,
            dry_run?,
            started,
            nil,
            nil
          )

        fast_path?(config, analysis) ->
          fast_path_decision(
            snapshot,
            config,
            analysis,
            opts,
            viable,
            rules,
            session_key,
            subject_id,
            dry_run?,
            started
          )

        length(viable) == 1 ->
          finish(
            snapshot,
            config,
            analysis,
            opts,
            viable,
            rules,
            if(rules.force, do: "rule", else: "single_candidate"),
            session_key,
            subject_id,
            dry_run?,
            started,
            nil,
            if(restriction_ignored, do: "restriction_left_no_candidates", else: nil)
          )

        true ->
          classify(
            snapshot,
            config,
            analysis,
            opts,
            viable,
            rules,
            session_key,
            subject_id,
            dry_run?,
            started
          )
      end
    end
  end

  defp viable_use_cases(use_cases, analysis, _opts) do
    use_cases
    |> Enum.filter(&(field(&1, :enabled) != false))
    |> Enum.map(fn use_case -> {use_case, eligible_candidates(use_case, analysis)} end)
    |> Enum.reject(fn {_use_case, candidates} -> candidates == [] end)
    |> Enum.sort_by(fn {use_case, _candidates} -> field(use_case, :priority) || 100 end)
  end

  defp eligible_candidates(use_case, analysis) do
    use_case
    |> candidates()
    |> Enum.filter(fn candidate ->
      field(candidate, :enabled) != false and
        capability_ok?(use_case, candidate, analysis) and
        context_window_ok?(candidate, analysis)
    end)
  end

  # A destination must serve BOTH what the use case requires and what THIS
  # request carries: a use case that does not require tools still cannot be
  # routed to a tool-blind model when the payload brings a `tools` array (the
  # upstream would 400), and the same holds for images and structured output.
  defp capability_ok?(use_case, candidate, analysis) do
    requires_tools? = field(use_case, :requires_tools) == true or analysis.has_tools == true
    requires_vision? = field(use_case, :requires_vision) == true or analysis.has_vision == true

    requires_structured? =
      field(use_case, :requires_structured_output) == true or
        analysis.has_structured_output == true

    (not requires_tools? or field(candidate, :supports_tools) == true) and
      (not requires_vision? or field(candidate, :supports_vision) == true) and
      (not requires_structured? or field(candidate, :supports_structured_output) == true)
  end

  defp context_window_ok?(candidate, analysis) do
    case field(candidate, :context_window) do
      window when is_integer(window) ->
        window >= analysis.prompt_tokens + analysis.estimated_output_tokens

      _ ->
        true
    end
  end

  defp apply_force(viable, rules) do
    case rules.force do
      nil ->
        {viable, false}

      key ->
        case Enum.find(viable, fn {use_case, _} -> field(use_case, :key) == key end) do
          nil -> {viable, true}
          forced -> {[forced], false}
        end
    end
  end

  defp apply_restriction(viable, rules) do
    case rules.restrict do
      nil ->
        {viable, false}

      keys ->
        restricted = Enum.filter(viable, fn {use_case, _} -> field(use_case, :key) in keys end)

        if restricted == [], do: {viable, true}, else: {restricted, false}
    end
  end

  defp fast_path?(config, analysis) do
    max = field(config, :fast_path_max_tokens)

    is_integer(max) and max > 0 and analysis.prompt_tokens <= max and
      not analysis.has_tools and not analysis.tool_loop and
      not analysis.has_vision and not analysis.has_structured_output
  end

  defp fast_path_decision(
         snapshot,
         config,
         analysis,
         opts,
         viable,
         rules,
         session_key,
         subject_id,
         dry_run?,
         started
       ) do
    preferred =
      Enum.find(viable, fn {use_case, _} -> field(use_case, :key) == "fast" end) ||
        Enum.min_by(viable, fn {use_case, candidates} ->
          {best_cost(candidates, analysis, opts), field(use_case, :priority) || 100}
        end)

    {use_case, candidates} = preferred

    finish(
      snapshot,
      config,
      analysis,
      opts,
      [{use_case, candidates} | viable -- [preferred]],
      rules,
      "fast_path",
      session_key,
      subject_id,
      dry_run?,
      started,
      nil,
      nil
    )
  end

  defp best_cost(candidates, analysis, opts) do
    candidates
    |> CostRanker.rank(analysis, health_fun: health_fun(opts))
    |> List.first()
    |> cost_sort_value()
  end

  # ---------------------------------------------------------------------------
  # Layer 2 — classifier
  # ---------------------------------------------------------------------------

  defp classify(
         snapshot,
         config,
         analysis,
         opts,
         viable,
         rules,
         session_key,
         subject_id,
         dry_run?,
         started
       ) do
    decision_model = Map.get(snapshot, :decision_model)

    if is_map(decision_model) and map_size(decision_model) > 0 do
      {result, cache_hit} =
        ask_classifier(config, analysis, opts, viable, decision_model, dry_run?)

      case result do
        {:ok, answer} ->
          case Enum.find(viable, fn {use_case, _} ->
                 field(use_case, :key) == Map.get(answer, :use_case_key)
               end) do
            nil ->
              deterministic(
                snapshot,
                config,
                analysis,
                opts,
                viable,
                rules,
                session_key,
                subject_id,
                dry_run?,
                started,
                :unknown_use_case
              )

            chosen ->
              finish(
                snapshot,
                config,
                analysis,
                opts,
                [chosen],
                rules,
                if(cache_hit, do: "decision_cache", else: "classifier"),
                session_key,
                subject_id,
                dry_run?,
                started,
                answer,
                nil
              )
          end

        {:error, reason} ->
          deterministic(
            snapshot,
            config,
            analysis,
            opts,
            viable,
            rules,
            session_key,
            subject_id,
            dry_run?,
            started,
            reason
          )
      end
    else
      deterministic(
        snapshot,
        config,
        analysis,
        opts,
        viable,
        rules,
        session_key,
        subject_id,
        dry_run?,
        started,
        :classifier_disabled
      )
    end
  end

  defp ask_classifier(config, analysis, opts, viable, decision_model, dry_run?) do
    key = cache_key(config, analysis, viable)

    case if(dry_run?, do: nil, else: DecisionCache.get(key)) do
      %{} = hit ->
        {{:ok, hit}, true}

      _ ->
        use_cases = Enum.map(viable, fn {use_case, _candidates} -> use_case end)

        classifier_fun =
          Keyword.get(opts, :classifier_fun, fn model, analysis, use_cases ->
            Classifier.classify(model, analysis, use_cases, classifier_opts(config, opts))
          end)

        result = normalize_result(classifier_fun.(decision_model, analysis, use_cases))

        with {:ok, answer} <- result, false <- dry_run? do
          DecisionCache.put(key, answer)
          {result, false}
        else
          {:error, _} -> {result, false}
          true -> {result, false}
        end
    end
  end

  defp normalize_result({:ok, %{} = answer}), do: {:ok, answer}
  defp normalize_result({:error, reason}), do: {:error, reason}

  defp normalize_result(answer) do
    if is_map(answer) and Map.get(answer, :use_case_key) do
      {:ok, answer}
    else
      {:error, {:invalid_classifier_result, answer}}
    end
  end

  defp classifier_opts(config, opts) do
    [
      timeout_ms: field(config, :decision_timeout_ms) || 800,
      context_chars: field(config, :decision_context_chars) || 1_200,
      post_fun: Keyword.get(opts, :post_fun),
      lane_fun: Keyword.get(opts, :lane_fun),
      task_supervisor: Keyword.get(opts, :task_supervisor),
      outcome_fun: Keyword.get(opts, :outcome_fun)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp cache_key(config, analysis, viable) do
    DecisionCache.fingerprint({
      Enum.map(viable, fn {use_case, _} -> field(use_case, :key) end),
      analysis.effort,
      analysis.has_tools,
      analysis.has_vision,
      analysis.has_structured_output,
      String.slice(
        analysis.last_user_message || "",
        0,
        field(config, :decision_context_chars) || 1_200
      )
    })
  end

  defp deterministic(
         snapshot,
         config,
         analysis,
         opts,
         viable,
         rules,
         session_key,
         subject_id,
         dry_run?,
         started,
         reason
       ) do
    {use_case, candidates} =
      Enum.min_by(viable, fn {use_case, candidates} ->
        {best_cost(candidates, analysis, opts), field(use_case, :priority) || 100}
      end)

    finish(
      snapshot,
      config,
      analysis,
      opts,
      [{use_case, candidates} | viable -- [{use_case, candidates}]],
      rules,
      fallback_source(reason),
      session_key,
      subject_id,
      dry_run?,
      started,
      nil,
      reason
    )
  end

  # A classifier that timed out is billed differently from one that answered
  # with garbage: S3 reads `source` to know what happened. `:classifier_disabled`
  # is not a failure at all — the operator simply runs without a decision model.
  defp fallback_source(:timeout), do: "fallback_timeout"
  defp fallback_source(:classifier_disabled), do: "deterministic"
  defp fallback_source(_reason), do: "fallback_error"

  # ---------------------------------------------------------------------------
  # Layer 3 — ranking and the fallback chain
  # ---------------------------------------------------------------------------

  defp finish(
         snapshot,
         config,
         analysis,
         opts,
         viable,
         rules,
         source,
         session_key,
         subject_id,
         dry_run?,
         started,
         classifier_answer,
         fallback_reason
       ) do
    {use_case, candidates} = List.first(viable)

    target_tier = target_tier(analysis, classifier_answer)
    confidence = classifier_answer && Map.get(classifier_answer, :confidence)
    mode = ranking_mode(use_case, config)
    health = health_fun(opts)
    # Only a classifier-sourced answer was actually paid for; a cache hit or a
    # deterministic decision must not report a classifier call's usage/ms.
    classifier? = source == "classifier"

    ranked = CostRanker.rank(candidates, analysis, mode: mode, health_fun: health)

    case choose_primary(ranked, target_tier, confidence) do
      {:ok, primary} ->
        primary = Map.put(primary, :confidence, confidence)

        fallbacks =
          fallback_chain(
            snapshot,
            use_case,
            candidates,
            primary,
            analysis,
            target_tier,
            confidence,
            mode,
            health
          )

        decision =
          decision(
            use_case,
            primary,
            fallbacks,
            %{
              source: source,
              classifier: classifier?,
              confidence: confidence,
              cache_hit: source == "decision_cache",
              latency_ms: System.monotonic_time(:millisecond) - started,
              classifier_ms: if(classifier?, do: Map.get(classifier_answer || %{}, :latency_ms)),
              usage: if(classifier?, do: Map.get(classifier_answer || %{}, :usage)),
              model_id: classifier_answer && Map.get(classifier_answer, :model_id),
              rules: rules.matched,
              fallback_reason: fallback_reason,
              escalated: primary.escalated,
              timeout: match?(:timeout, fallback_reason),
              tier_substituted: primary.tier_substituted,
              pinned: false,
              dry_run: dry_run?
            },
            target_tier
          )

        persist_pin(use_case, primary, analysis, session_key, subject_id, config, dry_run?)
        {:ok, decision}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp target_tier(_analysis, %{effort: effort}) when effort in @tiers, do: effort
  defp target_tier(analysis, _answer), do: analysis.effort

  defp ranking_mode(use_case, config) do
    if field(use_case, :critical_accuracy) == true or field(config, :policy) == "quality_first",
      do: :potency,
      else: :cost
  end

  defp choose_primary(ranked, target, confidence) do
    floor_ok? = fn candidate -> meets_floor?(candidate, confidence) end
    # A healthy destination always wins over a degraded one, whatever the tier:
    # escalating onto a circuit-open lane is not an escalation, it is a failed
    # request with extra steps.
    healthy_first = Enum.sort_by(ranked, &healthy_rank/1)

    case target do
      nil ->
        case Enum.find(healthy_first, floor_ok?) do
          nil -> escalated(ranked)
          candidate -> {:ok, annotate_tier(candidate, false)}
        end

      tier ->
        exact = tier_group(healthy_first, tier)

        case Enum.find(exact, floor_ok?) do
          nil ->
            case next_tier(healthy_first, CostRanker.tiers_above(tier), floor_ok?) do
              {:ok, candidate} -> {:ok, annotate_tier(candidate, true)}
              :none -> escalate_or_pick(ranked, floor_ok?)
            end

          candidate ->
            {:ok, annotate_tier(candidate, false)}
        end
    end
  end

  defp escalate_or_pick(ranked, floor_ok?) do
    candidates =
      ranked
      |> Enum.sort_by(fn candidate ->
        {healthy_rank(candidate), -CostRanker.tier_rank(field(candidate, :effort_tier)),
         cost_sort_value(candidate)}
      end)
      |> Enum.filter(floor_ok?)

    case List.first(candidates) do
      nil -> escalated(ranked)
      candidate -> {:ok, annotate_tier(candidate, true)}
    end
  end

  defp tier_group(ranked, tier) do
    Enum.filter(ranked, fn candidate ->
      field(candidate, :effort_tier) in [tier, @tier_any]
    end)
  end

  defp next_tier(_ranked, [], _floor_ok?), do: :none

  defp next_tier(ranked, [tier | rest], floor_ok?) do
    case Enum.find(tier_group(ranked, tier), floor_ok?) do
      nil -> next_tier(ranked, rest, floor_ok?)
      candidate -> {:ok, candidate}
    end
  end

  # Confidence below every destination's floor: escalate as far as possible
  # (highest healthy tier first, cheapest inside it). Never silently downgrade.
  defp escalated(ranked) do
    candidates =
      Enum.sort_by(ranked, fn candidate ->
        {healthy_rank(candidate), -CostRanker.tier_rank(field(candidate, :effort_tier)),
         cost_sort_value(candidate)}
      end)

    case List.first(candidates) do
      nil -> {:error, :no_eligible_model}
      candidate -> {:ok, annotate_tier(candidate, true)}
    end
  end

  defp healthy_rank(candidate) do
    case field(candidate, :healthy) do
      false -> 1
      _ -> 0
    end
  end

  # `{priced?, cost}`: an unpriced destination sorts after every priced one
  # instead of looking like a free one (`{1, 0.0}` vs `{0, 1.5}`).
  defp cost_sort_value(nil), do: {1, 0.0}

  defp cost_sort_value(candidate) do
    case field(candidate, :cost) do
      nil -> {1, 0.0}
      %Decimal{} = cost -> {0, Decimal.to_float(cost)}
      cost when is_number(cost) -> {0, cost * 1.0}
      _ -> {1, 0.0}
    end
  end

  defp annotate_tier(candidate, substituted) do
    candidate
    |> Map.put(:tier_substituted, substituted)
    |> Map.put(:escalated, substituted)
  end

  defp meets_floor?(_candidate, nil), do: true

  defp meets_floor?(candidate, confidence) do
    case field(candidate, :min_confidence) do
      nil -> true
      min when is_number(min) -> confidence >= min
      %Decimal{} = min -> confidence >= Decimal.to_float(min)
      _ -> true
    end
  end

  defp fallback_chain(
         snapshot,
         use_case,
         candidates,
         primary,
         analysis,
         target_tier,
         confidence,
         mode,
         health
       ) do
    allowed? = fn candidate -> meets_floor?(candidate, confidence) end
    primary_model_id = field(primary, :model_id)

    rest =
      candidates
      |> Enum.reject(&(&1 == primary))
      |> Enum.reject(&(field(&1, :model_id) == primary_model_id))

    groups =
      case target_tier do
        nil ->
          [rest]

        tier ->
          above = CostRanker.tiers_above(tier)
          above = if mode == :potency, do: Enum.reverse(above), else: above

          [tier_group(rest, tier)] ++
            Enum.map(above, &tier_group(rest, &1)) ++
            if(field(use_case, :allow_downgrade) == true,
              do: Enum.map(CostRanker.tiers_below(tier), &tier_group(rest, &1)),
              else: []
            )
      end

    group_mode = if target_tier == nil, do: mode, else: :cost

    same_use_case =
      groups
      |> Enum.flat_map(fn group ->
        group
        |> CostRanker.rank(analysis, mode: group_mode, health_fun: health)
        |> Enum.filter(allowed?)
      end)
      |> Enum.reject(&(field(&1, :model_id) == primary_model_id))

    chain =
      same_use_case ++
        fallback_entries(snapshot, field(use_case, :fallback_model_id), analysis, health) ++
        fallback_entries(
          snapshot,
          field(Map.get(snapshot, :config), :default_model_id),
          analysis,
          health
        )

    chain
    |> Enum.reject(&(field(&1, :model_id) == primary_model_id))
    |> dedupe_by_model()
  end

  defp fallback_entries(_snapshot, nil, _analysis, _health), do: []

  defp fallback_entries(snapshot, model_id, analysis, health) do
    case Map.get(Map.get(snapshot, :models, %{}), model_id) do
      %{} = model ->
        [
          %{
            model_id: model_id,
            model_name: field(model, :name),
            context_window: field(model, :context_window),
            market_input_price_per_1m: field(model, :market_input_price_per_1m),
            market_output_price_per_1m: field(model, :market_output_price_per_1m),
            lanes: Map.get(model, :lanes, [])
          }
        ]
        |> CostRanker.rank(analysis, mode: :cost, health_fun: health)

      _ ->
        []
    end
  end

  defp dedupe_by_model(candidates) do
    candidates
    |> Enum.reduce({[], MapSet.new()}, fn candidate, {acc, seen} ->
      model_id = field(candidate, :model_id)

      if MapSet.member?(seen, model_id) do
        {acc, seen}
      else
        {[candidate | acc], MapSet.put(seen, model_id)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # ---------------------------------------------------------------------------
  # Shape
  # ---------------------------------------------------------------------------

  defp decision(use_case, primary, fallbacks, meta, effort) do
    %{
      use_case: %{
        id: field(use_case, :id),
        key: field(use_case, :key),
        name: field(use_case, :name),
        critical_accuracy: field(use_case, :critical_accuracy) == true,
        allow_downgrade: field(use_case, :allow_downgrade) == true,
        pin_session: field(use_case, :pin_session) == true,
        fallback_model_id: field(use_case, :fallback_model_id)
      },
      primary: entry(use_case, primary, effort, field(primary, :confidence)),
      fallbacks: Enum.map(fallbacks, &entry(use_case, &1, effort, nil)),
      prompt_policy: %{
        keep_last_n_images: field(use_case, :keep_last_n_images),
        max_history_turns: field(use_case, :max_history_turns),
        compact_json: field(use_case, :compact_json) == true,
        stale_tool_trim_threshold_pct: field(use_case, :stale_tool_trim_threshold_pct)
      },
      decision_meta: meta
    }
  end

  defp entry(use_case, candidate, effort, confidence) do
    %{
      use_case_id: field(candidate, :use_case_id) || field(use_case, :id),
      use_case_key: field(candidate, :use_case_key) || field(use_case, :key),
      use_case_model_id: field(candidate, :id),
      model_id: field(candidate, :model_id),
      model_name: field(candidate, :model_name),
      effort_tier: field(candidate, :effort_tier),
      effort: effort,
      # The override travels with the destination so the proxy never needs a
      # second lookup (and a cache of its own) to know the effort to send.
      effort_override: field(candidate, :effort_override),
      confidence: confidence,
      cost_usd: field(candidate, :cost),
      lane: lane_shape(field(candidate, :lane))
    }
  end

  defp lane_shape(nil), do: nil

  defp lane_shape(lane) do
    %{
      credential_id: field(lane, :credential_id),
      provider_model: field(lane, :provider_model),
      priority: field(lane, :priority)
    }
  end

  defp persist_pin(_use_case, _primary, _analysis, nil, _subject_id, _config, _dry_run?), do: :ok

  defp persist_pin(use_case, primary, analysis, session_key, subject_id, config, dry_run?) do
    ttl_ms = sticky_ttl_ms(config)

    if field(use_case, :pin_session) == true and ttl_ms > 0 and is_binary(subject_id) and
         not dry_run? do
      SessionPin.put(
        subject_id,
        session_key,
        %{
          use_case_id: field(use_case, :id),
          use_case_key: field(use_case, :key),
          use_case_model_id: field(primary, :id),
          model_id: field(primary, :model_id),
          model_name: field(primary, :model_name),
          effort_tier: field(primary, :effort_tier),
          requirements: %{
            tools: analysis.has_tools,
            vision: analysis.has_vision,
            structured: analysis.has_structured_output
          }
        },
        ttl_ms
      )
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp enabled?(config), do: is_map(config) and Map.get(config, :enabled) == true

  defp sticky_ttl_ms(config) do
    seconds = field(config, :sticky_ttl_seconds)

    if is_integer(seconds) and seconds > 0, do: seconds * 1000, else: 0
  end

  defp find_use_case(snapshot, id) do
    Enum.find(Map.get(snapshot, :use_cases, []), &(field(&1, :id) == id))
  end

  defp find_candidate(use_case, model_id, analysis) do
    use_case
    |> candidates()
    |> Enum.find(fn candidate ->
      field(candidate, :model_id) == model_id and
        field(candidate, :enabled) != false and
        capability_ok?(use_case, candidate, analysis) and
        context_window_ok?(candidate, analysis)
    end)
  end

  defp candidates(use_case) do
    case Map.get(use_case, :candidates) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp health_fun(opts), do: Keyword.get(opts, :health_fun, &default_health?/1)

  defp default_health?(lane) do
    case field(lane, :credential_id) do
      id when is_binary(id) -> Tokengate.Routing.CircuitBreakerManager.usable?(id)
      _ -> true
    end
  end

  defp merge_context(opts, context) do
    opts
    |> Keyword.put_new(:subject_id, context_value(context, :subject_id))
    |> Keyword.put_new(:session_http, context_value(context, :session_id))
  end

  defp context_value(context, key) do
    case Map.get(context, key) || Map.get(context, Atom.to_string(key)) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp field(%_{} = struct, key), do: Map.get(struct, key)

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp field(_, _), do: nil
end
