defmodule Tokengate.SmartRouter do
  @moduledoc """
  Public door of the SmartRouter decision engine (S2).

  The engine classifies one chat-completions request across the operator's
  tag/flag-annotated use cases and picks a destination model, in four layers:

      0. session pin / tool loop (no classifier)
      1. capability filters + router rules + fast path (no classifier)
      2. on-demand classifier (only when 2+ viable use cases remain)
      3. effort-tier ranking + lowest eligible cost + fallback chain

  `decide/3` returns `{:ok, %{use_case, primary, fallbacks, prompt_policy,
  decision_meta}}`. `dry_run/3` produces the same decision without writing the
  session pin or the decision cache (no caller-visible state changes).

  ## Hook point for the proxy (S3 — intentionally NOT wired here)

  `TokengateWeb.ProxyController` has no SmartRouter call yet. The wiring belongs
  to S3 and is exactly this: on `POST /v1/chat/completions` (and the decisions
  surface) **before** `route_and_acquire/…` resolves the requested model, when
  `payload["model"] == "router"`, call

      Tokengate.SmartRouter.decide(payload, %{
        subject_id: subject_id(conn),
        group_id: group_id(conn),
        service_id: service_id(conn),
        session_id: get_req_header(conn, "x-session-id") |> List.first(),
        agent_type: agent_type(conn)
      })

  and route to `decision.primary.model_name`, persisting
  `decision.decision_meta` (`source`, `classifier`, `confidence`, `latency_ms`,
  `usage`, `model_id`) plus the use-case key into the `request_logs` router columns
  that already exist. The engine never mutates the caller's process state, so
  it is safe to call from the controller process.

  ## Snapshot

  The config, use cases, destinations and rules are loaded once per minute
  through `Tokengate.Cache` under `{:smart_router_config}`. Every mutation made
  through the admin surfaces must call `invalidate/0` after the write (S5 owns
  those screens; this module owns the invalidation). Tests and simulations can
  bypass the loader entirely by passing `:snapshot`.

  ## Decision cost

  The classifier is billed separately: `decide/3` never reserves budget and
  returns `decision_meta.usage`/`latency_ms` for S3 to price with
  `Tokengate.Proxy.CostCalculator` and persist.
  """

  alias Tokengate.Providers
  alias Tokengate.Providers.Model
  alias Tokengate.Repo
  alias Tokengate.Routing.Pools
  alias Tokengate.SmartRouter.{Config, Engine, Rule, UseCase, UseCaseModel}

  @cache_key {:smart_router_config}
  @enabled_key {:smart_router_enabled}
  @cache_ttl_ms :timer.minutes(1)

  @doc """
  Whether the router is switched on (`router_configs.enabled`).

  This is the **discovery/authorization** predicate: `GET /v1/models` only
  advertises the `"router"` alias when this is `true` AND the subject opted in
  (`Tokengate.Accounts.router_enabled?/1`), so what the catalog shows and what
  the proxy accepts never disagree.

  Cached for a minute under its own key (it is read on every `/v1/models`
  call); `invalidate/0` drops it together with the snapshot.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Tokengate.Cache.fetch(@enabled_key, @cache_ttl_ms, fn ->
      match?(%Config{enabled: true}, Config.get())
    end)
  end

  @doc """
  The `effort_override` declared by a use-case destination binding
  (`router_use_case_models.effort_override`), or `nil`.

  The decision carries the binding id (`primary.use_case_model_id`) but not the
  override itself, which is a property of the BINDING, not of the shared
  `Model`: the proxy reads it here so the use case — not the model row — decides
  the effort sent upstream. Read straight from the cached `snapshot/1` (the
  candidates carry `effort_override`), so there is no second cache to keep in
  sync and `invalidate/0` covers it; `nil` for an unknown id.
  """
  @spec effort_override(String.t() | nil, keyword()) :: String.t() | nil
  def effort_override(use_case_model_id, opts \\ [])

  def effort_override(nil, _opts), do: nil

  def effort_override(use_case_model_id, opts) when is_binary(use_case_model_id) do
    snapshot = Keyword.get_lazy(opts, :snapshot, fn -> snapshot() end)

    snapshot
    |> Map.get(:use_cases, [])
    |> Enum.flat_map(&Map.get(&1, :candidates, []))
    |> Enum.find_value(fn candidate ->
      if Map.get(candidate, :id) == use_case_model_id,
        do: Map.get(candidate, :effort_override) || nil
    end)
  rescue
    _ -> nil
  end

  @doc """
  Decides the destination for `payload` (a chat-completions body with string
  keys).

  `context` may carry `subject_id`, `group_id`, `service_id`, `session_id`
  (the `x-session-id` header) and `agent_type` — all optional, all used only
  for pinning and rule matching.

  Options:

    * `:snapshot` — an already-loaded snapshot (tests / dry-run of a proposed
      config). Skips the cache and the database.
    * `:classifier_fun` — overrides the whole Layer 2 call
      (`fn decision_model, analysis, use_cases -> {:ok, answer} | {:error, reason} end`).
    * `:post_fun` / `:lane_fun` / `:task_supervisor` — injected into
      `Tokengate.SmartRouter.Classifier`.
    * `:health_fun` — `fn lane -> boolean end`, defaults to the circuit breaker.

  ## S3 wiring (not done here)

  `TokengateWeb.ProxyController` must call this **before** `route_and_acquire`
  when `payload["model"] == "router"` and route to `primary.model_name`, passing
  `subject_id`, `group_id`, `service_id`, `session_id` and `agent_type` in
  `context` (see the module documentation for the exact snippet). The controller
  is intentionally left untouched by S2; the hook point is documented on this
  function so S3 has one unambiguous place to wire it.
  """
  @spec decide(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def decide(payload, context \\ %{}, opts \\ []) do
    snapshot = Keyword.get_lazy(opts, :snapshot, fn -> snapshot() end)
    Engine.decide(snapshot, payload, context, opts)
  end

  @doc """
  Side-effect-free simulation: same decision as `decide/3` but it never writes
  the session pin nor the decision cache, and `decision_meta.dry_run` is `true`.
  """
  @spec dry_run(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def dry_run(payload, context \\ %{}, opts \\ []) do
    opts = opts |> Keyword.put(:dry_run, true)
    snapshot = Keyword.get_lazy(opts, :snapshot, fn -> snapshot() end)
    Engine.decide(snapshot, payload, context, opts)
  end

  @doc """
  The cached routing snapshot (`config`, `use_cases`, `rules`, `models`,
  `decision_model`). Cached for one minute under `{:smart_router_config}`.
  """
  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @cache_ttl_ms)
    Tokengate.Cache.fetch(@cache_key, ttl_ms, &load_snapshot/0)
  end

  @doc "Drops the cached snapshot (call after any router config mutation)."
  @spec invalidate() :: :ok
  def invalidate do
    Tokengate.Cache.invalidate(@cache_key)
    Tokengate.Cache.invalidate(@enabled_key)
    # The decision cache is keyed by the QUESTION (use-case catalogue + prompt),
    # so a catalogue change makes every cached answer suspect: drop it too.
    clear_decision_cache()
    :ok
  end

  defp clear_decision_cache do
    if :ets.whereis(:tokengate_router_decisions) != :undefined do
      Tokengate.SmartRouter.DecisionCache.clear_all()
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Resolves a **global** lane for the decision model (`decision_model_id`).

  Never touches exclusive credentials: the classifier is a gateway-internal
  call and must not consume a member's exclusive lane. Skips credentials that
  are not `active` and lanes whose credential is circuit-open.
  """
  @spec resolve_decision_lane(String.t()) :: {:ok, map()} | {:error, term()}
  def resolve_decision_lane(model_id) when is_binary(model_id) do
    case Repo.get(Model, model_id) do
      nil -> {:error, :model_not_found}
      model -> resolve_lane(model)
    end
  end

  # ---------------------------------------------------------------------------
  # Lane resolution
  # ---------------------------------------------------------------------------

  defp resolve_lane(model) do
    model.id
    |> Providers.list_model_providers()
    |> Pools.expand()
    |> Enum.filter(&global_lane?/1)
    |> Enum.filter(fn lane ->
      lane.credential != nil and lane.credential.status == "active" and
        Tokengate.Routing.CircuitBreakerManager.usable?(lane.credential.id)
    end)
    |> List.first()
    |> case do
      nil ->
        {:error, :no_available_lane}

      lane ->
        {:ok,
         %{
           model_provider: lane,
           credential: lane.credential,
           provider: lane.credential.provider,
           provider_model: lane.provider_model,
           model_id: model.id,
           model_type: model.model_type
         }}
    end
  end

  defp global_lane?(lane) do
    lane.exclusive_to_group_member_id == nil and lane.exclusive_to_group_id == nil and
      lane.exclusive_to_service_id == nil
  end

  # ---------------------------------------------------------------------------
  # Snapshot loader
  # ---------------------------------------------------------------------------

  defp load_snapshot do
    config = Config.get()
    use_cases = Repo.all(UseCase) |> Enum.filter(& &1.enabled) |> Enum.sort_by(& &1.priority)
    bindings = load_bindings()
    models = load_models(model_ids(config, use_cases, bindings))
    rules = load_rules()

    %{
      config: config,
      use_cases: Enum.map(use_cases, &use_case_snapshot(&1, bindings, models)),
      rules: rules,
      models: models,
      decision_model: decision_model(config)
    }
  end

  defp load_bindings do
    import Ecto.Query, only: [from: 2]

    Repo.all(
      from(b in UseCaseModel,
        where: b.enabled == true,
        order_by: [asc: b.priority],
        preload: [:target_model]
      )
    )
    |> Enum.group_by(& &1.router_use_case_id)
  end

  defp load_rules do
    import Ecto.Query, only: [from: 2]

    Repo.all(
      from(r in Rule,
        where: r.enabled == true,
        order_by: [asc: r.priority]
      )
    )
  end

  defp model_ids(config, use_cases, bindings) do
    binding_ids =
      bindings
      |> Enum.flat_map(fn {_use_case_id, list} -> Enum.map(list, & &1.target_model_id) end)

    fallback_ids =
      Enum.map(use_cases, & &1.fallback_model_id) ++
        case config do
          nil -> []
          config -> [config.decision_model_id, config.default_model_id, config.baseline_model_id]
        end

    (binding_ids ++ fallback_ids)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp load_models([]), do: %{}

  defp load_models(model_ids) do
    import Ecto.Query, only: [from: 2]

    Repo.all(
      from(m in Model,
        where: m.id in ^model_ids,
        preload: [model_providers: [:credential, pool: [members: [:credential]]]]
      )
    )
    |> Enum.reduce(%{}, fn model, acc ->
      Map.put(acc, model.id, %{
        id: model.id,
        name: model.name,
        model_type: model.model_type,
        context_window: model.context_window,
        market_input_price_per_1m: model.market_input_price_per_1m,
        market_output_price_per_1m: model.market_output_price_per_1m,
        lanes: lanes(model)
      })
    end)
  end

  # Only GLOBAL, active lanes participate in cost ranking: an exclusive lane
  # belongs to one consumer and must not price a decision for everybody else.
  defp lanes(model) do
    model.model_providers
    |> Pools.expand()
    |> Enum.filter(fn lane ->
      lane.enabled != false and global_lane?(lane) and lane.credential != nil and
        lane.credential.status == "active"
    end)
    |> Enum.map(fn lane ->
      %{
        id: lane.id,
        credential_id: lane.credential.id,
        provider_model: lane.provider_model,
        priority: lane.priority,
        input_cost_per_million: lane.input_cost_per_million,
        output_cost_per_million: lane.output_cost_per_million,
        cache_cost_per_million: lane.cache_cost_per_million,
        pricing_unit: lane.pricing_unit,
        unit_cost: lane.unit_cost
      }
    end)
  end

  defp use_case_snapshot(use_case, bindings, models) do
    use_case
    |> Map.from_struct()
    |> Map.put(
      :candidates,
      use_case
      |> Map.get(:id)
      |> then(&Map.get(bindings, &1, []))
      |> Enum.map(&candidate_snapshot(&1, use_case, models))
      |> Enum.reject(&is_nil/1)
    )
  end

  defp candidate_snapshot(binding, use_case, models) do
    case binding.target_model do
      %Model{model_type: "llm"} = model ->
        %{
          id: binding.id,
          use_case_id: use_case.id,
          use_case_key: use_case.key,
          model_id: model.id,
          model_name: model.name,
          effort_tier: binding.effort_tier,
          effort_override: binding.effort_override,
          supports_tools: binding.supports_tools,
          supports_vision: binding.supports_vision,
          supports_structured_output: binding.supports_structured_output,
          min_confidence: min_confidence(binding.min_confidence),
          tags: binding.tags,
          flags: binding.flags,
          priority: binding.priority,
          enabled: binding.enabled,
          context_window: model.context_window,
          market_input_price_per_1m: model.market_input_price_per_1m,
          market_output_price_per_1m: model.market_output_price_per_1m,
          lanes: get_in(models, [model.id, :lanes]) || []
        }

      _ ->
        nil
    end
  end

  defp min_confidence(nil), do: nil
  defp min_confidence(%Decimal{} = value), do: Decimal.to_float(value)
  defp min_confidence(value) when is_float(value) or is_integer(value), do: value * 1.0

  defp decision_model(nil), do: nil

  defp decision_model(%Config{decision_model_id: nil}), do: nil

  defp decision_model(%Config{decision_model_id: id}) do
    case Repo.get(Model, id) do
      nil -> nil
      model -> %{id: model.id, name: model.name, model_type: model.model_type}
    end
  end
end
