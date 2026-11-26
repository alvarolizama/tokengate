defmodule Tokengate.SmartRouter.ShadowEvaluator do
  @moduledoc """
  Re-decides a **live** request against every Shadow version, out of band.

  The serving Default already answered the client and its `request_logs` row is
  on its way to Postgres when this runs, so nothing here can add latency or
  money to the request: `SmartRouter.dry_run/3` never writes `SessionPin`,
  never reads or writes `DecisionCache`, never calls an upstream model to serve
  and never touches `Budgets`.

  ## What is recorded

  One `router_shadow_evaluations` row per shadow version that sampled this
  request, keyed by `(request_log_id, request_inserted_at)` — the pair the
  partitioned log table knows. Both sides are priced with the request's REAL
  token counts:

    * `default_served_cost_usd` — what the Default actually booked;
    * `estimated_served_cost_usd` — the Shadow destination's own primary tariff
      over the same tokens. The Shadow's prompt saving is measured on the RAW
      payload with its OWN policy (`PromptOptimizer.apply_router_policy/3`), so
      it is never the Default's saving subtracted a second time;
    * `decision_cost_usd` — the shadow classifier's own cost, recorded here
      and never billed to anybody (`nil` on a cache hit or a deterministic
      layer).

  ## Why the raw prompt is reconstructed

  `usage.prompt_tokens` is what the PROVIDER counted, i.e. after the Default's
  prompt policy already removed its own tokens. To price what the Shadow would
  have sent, this module:

    1. reconstructs `raw_prompt = prompt_tokens + prompt_tokens_saved_est`
       (the trimming the Default applied before the provider counted);
    2. measures the Shadow's OWN trim on that raw payload with the Shadow's
       `prompt_policy` (`shadow_saved`, 0 when the policy trimmed nothing);
    3. prices `max(raw_prompt - shadow_saved, 0)`.

  Reusing the Default's `prompt_tokens_saved_est` as the Shadow's saving would
  discount the same tokens twice (and would credit a version with a trim it
  does not declare).

  `matches_default_model` / `matches_default_tier` are written as booleans so
  the discrepancy filters are plain indexed reads instead of per-row
  comparisons.

  ## Sampling

  `:erlang.phash2({shadow_config_id, sticky_key}, 100) < shadow_sample_pct`,
  where `sticky_key` is the session (then subject, then the log id): the same
  conversation lands on the same side of the split on every turn, so a Shadow
  version sees whole sessions instead of random single turns.

  ## Where it runs

  `evaluate_async/1` submits the work to
  `Tokengate.Routing.DecisionTaskSupervisor` (falling back to `Task.start/1`
  when that supervisor is not running), NEVER in the HTTP request process. With
  no shadow version enabled it returns `:ok` immediately and spawns nothing.
  """

  require Logger

  alias Tokengate.Proxy.{CostCalculator, PromptOptimizer, ServiceUsage}
  alias Tokengate.Repo
  alias Tokengate.Routing.Router
  alias Tokengate.SmartRouter
  alias Tokengate.SmartRouter.ShadowEvaluation

  @task_sup Tokengate.Routing.DecisionTaskSupervisor
  @pubsub Tokengate.PubSub
  @topic "smart_router:shadow"

  @zero Decimal.new(0)

  @type params :: %{
          required(:request_log_id) => String.t(),
          required(:request_inserted_at) => DateTime.t(),
          required(:payload) => map(),
          optional(:context) => map(),
          optional(:default_decision) => map() | nil,
          optional(:usage) => map(),
          optional(:default_served_cost_usd) => Decimal.t() | nil,
          optional(:prompt_tokens_saved_est) => non_neg_integer(),
          optional(:group_member) => map() | nil
        }

  @doc """
  Evaluates `params` against every shadow version, off the calling process.

  Returns `:ok` without spawning anything when no version is `shadow_enabled`.
  """
  @spec evaluate_async(params()) :: :ok
  def evaluate_async(params) when is_map(params) do
    case SmartRouter.shadow_configs() do
      [] -> :ok
      configs -> start_task(fn -> run(configs, params) end)
    end
  end

  @doc """
  Same evaluation, in the calling process (tests and manual dry runs).
  """
  @spec evaluate_sync(params()) :: :ok
  def evaluate_sync(params) when is_map(params) do
    case SmartRouter.shadow_configs() do
      [] -> :ok
      configs -> run(configs, params)
    end
  end

  @doc "The PubSub topic the comparison screens subscribe to."
  @spec topic() :: String.t()
  def topic, do: @topic

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  defp start_task(fun) do
    case safe_start_child(fun) do
      :ok ->
        :ok

      :unavailable ->
        # No supervisor (a bare `iex -S mix`, an app tree without routing):
        # a plain process still keeps the evaluation off the caller.
        _ = Task.start(fun)
        :ok
    end
  end

  # A `Task.Supervisor.start_child/2` against a supervisor that is not running
  # EXITS the caller (the request process) — which must never happen here.
  defp safe_start_child(fun) do
    Task.Supervisor.start_child(@task_sup, fun)
    :ok
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  # ---------------------------------------------------------------------------
  # Evaluation
  # ---------------------------------------------------------------------------

  defp run(configs, params) do
    request_log_id = Map.fetch!(params, :request_log_id)
    context = Map.get(params, :context) || %{}
    sticky_key = sticky_key(context, request_log_id)

    evals =
      configs
      |> Enum.filter(&sampled?(&1, sticky_key))
      |> Enum.flat_map(&evaluate(&1, params, context))

    broadcast(request_log_id, evals)
    :ok
  end

  # One broken version must not cost the others their comparison.
  defp evaluate(config, params, context) do
    try do
      [insert_evaluation(config, params, context)]
    rescue
      error ->
        Logger.warning(
          "shadow evaluation crashed for config #{config.id}: #{Exception.message(error)}"
        )

        []
    end
  end

  defp insert_evaluation(config, params, context) do
    case shadow_decision(config, params, context) do
      {:ok, decision} ->
        attrs = success_attrs(config, params, decision)
        persist(attrs, params)

      {:error, reason} ->
        attrs = error_attrs(config, params, reason)
        persist(attrs, params)
    end
  end

  # `dry_run: true` is what makes this safe: no session pin, no decision cache
  # read or write, no upstream call, no budget reservation. `enabled` is forced
  # on because that flag is GLOBAL policy (a promotion preserves the outgoing
  # Default's value) — a candidate's own flag must not make it unevaluable.
  defp shadow_decision(config, params, context) do
    case SmartRouter.snapshot(config_id: config.id) do
      %{config: %{} = snapshot_config} = snapshot ->
        snapshot = %{snapshot | config: %{snapshot_config | enabled: true}}

        SmartRouter.dry_run(Map.get(params, :payload) || %{}, context, snapshot: snapshot)

      _ ->
        {:error, :version_not_found}
    end
  end

  defp success_attrs(config, params, decision) do
    meta = Map.get(decision, :decision_meta) || %{}
    primary = Map.get(decision, :primary) || %{}
    use_case = Map.get(decision, :use_case) || %{}
    defaults = default_side(params)
    usage = Map.get(params, :usage) || %{}
    model_id = Map.get(primary, :model_id)
    tier = Map.get(primary, :effort_tier)

    # `default_saved` is the trim the Default already applied BEFORE the
    # provider counted `usage.prompt_tokens`; the Shadow measures its own trim
    # on the RAW payload, so the two never overlap.
    default_saved = default_prompt_tokens_saved(params)
    shadow_saved = shadow_prompt_tokens_saved(params, decision)
    raw_prompt = tokens(usage, :prompt_tokens) + default_saved
    prompt = max(raw_prompt - shadow_saved, 0)

    %{
      request_log_id: Map.fetch!(params, :request_log_id),
      request_inserted_at: Map.fetch!(params, :request_inserted_at),
      default_config_id: defaults.config_id,
      shadow_config_id: config.id,
      shadow_config_name: config.name,
      default_use_case_key: defaults.use_case_key,
      default_effort_tier: defaults.effort_tier,
      default_model_id: defaults.model_id,
      default_model_name: defaults.model_name,
      default_served_cost_usd: Map.get(params, :default_served_cost_usd),
      use_case_key: Map.get(use_case, :key),
      effort_tier: tier,
      model_id: model_id,
      model_name: Map.get(primary, :model_name),
      decision_source: Map.get(meta, :source),
      decision_ms: Map.get(meta, :latency_ms),
      decision_cost_usd: decision_cost(meta, params),
      prompt_tokens_saved_est: shadow_saved,
      estimated_served_cost_usd: estimated_served_cost(model_id, usage, prompt, params),
      matches_default_model: model_id != nil and model_id == defaults.model_id,
      # An unknown tier is unknown, not equal: `nil == nil` must not read as
      # agreement.
      matches_default_tier: tier != nil and tier == defaults.effort_tier
    }
  end

  defp error_attrs(config, params, reason) do
    defaults = default_side(params)

    %{
      request_log_id: Map.fetch!(params, :request_log_id),
      request_inserted_at: Map.fetch!(params, :request_inserted_at),
      default_config_id: defaults.config_id,
      shadow_config_id: config.id,
      shadow_config_name: config.name,
      default_use_case_key: defaults.use_case_key,
      default_effort_tier: defaults.effort_tier,
      default_model_id: defaults.model_id,
      default_model_name: defaults.model_name,
      default_served_cost_usd: Map.get(params, :default_served_cost_usd),
      decision_source: "shadow_error",
      error_reason: error_reason(reason),
      matches_default_model: false,
      matches_default_tier: false
    }
  end

  # A version that cannot be inserted (deleted between the list read and this
  # write, an FK race) is a log line, never a crashed worker: the live request
  # already has its response.
  defp persist(attrs, params) do
    case %ShadowEvaluation{} |> ShadowEvaluation.changeset(attrs) |> Repo.insert() do
      {:ok, evaluation} ->
        evaluation

      {:error, changeset} ->
        Logger.warning(
          "shadow evaluation not recorded for log #{Map.get(params, :request_log_id)}: " <>
            inspect(changeset.errors)
        )

        nil
    end
  end

  defp broadcast(_request_log_id, []), do: :ok

  defp broadcast(request_log_id, evals) do
    case Enum.reject(evals, &is_nil/1) do
      [] ->
        # Every version crashed or could not be persisted: nothing was
        # recorded, so there is nothing to announce.
        :ok

      recorded ->
        Phoenix.PubSub.broadcast(
          @pubsub,
          @topic,
          {:shadow_evaluated, request_log_id, recorded}
        )
    end
  end

  defp error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_reason(reason), do: inspect(reason)

  # ---------------------------------------------------------------------------
  # Sampling
  # ---------------------------------------------------------------------------

  defp sampled?(config, sticky_key) do
    pct = Map.get(config, :shadow_sample_pct) || 100
    :erlang.phash2({config.id, sticky_key}, 100) < pct
  end

  defp sticky_key(context, request_log_id) do
    context_value(context, :session_id) || context_value(context, :subject_id) ||
      request_log_id
  end

  # ---------------------------------------------------------------------------
  # Pricing
  # ---------------------------------------------------------------------------

  # `prompt` is already the Shadow's OWN post-trim count (see
  # `success_attrs/3`); the cache read can never exceed it.
  defp estimated_served_cost(model_id, usage, prompt, params) do
    with true <- is_binary(model_id),
         %{} = tariff <- tariff(model_id, Map.get(params, :group_member)) do
      cost =
        CostCalculator.provider_cost(nil,
          manual_pricing: pricing(tariff),
          usage: %{
            prompt_tokens: prompt,
            completion_tokens: tokens(usage, :completion_tokens),
            cache_read_tokens: min(tokens(usage, :cache_read_tokens), prompt),
            cache_creation_tokens: tokens(usage, :cache_creation_tokens)
          },
          pricing_unit: tariff.pricing_unit || "per_1m_tokens",
          unit_cost: tariff.unit_cost,
          quantities: ServiceUsage.quantities("llm", %{}, %{})
        )

      positive(cost)
    else
      _ -> nil
    end
  end

  # The shadow classifier's own price. Only a REAL Layer-2 call costs anything:
  # a cache hit or a deterministic layer must not report a classifier price.
  #
  # The lane is resolved exactly the way the SERVING path resolves it
  # (`SmartRouter.resolve_decision_lane/1`: a global, active, circuit-closed
  # lane of the decision model), and the rate comes from that lane's
  # `model_provider` — never from a per-member tariff, which does not exist for
  # an internal classifier call.
  defp decision_cost(meta, _params) do
    with true <- Map.get(meta, :classifier) == true,
         true <- Map.get(meta, :cache_hit) != true,
         %{} = usage <- Map.get(meta, :usage),
         model_id when is_binary(model_id) <- Map.get(meta, :model_id),
         {:ok, lane} <- SmartRouter.resolve_decision_lane(model_id) do
      pricing_row = lane.model_provider

      cost =
        CostCalculator.provider_cost(nil,
          manual_pricing: %{
            input_cost_per_million: Map.get(pricing_row, :input_cost_per_million),
            output_cost_per_million: Map.get(pricing_row, :output_cost_per_million),
            cache_cost_per_million: Map.get(pricing_row, :cache_cost_per_million),
            cache_write_cost_per_million: Map.get(pricing_row, :cache_write_cost_per_million)
          },
          usage: %{
            prompt_tokens: tokens(usage, :prompt_tokens, :input_tokens),
            completion_tokens: tokens(usage, :completion_tokens, :output_tokens)
          },
          pricing_unit: Map.get(pricing_row, :pricing_unit),
          quantities: ServiceUsage.quantities(lane.model_type || "llm", %{}, %{})
        )

      positive(cost)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp pricing(tariff) do
    %{
      input_cost_per_million: Map.get(tariff, :input_cost_per_million),
      output_cost_per_million: Map.get(tariff, :output_cost_per_million),
      cache_cost_per_million: Map.get(tariff, :cache_cost_per_million),
      cache_write_cost_per_million: Map.get(tariff, :cache_write_cost_per_million)
    }
  end

  # Tariffs are lane rates of a model for a member: no member (or no visible
  # lane) means no honest price, and an estimated cost is never invented.
  defp tariff(model_id, group_member) when is_map(group_member) do
    Router.primary_tariff(model_id, group_member)
  rescue
    _ -> nil
  end

  defp tariff(_model_id, _group_member), do: nil

  defp positive(cost) do
    if Decimal.compare(cost, @zero) == :gt, do: cost
  end

  # ---------------------------------------------------------------------------
  # Params helpers
  # ---------------------------------------------------------------------------

  defp default_side(params) do
    decision = Map.get(params, :default_decision) || %{}
    primary = Map.get(decision, :primary) || %{}
    use_case = Map.get(decision, :use_case) || %{}
    meta = Map.get(decision, :decision_meta) || %{}

    %{
      config_id: Map.get(meta, :config_id),
      use_case_key: Map.get(use_case, :key),
      effort_tier: Map.get(primary, :effort_tier),
      model_id: Map.get(primary, :model_id),
      model_name: Map.get(primary, :model_name)
    }
  end

  # The trim the Default applied to the request BEFORE the provider counted
  # `usage.prompt_tokens`: the amount to add back to reconstruct the raw prompt.
  defp default_prompt_tokens_saved(params) do
    case Map.get(params, :prompt_tokens_saved_est) do
      saved when is_integer(saved) and saved > 0 -> saved
      _ -> 0
    end
  end

  # The trim THIS version would have applied, measured on the raw payload with
  # its own `prompt_policy` and the same estimator the serving path uses. `0`
  # when the version declares no trimming policy or the policy removed nothing.
  #
  # `pinned: false` on purpose: the Shadow serves nobody, so there is no hot
  # upstream prefix to protect and the conservative gate of a live pin would
  # under-report its saving.
  defp shadow_prompt_tokens_saved(params, decision) do
    payload = Map.get(params, :payload) || %{}
    policy = Map.get(decision, :prompt_policy)

    case PromptOptimizer.apply_router_policy(payload, policy, pinned: false) do
      {_optimized, saved} when is_integer(saved) and saved > 0 -> saved
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp tokens(usage, key) when is_map(usage) do
    case Map.get(usage, key) || Map.get(usage, Atom.to_string(key)) do
      value when is_integer(value) and value > 0 -> value
      _ -> 0
    end
  end

  defp tokens(_usage, _key), do: 0

  # The same token count under two names across providers (`prompt_tokens` vs
  # `input_tokens`): take whichever the answer carries, never the sum.
  defp tokens(usage, key, fallback_key), do: max(tokens(usage, key), tokens(usage, fallback_key))

  defp context_value(context, key) when is_map(context) do
    case Map.get(context, key) || Map.get(context, Atom.to_string(key)) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp context_value(_context, _key), do: nil
end
