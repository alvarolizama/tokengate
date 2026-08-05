defmodule Tokengate.Routing.Router do
  @moduledoc """
  Resolves a requested model name to a concrete provider credential, applying
  access control, strategy-based provider selection, and circuit-breaker
  availability filtering.

  ## Public API

    * `route/3`  – resolve a `model_requested` for a `team_member`, returning a
      route map with the selected `model_provider`, `credential`, and
      `model_responded` (the upstream model string).
    * `record_outcome/2` – record a success or failure against the selected
      credential's circuit breaker.
    * `models_for/1` – shape the accessible aliases for the `/v1/models` API.

  ## Access control

  A team member can only route to aliases returned by
  `Tokengate.Providers.list_accessible_aliases/1` — the union of aliases
  granted to their team plus any extra aliases granted to them individually.

  ## Provider selection

  Priority-based selection with sticky routing: the first available
  provider (by priority ASC) is chosen, and the same API key sticks to
  the same provider to preserve prompt caches. Strategies receive an
  `available?` predicate built from the circuit breaker so they never
  call the breaker directly.

  ### Exclusive scope

  Providers can be scoped to serve only specific consumers:
    * Global (no scope) — available to all members with access.
    * Member-exclusive — only the specified team member sees it.
    * Team-exclusive — only members of the specified team see it.

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
  alias Tokengate.Routing.Priority

  @type route :: %{
          model_alias: Tokengate.Providers.ModelAlias.t(),
          model_provider: Tokengate.Providers.ModelProvider.t(),
          credential: Tokengate.Providers.Credential.t(),
          model_responded: String.t()
        }

  @default_breaker CircuitBreakerManager

  @doc """
  Resolves `model_requested` for `team_member`, returning a route map.

  ## Options (`request_context`)

    * `"messages"` – list of OpenAI-style messages, used for routing-rule
      condition evaluation (context length, image presence).
    * `:api_key_hash` – opaque hash identifying the API key (for sticky
      routing under the priority strategy). May be nil.
    * `:exclude_credential_ids` – list of credential ids to exclude from
      candidates (retry-after-failure fallback). May also be passed as a
      keyword option to `route/3`.
    * `:breaker` – a module implementing the breaker API
      (`allow?/1`, `record_success/1`, `record_failure/2`) used in place of
      `CircuitBreakerManager` (test injection). Defaults to the real manager.
    * `:capability` – the required `model_type` of the alias (`"llm"`,
      `"embedding"`, `"rerank"`). Defaults to `"llm"` (chat completions).
      When the alias exists but its `model_type` differs, returns
      `{:error, :model_type_mismatch}`.

  ## Returns

    * `{:ok, route}` – the resolved route.
    * `{:error, :model_not_found}` – no accessible alias with that name.
    * `{:error, :model_type_mismatch}` – alias exists but serves a
      different capability than requested.
    * `{:error, :no_providers_configured}` – alias has no enabled alias providers.
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
  def route(model_requested, team_member, request_context \\ %{}, opts \\ []) do
    breaker = Keyword.get(opts, :breaker, Map.get(request_context, :breaker, @default_breaker))
    exclude = exclude_ids(request_context, opts)
    capability = Map.get(request_context, :capability, "llm")

    # Ensure team is preloaded (callers may not have preloaded it).
    team_member = maybe_preload_team(team_member)

    accessible = Providers.list_accessible_aliases(team_member)

    case find_alias_by_name(accessible, model_requested) do
      nil ->
        {:error, :model_not_found}

      %{model_type: type} when type != capability ->
        {:error, :model_type_mismatch}

      model_alias ->
        route_alias(model_alias, team_member, accessible, request_context, breaker, exclude)
    end
  end

  @doc """
  Records the outcome of a routed request against the selected credential's
  circuit breaker, and — for successes — against the credential's soft
  health (`Tokengate.Routing.CredentialHealth`).

    * `:success` → `breaker.record_success(credential.id)`. When
      `:latency_ms` is passed in `opts`, a slow success degrades the
      credential (it sinks within its routing tier) and a fast one heals it.
    * `{:failure, reason}` → `breaker.record_failure(credential.id, reason)`.

  Always returns `:ok`. The caller decides whether to re-route (using
  `:exclude_credential_ids` to skip the failed credential) or surface the
  error to the client.

  `reason` is one of `:server_error`, `:timeout`, `:rate_limited`,
  `:client_error`.

  ## Options

    * `:latency_ms` — end-to-end latency of a successful upstream call.
      Compared against `slow_threshold_ms` (config `:tokengate, :routing`).
  """
  @spec record_outcome(route(), :success | {:failure, atom()}, keyword()) :: :ok
  def record_outcome(route, outcome, opts \\ []) do
    credential_id = route.credential.id

    case outcome do
      :success ->
        @default_breaker.record_success(credential_id)

        case Keyword.get(opts, :latency_ms) do
          nil -> :ok
          latency_ms -> CredentialHealth.record_success(credential_id, latency_ms)
        end

      {:failure, reason} ->
        @default_breaker.record_failure(credential_id, reason)
    end

    :ok
  end

  @doc """
  Returns the accessible aliases for `team_member` shaped for the
  OpenAI-compatible `/v1/models` API.
  """
  @spec models_for(map()) :: [map()]
  def models_for(team_member) do
    team_member = maybe_preload_team(team_member)

    team_member
    |> Providers.list_accessible_aliases()
    |> Enum.map(fn alias_ ->
      %{
        id: alias_.name,
        object: "model",
        context_window: alias_.context_window,
        model_type: alias_.model_type,
        owned_by: "tokengate"
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Internal: alias resolution + routing-rule evaluation
  # ---------------------------------------------------------------------------

  defp route_alias(model_alias, team_member, _accessible, request_context, breaker, exclude) do
    # Load model_providers visible to this member (global + their exclusives).
    model_providers =
      if team_member && team_member.team && team_member.team.id do
        Providers.list_model_providers_for_member(
          model_alias.id,
          team_member.id,
          team_member.team.id
        )
      else
        # Fallback: no team context (e.g. service members), global only
        Providers.list_model_providers(model_alias.id)
      end

    if model_providers == [] do
      {:error, :no_providers_configured}
    else
      # Filter out candidates whose credential is excluded or disabled.
      candidates =
        model_providers
        |> Enum.filter(fn mp ->
          mp.credential != nil and
            mp.credential.status == "active" and
            mp.credential.id not in exclude
        end)

      if candidates == [] do
        {:error, :no_available_provider}
      else
        select_and_build_route(model_alias, candidates, request_context, breaker)
      end
    end
  end

  defp select_and_build_route(model_alias, candidates, request_context, breaker) do
    available? = fn ap ->
      breaker.allow?(ap.credential.id)
    end

    # Mark exclusive providers with priority -1 so they always come first
    candidates = inject_exclusive_priority(candidates)

    strategy_opts = %{
      api_key_hash: Map.get(request_context, :api_key_hash),
      model_alias_id: model_alias.id,
      available?: available?
    }

    case Priority.select(candidates, strategy_opts) do
      {:ok, model_provider} ->
        credential = model_provider.credential

        {:ok,
         %{
           model_alias: model_alias,
           model_provider: model_provider,
           credential: credential,
           model_responded: model_provider.provider_model
         }}

      {:error, :no_available_provider} = error ->
        error
    end
  end

  # Inject exclusive providers with priority -1 so they are always selected
  # first by the priority strategy. Global providers keep their configured priority.
  defp inject_exclusive_priority(candidates) do
    Enum.map(candidates, fn mp ->
      if mp.exclusive_to_team_member_id != nil || mp.exclusive_to_team_id != nil do
        %{mp | priority: -1}
      else
        mp
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp find_alias_by_name(accessible, name) do
    Enum.find(accessible, fn alias_ -> alias_.name == name end)
  end

  defp maybe_preload_team(team_member) do
    # Always force-preload the team association to guarantee it's populated.
    Tokengate.Repo.preload(team_member, [:team], force: true)
  end

  defp exclude_ids(request_context, opts) do
    from_opts = Keyword.get(opts, :exclude_credential_ids, [])
    from_ctx = Map.get(request_context, :exclude_credential_ids, [])

    List.wrap(from_opts) ++ List.wrap(from_ctx)
  end
end
