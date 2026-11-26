defmodule Tokengate.Routing.Router do
  @moduledoc """
  Resolves a requested model name to a concrete provider credential, applying
  access control, strategy-based provider selection, and circuit-breaker
  availability filtering.

  ## Public API

    * `route/3`  – resolve a `model_requested` for a `group_member`, returning a
      route map with the selected `model_provider`, `credential`, and
      `model_responded` (the upstream model string).
    * `record_outcome/2` – record a success or failure against the selected
      credential's circuit breaker.
    * `models_for/1` – shape the accessible models for the `/v1/models` API.

  ## Access control

  A group member can only route to models returned by
  `Tokengate.Providers.list_accessible_models/1` — the union of models
  granted to their group plus any extra models granted to them individually.

  ## Provider selection

  Priority-based selection with sticky routing: the first available
  provider (by priority ASC) is chosen, and the same API key sticks to
  the same provider to preserve prompt caches. Strategies receive an
  `available?` predicate built from the circuit breaker so they never
  call the breaker directly.

  ### Credential pools

  A lane mounted on a credential pool (`pool_id`) carries no credential of
  its own: it stands for N keys of the same provider. Before the credential,
  status, `exclude` and visibility filters run, every lane is materialized
  into one candidate per pool member — a COPY of the lane with the member's
  credential and the lane's `id` (`Tokengate.Routing.Pools.expand/1`) — so the
  filters and the breaker run per member while priority, price, scope and
  `provider_model` stay on the lane. Candidates are then grouped back by lane
  id (`Pools.group/1`) and `Priority.select_groups/2` picks the group first
  (health, priority) and the member second (rotation per request, no sticky).
  The route is built from the chosen copy, so `route.model_provider.credential`
  is the member that served and `route.model_provider.id` is still the lane.

  ### Exclusive scope

  Providers can be scoped to serve only specific consumers:
    * Global (no scope) — available to all members with access.
    * Member-exclusive — only the specified group member sees it.
    * Group-exclusive — only members of the specified group see it.

  A credential can appear in multiple scope rows for the same model
  (global + multiple group-exclusive + multiple member-exclusive).
  Exclusive providers are injected with priority -1 (always first) for
  the matching scope. If they fail, the normal fallback pool takes over.

  ## Fallback / retry

  Callers may pass `:exclude_credential_ids` in `request_context` (or as a
  keyword option to `route/3`) to drop credentials from the candidate set —
  used to retry on a different provider after a failure without re-selecting
  the same (now failed) credential.
  """
  alias Tokengate.Providers
  alias Tokengate.Routing.CircuitBreakerManager
  alias Tokengate.Routing.CredentialHealth
  alias Tokengate.Routing.Pools
  alias Tokengate.Routing.Priority

  @type route :: %{
          model: Tokengate.Providers.Model.t(),
          model_provider: Tokengate.Providers.ModelProvider.t(),
          credential: Tokengate.Providers.Credential.t(),
          model_responded: String.t()
        }

  @default_breaker CircuitBreakerManager

  @doc """
  Resolves `model_requested` for `group_member`, returning a route map.

  ## Options (`request_context`)

    * `:api_key_hash` – opaque hash identifying the API key (for sticky
      routing under the priority strategy). May be nil.
    * `:exclude_credential_ids` – list of credential ids to exclude from
      candidates (retry-after-failure fallback). May also be passed as a
      keyword option to `route/3`.
    * `:breaker` – a module implementing the breaker API
      (`allow?/1`, `record_success/1`, `record_failure/2`) used in place of
      `CircuitBreakerManager` (test injection). Defaults to the real manager.
    * `:capability` – the required `model_type` of the model (`"llm"`,
      `"embedding"`). Defaults to `"llm"` (chat completions).
      When the model exists but its `model_type` differs, returns
      `{:error, :model_type_mismatch}`.

  ## Returns

    * `{:ok, route}` – the resolved route.
    * `{:error, :model_not_found}` – no accessible model with that name.
    * `{:error, :model_type_mismatch}` – model exists but serves a
      different capability than requested.
    * `{:error, :no_providers_configured}` – model has no configured model providers.
    * `{:error, :no_available_provider}` – all candidates were filtered out
      (no active credential, breaker open, or excluded).

  """
  @spec route(String.t(), map(), map(), keyword()) ::
          {:ok, route()}
          | {:error,
             :model_not_found
             | :model_type_mismatch
             | :no_providers_configured
             | :no_available_provider}
  def route(model_requested, group_member, request_context \\ %{}, opts \\ []) do
    breaker = Keyword.get(opts, :breaker, Map.get(request_context, :breaker, @default_breaker))
    exclude = exclude_ids(request_context, opts)

    capability =
      request_context
      |> Map.get(:capability, "llm")
      |> List.wrap()
      |> Enum.map(&to_string/1)

    # Ensure group is preloaded (callers may not have preloaded it).
    group_member = maybe_preload_group(group_member)

    accessible = accessible_models(group_member)

    case find_alias_by_name(accessible, model_requested) do
      nil ->
        {:error, :model_not_found}

      %{model_type: type} = model ->
        if is_binary(type) and type in capability do
          route_model(model, group_member, accessible, request_context, breaker, exclude)
        else
          {:error, :model_type_mismatch}
        end
    end
  end

  @doc """
  Resolves a **model id** for `group_member`, bypassing the model ACL.

  This is the SmartRouter door: the decision engine already picked a concrete
  model (it only ranks models with a global, healthy lane), so the model-grant
  check (`accessible_models/1`) must not veto a destination the router was
  allowed to choose. Everything else is the SAME pipeline as `route/4`:

    * the model's `model_type` is checked against `:capability` (an LLM-only
      alias never lands on an embedding model);
    * `route_model/6` still runs `visible_to_member?/2`, so a lane exclusive to
      another member, group or service is NEVER leaked — the ACL bypass stops at
      the model, not at the credential.

  Returns the same route map and error vocabulary as `route/4`;
  `:model_not_found` now means "no such model row", not "not granted".
  """
  @spec route_by_model_id(String.t(), map(), map(), keyword()) ::
          {:ok, route()}
          | {:error,
             :model_not_found
             | :model_type_mismatch
             | :no_providers_configured
             | :no_available_provider}
  def route_by_model_id(model_id, group_member, request_context \\ %{}, opts \\ []) do
    breaker = Keyword.get(opts, :breaker, Map.get(request_context, :breaker, @default_breaker))
    exclude = exclude_ids(request_context, opts)

    capability =
      request_context
      |> Map.get(:capability, "llm")
      |> List.wrap()
      |> Enum.map(&to_string/1)

    group_member = maybe_preload_group(group_member)

    case model_by_id(model_id) do
      nil ->
        {:error, :model_not_found}

      %{model_type: type} = model ->
        if is_binary(type) and type in capability do
          route_model(model, group_member, nil, request_context, breaker, exclude)
        else
          {:error, :model_type_mismatch}
        end
    end
  end

  @doc """
  Whether `model_id` is directly reachable by `group_member` (it is in
  `accessible_models/1`, the cached model ACL).

  The router logs it as `request_logs.router_direct_access`: `false` means the
  subject reached the serving model ONLY through the router. Reads the same
  ETS cache as `route/4`, so it costs no extra query on the hot path.
  """
  @spec direct_access?(String.t(), map() | nil) :: boolean()
  def direct_access?(model_id, group_member) do
    group_member = maybe_preload_group(group_member)
    Enum.any?(accessible_models(group_member), &(&1.id == model_id))
  end

  @doc """
  The pricing of the lane `route_by_model_id(model_id, group_member)` would
  serve FIRST for this member (highest priority among the lanes visible to
  them), or `nil` when the model has no visible lane.

  Used for the router's frozen counterfactual: the savings baseline is priced
  with the BASELINE model's own primary lane rates and the request's real
  usage. `nil` when there is no lane — a baseline is never invented.
  """
  @spec primary_tariff(String.t(), map() | nil) ::
          %{
            input_cost_per_million: term(),
            output_cost_per_million: term(),
            cache_cost_per_million: term(),
            cache_write_cost_per_million: term(),
            pricing_unit: String.t() | nil,
            unit_cost: term(),
            provider_model: String.t() | nil
          }
          | nil
  def primary_tariff(model_id, group_member) do
    group_member = maybe_preload_group(group_member)

    enabled_global_ids = Tokengate.Routing.Cache.disabled_credential_ids()

    case model_by_id(model_id) do
      nil ->
        nil

      model ->
        model
        |> model_providers_for(group_member)
        |> Pools.expand()
        |> Enum.filter(fn mp ->
          mp.enabled != false and
            mp.credential != nil and
            mp.credential.status == "active" and
            not MapSet.member?(enabled_global_ids, mp.credential.id) and
            visible_to_member?(mp, group_member)
        end)
        |> Enum.min_by(& &1.priority, fn -> nil end)
        |> case do
          nil ->
            nil

          lane ->
            %{
              input_cost_per_million: lane.input_cost_per_million,
              output_cost_per_million: lane.output_cost_per_million,
              cache_cost_per_million: lane.cache_cost_per_million,
              cache_write_cost_per_million: lane.cache_write_cost_per_million,
              pricing_unit: lane.pricing_unit,
              unit_cost: lane.unit_cost,
              provider_model: lane.provider_model
            }
        end
    end
  end

  @doc """
  Records the outcome of a routed request against the selected credential's
  circuit breaker, and — for successes — against the credential's soft
  health (`Tokengate.Routing.CredentialHealth`).

    * `:success` → `breaker.record_success(credential.id)`. When
      `:latency_ms` is passed in `opts`, a slow success degrades the
      credential (it sinks below healthy candidates) and a fast one heals it.
    * `{:failure, reason}` → `breaker.record_failure(credential.id, reason)`.
    * `{:failure, reason, error_message}` → same, also storing the upstream
      error message in the breaker state for observability.

  ### Rate limits

  A `:rate_limited` failure feeds the circuit breaker like any other failure
  reason — routing no longer distinguishes a subscription provider. A 429 is
  a provider signal, and the breaker's cooldown/fallback handles it.

  Always returns `:ok`. The caller decides whether to re-route (using
  `:exclude_credential_ids` to skip the failed credential) or surface the
  error to the client.

  `reason` is one of `:server_error`, `:timeout`, `:rate_limited`,
  `:client_error`, `:bad_request`, `:auth_error`.

  ## Options

    * `:latency_ms` — end-to-end latency of a successful upstream call.
      Compared against `slow_threshold_ms` (config `:tokengate, :routing`).
  """
  @spec record_outcome(
          route(),
          :success | {:failure, atom()} | {:failure, atom(), String.t() | nil},
          keyword()
        ) ::
          :ok
  def record_outcome(route, outcome, opts \\ []) do
    credential_id = route.credential.id
    breaker_opts = Keyword.take(opts, [:epoch, :retry_after_ms, :source])

    case outcome do
      :success ->
        @default_breaker.record_success(credential_id, breaker_opts)

        case Keyword.get(opts, :latency_ms) do
          nil ->
            :ok

          latency_ms ->
            CredentialHealth.record_success(
              credential_id,
              latency_ms,
              Keyword.take(opts, [:streaming])
            )
        end

      {:failure, reason} ->
        record_failure_outcome(route, reason, nil, breaker_opts)

      {:failure, reason, error_message} ->
        record_failure_outcome(route, reason, error_message, breaker_opts)
    end

    :ok
  end

  # Every failure reason feeds the breaker — billing surface no longer makes a
  # 429 special. The breaker's cooldown and the routing cascade provide the
  # fallback a saturated credential needs.
  defp record_failure_outcome(route, reason, error_message, breaker_opts) do
    @default_breaker.record_failure(route.credential.id, reason, error_message, breaker_opts)
  end

  @doc """
  Returns the accessible models for `group_member` shaped for the
  OpenAI-compatible `/v1/models` API.

  The reserved `"router"` alias is appended **only** when the router is on
  (`Tokengate.SmartRouter.enabled?/0`) AND the subject opted in
  (`Tokengate.Accounts.router_enabled?/1`): discovery and authorization are the
  same predicate, so a client never sees an alias the proxy would refuse.
  """
  @spec models_for(map()) :: [map()]
  def models_for(group_member) do
    group_member = maybe_preload_group(group_member)

    models =
      group_member
      |> accessible_models()
      |> Enum.map(fn model_ ->
        %{
          id: model_.name,
          object: "model",
          context_window: model_.context_window,
          model_type: model_.model_type,
          owned_by: "tokengate"
        }
      end)

    if router_visible?(group_member), do: models ++ [router_entry()], else: models
  end

  # The alias is a gateway pseudo-model, not a `models` row: no id, no lane.
  @router_entry %{
    id: "router",
    object: "model",
    model_type: "router",
    owned_by: "tokengate"
  }

  defp router_entry, do: @router_entry

  defp router_visible?(group_member) do
    Tokengate.SmartRouter.enabled?() and Tokengate.Accounts.router_enabled?(group_member)
  rescue
    # Discovery must never break because the router tables/config are missing
    # (a node mid-migration): the alias simply is not advertised.
    _ -> false
  end

  # La consulta de accesibles es un UNION de tres tablas + EXCEPT y se
  # ejecutaba en CADA request (y en cada reintento de la cascada). El cache ETS
  # existe para esto y sus invalidaciones ya están cableadas en
  # `Tokengate.Providers` (grants/revokes de grupo, extras, denies, service y
  # cambios de modelo/proveedor). La clave es (group_id, member_id); un
  # service virtual member no tiene grupo, así que usa `:global` — el mismo
  # contrato con el que el cache invalida por `(nil, service_id)`.
  defp accessible_models(group_member) do
    member_id = group_member && group_member.id

    group_id =
      case group_member do
        %{service_name: name} when is_binary(name) -> nil
        %{group: %{id: id}} -> id
        _ -> nil
      end

    Tokengate.Routing.Cache.fetch_accessible_models(group_id, member_id, fn ->
      Providers.list_accessible_models(group_member)
    end)
  end

  # ---------------------------------------------------------------------------
  # Internal: model resolution
  # ---------------------------------------------------------------------------

  defp route_model(model, group_member, _accessible, request_context, breaker, exclude) do
    # Load model_providers visible to this member (global + their exclusives).
    # The heavy part (join credential + provider, order by priority) is cached
    # per (model_id, group_id) for 60s; disabled credentials are a
    # separate ETS set refreshed every 60s. Both are stale-tolerant because
    # the fallback matrix re-routes on a dead credential anyway.
    model_providers = model_providers_for(model, group_member)

    if model_providers == [] do
      {:error, :no_providers_configured}
    else
      disabled_ids = Tokengate.Routing.Cache.disabled_credential_ids()

      # Expansion comes FIRST: a lane mounted on a credential pool is one row
      # that stands for N keys, so it becomes one candidate per member — a copy
      # of the lane with the member's credential and the lane's id — before the
      # credential/status/exclude/visibility filter and before the breaker is
      # ever asked. Every member is therefore filtered (and breaker-checked) as
      # its own credential, while priority, provider_model, price and scope stay
      # on the lane. A single-key lane expands to itself.
      #
      # Filter out candidates whose credential is excluded, disabled, or
      # missing. Disabled credentials are checked against the cached set so
      # a freshly-disabled credential stops receiving traffic within 60s
      # instead of waiting for the next credential-health sweep.
      # Member-exclusive rows are also dropped for non-owners: the cached
      # list is keyed by group, so without this filter a groupmate would see
      # the owner's exclusive provider.
      candidates =
        model_providers
        |> Pools.expand()
        |> Enum.filter(fn mp ->
          mp.credential != nil and
            mp.credential.status == "active" and
            not MapSet.member?(disabled_ids, mp.credential.id) and
            mp.credential.id not in exclude and
            visible_to_member?(mp, group_member)
        end)

      if candidates == [] do
        {:error, :no_available_provider}
      else
        select_and_build_route(model, candidates, request_context, breaker, exclude)
      end
    end
  end

  # The lane list of `model` as `group_member` may see it, cached per scope.
  # Extracted from `route_model/6` so the router's baseline tariff reads the
  # exact same rows (and cache entry) the route does.
  #
  # The scope is `{:service, service_id}` for a service, the group id for a
  # group member and `:global` only when neither applies. A service MUST NOT
  # share the `:global` entry: two services with their own service-exclusive
  # lane for the same model would otherwise overwrite each other's list for a
  # minute and one of them would see the other's lane.
  defp model_providers_for(model, group_member) do
    group_id = group_id_of(group_member)
    service_id = service_id_of(group_member)

    scope =
      cond do
        service_id -> {:service, service_id}
        group_id -> group_id
        true -> :global
      end

    Tokengate.Routing.Cache.fetch_model_providers(model.id, scope, fn ->
      cond do
        service_id ->
          # Services are group-independent: global rows + their own
          # service-exclusive rows (no group/member exclusives).
          Providers.list_model_providers_for_service(model.id, service_id)

        group_id ->
          # NOTE: the cached list is shared by every member of the group. The
          # member-exclusive provider rows are filtered per-member below in
          # `visible_to_member?/2`, so caching by group_id is safe.
          Providers.list_model_providers_for_member(
            model.id,
            group_member.id,
            group_id
          )

        true ->
          # No group, no service: only the GLOBAL lanes belong in this entry.
          # `list_model_providers/1` returns every row of the model, so an
          # unfiltered list would cache another group's/service's exclusive
          # lane into `:global` and leak it to whoever reads that key.
          Providers.list_model_providers(model.id)
          |> Enum.filter(&global_lane?/1)
      end
    end)
  end

  # A lane with no exclusive scope: routable by any subject with access.
  defp global_lane?(mp) do
    mp.exclusive_to_group_id == nil and mp.exclusive_to_group_member_id == nil and
      mp.exclusive_to_service_id == nil
  end

  # The model row behind `route_by_model_id/4`, cached for a minute. The router
  # resolves by id on every attempted hop of its fallback chain, so without the
  # cache a cascading request would pay one query per lane instead of none
  # (the model ACL path already reads a cached list).
  @model_cache_ttl_ms 60_000

  defp model_by_id(nil), do: nil

  defp model_by_id(model_id) when is_binary(model_id) do
    Tokengate.Cache.fetch({:router_model_by_id, model_id}, @model_cache_ttl_ms, fn ->
      Providers.get_model(model_id)
    end)
  end

  defp model_by_id(_), do: nil

  defp select_and_build_route(model, candidates, request_context, breaker, exclude) do
    # Use side-effect-free usable?/1 when supported so Priority (Enum.filter on
    # pools, sticky checks) never consumes a :half_open probe slot during
    # selection. Probe lease acquisition happens right before the upstream HTTP
    # call in ProxyController.
    use_usable? = Code.ensure_loaded?(breaker) and function_exported?(breaker, :usable?, 1)

    available? = fn ap ->
      if use_usable?,
        do: breaker.usable?(ap.credential.id),
        else: breaker.allow?(ap.credential.id)
    end

    # Mark exclusive providers with priority -1 so they always come first.
    # The boost lands on the copies (a pool lane's members inherit it), so an
    # exclusive lane mounted on a pool still outranks every global lane.
    candidates = inject_exclusive_priority(candidates)

    # Group back by lane: the selector ranks lanes (health, priority) and only
    # then chooses inside the winning lane — rotation for a pool, sticky for a
    # single key.
    groups = Pools.group(candidates)

    strategy_opts = %{
      api_key_hash: Map.get(request_context, :api_key_hash),
      model_id: model.id,
      available?: available?,
      # Las credenciales que la cascada ya intentó: los candidatos ya se
      # filtraron arriba, pero el selector necesita los ids para contar los
      # MIEMBROS del pool que quedaron fuera y saltar el grupo agotado
      # (`Pools.exhausted?/2`). Sale del MISMO `exclude` que alimentó el
      # filtro (request_context + opts), no de una relectura del contexto.
      exclude_ids: exclude
    }

    case Priority.select_groups(groups, strategy_opts) do
      {:ok, model_provider} ->
        credential = model_provider.credential

        {:ok,
         %{
           model: model,
           model_provider: model_provider,
           credential: credential,
           model_responded:
             normalize_model_responded(model_provider.provider_model, credential.provider)
         }}

      {:error, :no_available_provider} = error ->
        error
    end
  end

  # Inject exclusive providers with priority -1 so they are always selected
  # first by the priority strategy. Global providers keep their configured priority.
  defp inject_exclusive_priority(candidates) do
    Enum.map(candidates, fn mp ->
      if mp.exclusive_to_group_member_id != nil || mp.exclusive_to_group_id != nil ||
           mp.exclusive_to_service_id != nil do
        %{mp | priority: -1}
      else
        mp
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # El id que viaja en el body del upstream, tal como el proveedor lo publica.
  # El prefijo de lab de models.dev NO se desprefija: para los proveedores
  # cuyo prefijo ES parte del id (OpenRouter: `z-ai/glm-5.2` es su forma
  # canónica) quitarlo rompería la petición.
  defp normalize_model_responded(provider_model, _provider), do: provider_model

  defp find_alias_by_name(accessible, name) do
    Enum.find(accessible, fn model_ -> model_.name == name end)
  end

  # Exclusive scoping for the cached provider list. A cached entry is keyed by
  # (model_id, scope), so the raw list may still contain providers exclusive to
  # ANOTHER consumer: the group entry may carry a provider exclusive to a
  # different member of the group, and `:global`/a corrupted entry may carry
  # one exclusive to any group or service. Global rows (all exclusive fields
  # nil) and group-exclusive rows of the SAME group are visible to everyone in
  # that group; member-exclusive rows only to their owner; group-exclusive rows
  # only to a member of that group; service-exclusive rows only to their
  # service.
  defp visible_to_member?(mp, group_member) do
    cond do
      mp.exclusive_to_service_id != nil ->
        service_id_of(group_member) == mp.exclusive_to_service_id

      # Same rule `service_id` and `group_member_id` already follow: a lane
      # scoped to a group is invisible outside it, whatever list it arrived in.
      mp.exclusive_to_group_id != nil ->
        group_id_of(group_member) == mp.exclusive_to_group_id

      true ->
        case mp.exclusive_to_group_member_id do
          nil -> true
          member_id -> group_member != nil and group_member.id == member_id
        end
    end
  end

  # Service virtual members carry the service's id as their group_member id.
  defp service_id_of(%{service_name: name} = group_member) when is_binary(name),
    do: group_member.id

  defp service_id_of(_), do: nil

  # The group a member routes as. A service virtual member has NO group even
  # when a caller passes one: its lanes are service/global scoped only.
  defp group_id_of(%{service_name: name}) when is_binary(name), do: nil

  defp group_id_of(%{group: %{id: id}}), do: id
  defp group_id_of(_), do: nil

  defp maybe_preload_group(%{service_name: name} = group_member) when is_binary(name),
    do: group_member

  defp maybe_preload_group(group_member) do
    cond do
      group_member.group != nil and Ecto.assoc_loaded?(group_member.group) ->
        group_member

      true ->
        Tokengate.Repo.preload(group_member, [:group], force: true)
    end
  end

  defp exclude_ids(request_context, opts) do
    from_opts = Keyword.get(opts, :exclude_credential_ids, [])
    from_ctx = Map.get(request_context, :exclude_credential_ids, [])

    List.wrap(from_opts) ++ List.wrap(from_ctx)
  end
end
