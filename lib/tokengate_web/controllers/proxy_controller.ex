defmodule TokengateWeb.ProxyController do
  @moduledoc """
  OpenAI-compatible proxy API.

    * `GET /v1/models` — only the model aliases the API key can access
      (team grants + individual extras), each with its `context_window`.
    * `POST /v1/chat/completions` — transparent passthrough to the routed
      provider with full cost tracking. The response `usage` object gains
      `estimated_cost_usd` (market price) and `cost_usd` (provider price),
      plus `X-Tokengate-Cost` / `X-Tokengate-Savings` headers.

  Hot path discipline: auth, limits, budgets and routing read from
  ETS/atomics only. Postgres is touched asynchronously via Oban
  (`Tokengate.Logs.WriteWorker`).
  """

  use TokengateWeb, :controller

  alias Tokengate.Accounts
  alias Tokengate.Budgets.Manager, as: Budgets
  alias Tokengate.Limits.Manager, as: Limits
  alias Tokengate.Logs.WriteWorker
  alias Tokengate.Metrics.Collector
  alias Tokengate.Providers
  alias Tokengate.Proxy.{CostCalculator, OpenAIAdapter, TokenEstimator, UsageNormalizer}
  alias Tokengate.Routing.Router

  @max_attempts 3
  @default_completion_estimate 512

  @doc """
  Lists the model aliases accessible to the authenticated API key.
  """
  def models(conn, _params) do
    member = conn.assigns.current_team_member
    json(conn, %{"object" => "list", "data" => Router.models_for(member)})
  end

  @doc """
  Proxies a chat completion request to the routed provider.
  """
  def chat_completions(conn, _params) do
    member = conn.assigns.current_team_member
    payload = conn.body_params
    model = payload["model"]
    limits = Accounts.effective_limits(member)
    key_id = member.api_key.id

    with :ok <- require_model(model),
         :ok <- acquire_limits(key_id, limits) do
      try do
        case route_and_check(member, payload, conn.assigns.api_key_hash, limits) do
          {:ok, route} -> execute(conn, route, payload, member, @max_attempts, [])
          {:error, error} -> render_proxy_error(conn, error)
        end
      after
        Limits.release(key_id)
      end
    else
      {:error, error} -> render_proxy_error(conn, error)
    end
  end

  ## Pipeline steps ############################################################

  defp require_model(nil), do: {:error, {:invalid_request, "model is required"}}
  defp require_model(model) when is_binary(model), do: :ok
  defp require_model(_), do: {:error, {:invalid_request, "model must be a string"}}

  defp acquire_limits(key_id, limits) do
    case Limits.acquire(key_id, %{
           rpm_limit: limits.rpm_limit,
           concurrency_limit: limits.concurrency_limit
         }) do
      :ok -> :ok
      {:error, :rate_limited, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
      {:error, :concurrency_exceeded} -> {:error, :concurrency_exceeded}
    end
  end

  defp route_and_check(member, payload, api_key_hash, limits) do
    request_context = %{
      "messages" => payload["messages"] || [],
      :api_key_hash => api_key_hash
    }

    with {:ok, route} <- Router.route(payload["model"], member, request_context),
         :ok <- check_budget(member, limits, route, payload) do
      {:ok, route}
    end
  end

  defp check_budget(member, limits, route, payload) do
    estimated_usage = estimated_usage(payload)
    estimated_cost = CostCalculator.market_cost(route.model_alias, estimated_usage)

    case Budgets.check(
           member.id,
           limits.daily_budget_usd,
           limits.monthly_budget_usd,
           estimated_cost
         ) do
      :ok -> :ok
      {:error, :budget_exceeded, details} -> {:error, {:budget_exceeded, details}}
    end
  end

  ## Provider execution with fallback ##########################################

  defp execute(conn, route, payload, member, attempts_left, exclude) do
    provider = route.alias_provider.provider

    case OpenAIAdapter.chat_completion(provider, route.credential, payload) do
      {:ok, body, latency_ms} ->
        Router.record_outcome(route, :success)
        finalize_success(conn, route, body, latency_ms, member)

      {:error, :client_error, status} ->
        # 4xx from the provider: the caller's payload is at fault — surface
        # it without burning the breaker or trying other providers.
        Router.record_outcome(route, {:failure, :client_error})
        render_proxy_error(conn, {:upstream_client_error, status})

      {:error, reason, status} ->
        Router.record_outcome(route, {:failure, breaker_reason(reason)})

        if attempts_left > 1 do
          retry_with_fallback(conn, route, payload, member, attempts_left, exclude, status)
        else
          render_proxy_error(conn, {:upstream_error, reason, status})
        end
    end
  end

  defp retry_with_fallback(conn, route, payload, member, attempts_left, exclude, _status) do
    exclude = [route.credential.id | exclude]

    request_context = %{
      "messages" => payload["messages"] || [],
      :api_key_hash => conn.assigns.api_key_hash,
      :exclude_credential_ids => exclude
    }

    case Router.route(payload["model"], member, request_context) do
      {:ok, new_route} ->
        execute(conn, new_route, payload, member, attempts_left - 1, exclude)

      {:error, :no_available_provider} ->
        render_proxy_error(conn, :all_providers_down)

      {:error, error} ->
        render_proxy_error(conn, error)
    end
  end

  ## Success finalization #######################################################

  defp finalize_success(conn, route, body, latency_ms, member) do
    usage = UsageNormalizer.normalize(:openai, body) || fallback_usage(conn.body_params, body)
    pricing = Providers.current_pricing(route.alias_provider.id)
    billing_type = route.alias_provider.provider.billing_type

    costs = CostCalculator.breakdown(route.model_alias, pricing, billing_type, usage)

    # Hot-path state updates (ETS only)
    Budgets.record_spend(member.id, costs.cost_usd)

    Collector.record_request(%{
      model_alias_id: route.model_alias.id,
      provider_id: route.alias_provider.provider_id,
      agent_type: conn.assigns.agent_type,
      status: 200,
      latency_ms: latency_ms,
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      cost_usd: costs.cost_usd,
      savings_usd: costs.savings_usd,
      streaming: false
    })

    # Durable log + webhooks, async via Oban
    enqueue_log(route, member, conn.assigns.agent_type, usage, costs, latency_ms, 200, false)

    body = inject_usage_costs(body, usage, costs)

    conn
    |> put_resp_header("x-tokengate-cost", Decimal.to_string(costs.cost_usd, :normal))
    |> put_resp_header("x-tokengate-savings", Decimal.to_string(costs.savings_usd, :normal))
    |> json(body)
  end

  defp inject_usage_costs(body, usage, costs) do
    response_usage =
      body
      |> Map.get("usage", %{})
      |> Map.merge(%{
        "prompt_tokens" => usage.prompt_tokens,
        "completion_tokens" => usage.completion_tokens,
        "estimated_cost_usd" => Decimal.to_float(costs.estimated_cost_usd),
        "cost_usd" => Decimal.to_float(costs.cost_usd)
      })

    Map.put(body, "usage", response_usage)
  end

  defp fallback_usage(payload, body) do
    completion_text =
      case get_in(body, ["choices", Access.at(0), "message", "content"]) do
        text when is_binary(text) -> text
        _ -> ""
      end

    %{
      prompt_tokens: TokenEstimator.estimate_messages(payload["messages"] || []),
      completion_tokens: TokenEstimator.estimate_completion(completion_text),
      cache_read_tokens: 0,
      cache_creation_tokens: 0
    }
  end

  defp estimated_usage(payload) do
    %{
      prompt_tokens: TokenEstimator.estimate_messages(payload["messages"] || []),
      completion_tokens: payload["max_tokens"] || @default_completion_estimate,
      cache_read_tokens: 0,
      cache_creation_tokens: 0
    }
  end

  defp enqueue_log(route, member, agent_type, usage, costs, latency_ms, status, streaming) do
    %{
      "team_member_id" => member.id,
      "provider_id" => route.alias_provider.provider_id,
      "model_alias_id" => route.model_alias.id,
      "subscription_id" => route.alias_provider.subscription_id,
      "model_requested" => route.model_alias.name,
      "model_responded" => route.model_responded,
      "agent_type" => agent_type,
      "status_code" => status,
      "prompt_tokens" => usage.prompt_tokens,
      "completion_tokens" => usage.completion_tokens,
      "cost_usd" => Decimal.to_string(costs.cost_usd, :normal),
      "provider_cost_usd" => Decimal.to_string(costs.provider_cost_usd, :normal),
      "savings_usd" => Decimal.to_string(costs.savings_usd, :normal),
      "estimated_cost_usd" => Decimal.to_string(costs.estimated_cost_usd, :normal),
      "latency_ms" => latency_ms,
      "streaming" => streaming
    }
    |> WriteWorker.new()
    |> Oban.insert()
  end

  ## Errors ######################################################################

  defp breaker_reason(:timeout), do: :timeout
  defp breaker_reason(:rate_limited), do: :rate_limited
  defp breaker_reason(:connection_error), do: :server_error
  defp breaker_reason(:server_error), do: :server_error
  defp breaker_reason(_), do: :server_error

  defp render_proxy_error(conn, error) do
    {status, type, code, message} = error_details(error)

    body = %{"error" => %{"message" => message, "type" => type, "code" => code}}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp error_details({:invalid_request, msg}),
    do: {400, "invalid_request_error", "invalid_request", msg}

  defp error_details({:rate_limited, retry_ms}),
    do: {429, "rate_limit_error", "rate_limited", "Rate limit exceeded, retry in #{retry_ms}ms"}

  defp error_details(:concurrency_exceeded),
    do: {429, "rate_limit_error", "concurrency_exceeded", "Too many concurrent requests"}

  defp error_details({:budget_exceeded, %{period: period}}),
    do: {402, "billing_error", "budget_exceeded", "Budget exceeded (#{period})"}

  defp error_details(:model_not_found),
    do: {404, "invalid_request_error", "model_not_found", "Model not found or not accessible"}

  defp error_details(:no_providers_configured),
    do: {503, "service_unavailable", "no_providers", "No providers configured for this model"}

  defp error_details(:no_available_provider),
    do:
      {503, "service_unavailable", "no_available_provider",
       "All providers are currently unavailable"}

  defp error_details(:all_providers_down),
    do: {503, "service_unavailable", "all_providers_down", "All providers failed"}

  defp error_details({:upstream_client_error, status}),
    do:
      {status, "invalid_request_error", "upstream_client_error",
       "Provider rejected the request (#{status})"}

  defp error_details({:upstream_error, reason, status}),
    do: {upstream_status(status), "api_error", to_string(reason), "Upstream provider error"}

  defp error_details(other), do: {500, "api_error", "internal_error", inspect(other)}

  defp upstream_status(status) when is_integer(status) and status in 400..599, do: status
  defp upstream_status(_), do: 502
end
