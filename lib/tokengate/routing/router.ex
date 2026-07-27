defmodule Tokengate.Routing.Router do
  @moduledoc """
  Resolves a requested model name to a concrete provider credential, applying
  access control, routing-rule reroutes, strategy-based provider selection,
  and circuit-breaker availability filtering.

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
  Routing-rule reroute targets must *also* be accessible or the rule is skipped.

  ## Provider selection

  Priority-based selection with sticky routing: the first available
  provider (by priority ASC) is chosen, and the same API key sticks to
  the same provider to preserve prompt caches. Strategies receive an
  `available?` predicate built from the circuit breaker so they never
  call the breaker directly.

  ## Fallback / retry

  Callers may pass `:exclude_credential_ids` in `request_context` (or as a
  keyword option to `route/3`) to drop credentials from the candidate set —
  used to retry on a different provider after a failure without re-selecting
  the same (now failed) credential.
  """

  alias Tokengate.Providers
  alias Tokengate.Routing.CircuitBreakerManager
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

  ## Returns

    * `{:ok, route}` – the resolved route.
    * `{:error, :model_not_found}` – no accessible alias with that name.
    * `{:error, :no_providers_configured}` – alias has no enabled alias providers.
    * `{:error, :no_available_provider}` – all candidates were filtered out
      (no active credential, breaker open, or excluded).

  """
  @spec route(String.t(), map(), map(), keyword()) ::
          {:ok, route()}
          | {:error, :model_not_found | :no_providers_configured | :no_available_provider}
  def route(model_requested, team_member, request_context \\ %{}, opts \\ []) do
    breaker = Keyword.get(opts, :breaker, Map.get(request_context, :breaker, @default_breaker))
    exclude = exclude_ids(request_context, opts)

    # Ensure team is preloaded (callers may not have preloaded it).
    team_member = maybe_preload_team(team_member)

    accessible = Providers.list_accessible_aliases(team_member)

    case find_alias_by_name(accessible, model_requested) do
      nil ->
        {:error, :model_not_found}

      model_alias ->
        route_alias(model_alias, team_member, accessible, request_context, breaker, exclude)
    end
  end

  @doc """
  Records the outcome of a routed request against the selected credential's
  circuit breaker.

    * `:success` → `breaker.record_success(credential.id)`
    * `{:failure, reason}` → `breaker.record_failure(credential.id, reason)`

  Always returns `:ok`. The caller decides whether to re-route (using
  `:exclude_credential_ids` to skip the failed credential) or surface the
  error to the client.

  `reason` is one of `:server_error`, `:timeout`, `:rate_limited`,
  `:client_error`.
  """
  @spec record_outcome(route(), :success | {:failure, atom()}) :: :ok
  def record_outcome(route, outcome) do
    credential_id = route.credential.id

    case outcome do
      :success ->
        @default_breaker.record_success(credential_id)

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
        owned_by: "tokengate"
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Internal: alias resolution + routing-rule evaluation
  # ---------------------------------------------------------------------------

  defp route_alias(model_alias, _team_member, _accessible, request_context, breaker, exclude) do
    # Load enabled model_providers for the alias (with credential preloaded).
    model_providers = Providers.list_model_providers(model_alias.id)

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

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp find_alias_by_name(accessible, name) do
    Enum.find(accessible, fn alias_ -> alias_.name == name end)
  end

  defp maybe_preload_team(team_member) do
    # Reload the team association if it is not already a populated struct.
    team = Map.get(team_member, :team)

    if is_map(team) and Map.has_key?(team, :id) and team.id != nil do
      team_member
    else
      # force: true re-loads the association even if it was previously set to nil.
      Tokengate.Repo.preload(team_member, [:team], force: true)
    end
  end

  defp exclude_ids(request_context, opts) do
    from_opts = Keyword.get(opts, :exclude_credential_ids, [])
    from_ctx = Map.get(request_context, :exclude_credential_ids, [])

    List.wrap(from_opts) ++ List.wrap(from_ctx)
  end
end
