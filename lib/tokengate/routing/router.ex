defmodule Tokengate.Routing.Router do
  @moduledoc """
  Resolves a requested model name to a concrete provider credential, applying
  access control, routing-rule reroutes, strategy-based provider selection,
  and circuit-breaker availability filtering.

  ## Public API

    * `route/3`  – resolve a `model_requested` for a `team_member`, returning a
      route map with the selected `alias_provider`, `credential`, and
      `model_responded` (the upstream model string).
    * `record_outcome/2` – record a success or failure against the selected
      credential's circuit breaker.
    * `models_for/1` – shape the accessible aliases for the `/v1/models` API.

  ## Access control

  A team member can only route to aliases returned by
  `Tokengate.Providers.list_accessible_aliases/1` — the union of aliases
  granted to their team plus any extra aliases granted to them individually.
  Routing-rule reroute targets must *also* be accessible or the rule is skipped.

  ## Strategy dispatch

  The alias's `routing_strategy` ("priority" or "round_robin") selects the
  strategy module. Strategies receive an `available?` predicate built from the
  circuit breaker so they never call the breaker directly.

  ## Fallback / retry

  Callers may pass `:exclude_credential_ids` in `request_context` (or as a
  keyword option to `route/3`) to drop credentials from the candidate set —
  used to retry on a different provider after a failure without re-selecting
  the same (now failed) credential.
  """

  alias Tokengate.Providers
  alias Tokengate.Proxy.TokenEstimator
  alias Tokengate.Routing.CircuitBreakerManager
  alias Tokengate.Routing.Priority
  alias Tokengate.Routing.RoundRobin

  @type route :: %{
          model_alias: Tokengate.Providers.ModelAlias.t(),
          alias_provider: Tokengate.Providers.AliasProvider.t(),
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

  defp route_alias(model_alias, team_member, accessible, request_context, breaker, exclude) do
    org_id = org_id_for(team_member, model_alias)
    messages = Map.get(request_context, "messages", [])

    # Evaluate routing rules: first match reroutes to its target alias,
    # which must also be in the accessible set.
    resolved_alias =
      case evaluate_routing_rules(org_id, accessible, messages) do
        nil -> model_alias
        target -> target
      end

    # Load enabled alias_providers for the (possibly rerouted) alias.
    alias_providers = Providers.list_alias_providers(resolved_alias.id)

    if alias_providers == [] do
      {:error, :no_providers_configured}
    else
      # Attach the active credential to each alias_provider and drop those
      # without one (or whose credential is excluded).
      candidates =
        alias_providers
        |> Enum.map(fn ap ->
          credential = Providers.active_credential(ap.provider_id)
          {ap, credential}
        end)
        |> Enum.filter(fn {_ap, credential} ->
          credential != nil and credential.id not in exclude
        end)
        |> Enum.map(fn {ap, credential} ->
          Map.put(ap, :credential, credential)
        end)

      if candidates == [] do
        {:error, :no_available_provider}
      else
        select_and_build_route(resolved_alias, candidates, request_context, breaker)
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

    strategy = strategy_module(model_alias.routing_strategy)

    case strategy.select(candidates, strategy_opts) do
      {:ok, alias_provider} ->
        credential = alias_provider.credential

        {:ok,
         %{
           model_alias: model_alias,
           alias_provider: alias_provider,
           credential: credential,
           model_responded: alias_provider.provider_model
         }}

      {:error, :no_available_provider} = error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Routing-rule evaluation
  # ---------------------------------------------------------------------------

  defp evaluate_routing_rules(org_id, accessible, messages) do
    rules = Providers.list_enabled_rules_for_org(org_id)
    accessible_ids = MapSet.new(accessible, & &1.id)

    Enum.find_value(rules, fn rule ->
      target = rule.target_alias

      # Target must be accessible; if not, skip the rule.
      if target != nil and MapSet.member?(accessible_ids, target.id) do
        if rule_matches?(rule.conditions, messages) do
          target
        else
          nil
        end
      else
        nil
      end
    end)
  end

  defp rule_matches?(conditions, messages) do
    Enum.all?(conditions, fn
      {"context_length", op_str} ->
        context_length_matches?(op_str, messages)

      {"has_images", expected} ->
        has_images?(messages) == truthy?(expected)

      {_unknown, _value} ->
        true
    end)
  end

  defp context_length_matches?(op_str, messages) do
    with {op, n} <- parse_op(op_str) do
      estimate =
        if is_list(messages) and messages != [],
          do: TokenEstimator.estimate_messages(messages),
          else: 0

      compare(estimate, op, n)
    else
      :error -> false
    end
  end

  # Parses strings like "> 100000", "< 1000", ">= 50000".
  defp parse_op(str) when is_binary(str) do
    str = String.trim(str)

    case str do
      ">" <> rest -> parse_number(rest, :>)
      "<" <> rest -> parse_number(rest, :<)
      ">=" <> rest -> parse_number(rest, :>=)
      "<=" <> rest -> parse_number(rest, :<=)
      "==" <> rest -> parse_number(rest, :==)
      _ -> :error
    end
  end

  defp parse_number(rest, op) do
    case Integer.parse(String.trim(rest)) do
      {n, ""} -> {op, n}
      _ -> :error
    end
  end

  defp compare(left, :>, right), do: left > right
  defp compare(left, :<, right), do: left < right
  defp compare(left, :>=, right), do: left >= right
  defp compare(left, :<=, right), do: left <= right
  defp compare(left, :==, right), do: left == right

  defp has_images?(messages) when is_list(messages) do
    Enum.any?(messages, fn message ->
      content = Map.get(message, "content")

      is_list(content) and
        Enum.any?(content, fn
          %{"type" => "image_url"} -> true
          _ -> false
        end)
    end)
  end

  defp has_images?(_), do: false

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp find_alias_by_name(accessible, name) do
    Enum.find(accessible, fn alias_ -> alias_.name == name end)
  end

  defp strategy_module("priority"), do: Priority
  defp strategy_module("round_robin"), do: RoundRobin

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

  defp org_id_for(team_member, model_alias) do
    cond do
      team_member.team != nil and team_member.team.organization_id != nil ->
        team_member.team.organization_id

      model_alias.organization_id != nil ->
        model_alias.organization_id

      true ->
        nil
    end
  end

  defp exclude_ids(request_context, opts) do
    from_opts = Keyword.get(opts, :exclude_credential_ids, [])
    from_ctx = Map.get(request_context, :exclude_credential_ids, [])

    List.wrap(from_opts) ++ List.wrap(from_ctx)
  end
end
