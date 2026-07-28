defmodule TokengateWeb.ProxyController do
  @moduledoc """
  OpenAI-compatible proxy API.

    * `GET /v1/models` — only the model aliases the API key can access
      (team grants + individual extras), each with its `context_window`.
    * `POST /v1/chat/completions` — transparent passthrough to the routed
      provider with full cost tracking. The response `usage` object gains
      `estimated_cost_usd` (market price) and `cost_usd` (provider price),
      plus `X-Tokengate-Cost` / `X-Tokengate-Savings` headers.

  ## Two-gate throttling

  Requests pass through two independent throttle layers:

    1. **Team limits** — protects TokenGate from abusive users (client-side).
       Limits are derived from team defaults + member overrides and keyed by
       the user's API key.

    2. **Credential limits** — protects the provider API key from upstream
       rate limits (provider-side). Limits are configured per credential
       (`max_rpm`, `max_concurrent`) and keyed by credential.id.

  Both gates must pass for a request to proceed. Team limits are acquired
  first; if routing succeeds, credential limits are acquired before execution.

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
         :ok <- acquire_team_limits(key_id, limits) do
      try do
        case route_and_check(member, payload, conn.assigns.api_key_hash, limits) do
          {:ok, route} ->
            # Second gate: credential limits (provider-side throttling)
            case acquire_credential_limits(route.credential) do
              :ok ->
                {conn, inflight} = register_inflight(conn, member, payload, route)

                try do
                  if payload["stream"] == true do
                    execute_stream(conn, route, payload, member, @max_attempts, [])
                  else
                    execute(conn, route, payload, member, @max_attempts, [])
                  end
                after
                  Tokengate.Logs.Inflight.finish_request(inflight.id)
                  release_credential_limits(route.credential)
                end

              {:error, error} ->
                render_proxy_error(conn, error)
            end

          {:error, error} ->
            render_proxy_error(conn, error)
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

  defp acquire_team_limits(key_id, limits) do
    case Limits.acquire(key_id, %{
           rpm_limit: limits.rpm_limit,
           concurrency_limit: limits.concurrency_limit
         }) do
      :ok -> :ok
      {:error, :rate_limited, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
      {:error, :concurrency_exceeded} -> {:error, :concurrency_exceeded}
    end
  end

  defp acquire_credential_limits(credential) do
    # Use credential.id as the throttle key for provider-side limits
    # nil limits mean unlimited (track but don't block)
    case Limits.acquire(credential.id, %{
           rpm_limit: credential.max_rpm,
           concurrency_limit: credential.max_concurrent
         }) do
      :ok ->
        :ok

      {:error, :rate_limited, retry_after_ms} ->
        {:error, {:provider_rate_limited, retry_after_ms}}

      {:error, :concurrency_exceeded} ->
        {:error, :provider_concurrency_exceeded}
    end
  end

  defp release_credential_limits(credential) do
    Limits.release(credential.id)
  end

  # Registers the request in the in-flight registry so the Logs UI shows it
  # as "Pending" while it executes. Also parses think/effort from the payload
  # and stashes them in conn assigns for the durable log.
  # Returns `{conn, entry}` — the conn carries the think/effort assigns.
  defp register_inflight(conn, member, payload, route) do
    {think, effort} = Tokengate.Proxy.Reasoning.parse(payload)

    conn =
      conn
      |> assign(:think, think)
      |> assign(:effort, effort)

    entry =
      Tokengate.Logs.Inflight.start_request(%{
        team_member_id: member.id,
        user_email: member.user && member.user.email,
        team_name: member.team && member.team.name,
        model_requested: payload["model"],
        agent_type: conn.assigns.agent_type,
        streaming: payload["stream"] == true,
        think: think,
        effort: effort,
        provider_name: route.model_provider.credential.provider.name,
        api_key_prefix: member.api_key && member.api_key.key_prefix,
        credential_name: route.credential.name
      })

    {conn, entry}
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

  defp check_budget(member, _limits, route, payload) do
    estimated_usage = estimated_usage(payload)
    estimated_cost = CostCalculator.market_cost(route.model_alias, estimated_usage)

    # 3-level ladder: team pool → extra general → extra per model
    member_ids = Accounts.list_member_ids_for_team(member.team_id)
    team_daily = member.team && member.team.default_daily_budget_usd

    team_spend_usd =
      if team_daily do
        Budgets.team_spend(member_ids)
      else
        Decimal.new(0)
      end

    member_extra = member.extra_daily_budget_usd
    model_extra = Accounts.extra_model_daily_budget(member.id, route.model_alias.id)

    case Budgets.check_ladder(
           team_daily,
           team_spend_usd,
           member_extra,
           model_extra,
           estimated_cost
         ) do
      :ok -> :ok
      {:error, :budget_exceeded, details} -> {:error, {:budget_exceeded, details}}
    end
  end

  ## Provider execution with fallback ##########################################

  defp execute(conn, route, payload, member, attempts_left, exclude) do
    provider = route.model_provider.credential.provider
    # The client sends the alias name; the provider expects its own model id.
    payload = Map.put(payload, "model", route.model_responded)
    receive_timeout = route.credential.receive_timeout_ms || 120_000

    case OpenAIAdapter.chat_completion(provider, route.credential, payload,
           receive_timeout: receive_timeout
         ) do
      {:ok, body, latency_ms} ->
        Router.record_outcome(route, :success)
        finalize_success(conn, route, body, latency_ms, member)

      {:error, :auth_error, status, error_message} ->
        # 401/402/403: the credential is bad (invalid key, insufficient credit,
        # forbidden). Disable it permanently in the DB and fall back.
        disable_credential_async(route.credential, "auth_error_#{status}", error_message)
        Router.record_outcome(route, {:failure, :auth_error})

        if attempts_left > 1 do
          retry_with_fallback(conn, route, payload, member, attempts_left, exclude, status)
        else
          render_proxy_error(conn, {:upstream_error, :auth_error, status})
        end

      {:error, :client_error, status} ->
        # Other 4xx from the provider: the caller's payload is at fault — surface
        # it without burning the breaker or trying other providers.
        Router.record_outcome(route, {:failure, :client_error})
        render_proxy_error(conn, {:upstream_client_error, status})

      {:error, reason, status, _error_message} ->
        Router.record_outcome(route, {:failure, breaker_reason(reason)})

        if attempts_left > 1 do
          retry_with_fallback(conn, route, payload, member, attempts_left, exclude, status)
        else
          render_proxy_error(conn, {:upstream_error, reason, status})
        end
    end
  end

  # Permanently disable a credential after an auth/billing failure (401/402/403).
  # Runs in a background Task to avoid blocking the hot path. The credential's
  # status is set to "error" so the router excludes it from the candidate pool.
  defp disable_credential_async(credential, reason, error_message \\ nil) do
    Task.start(fn ->
      Providers.update_credential(credential, %{
        status: "error",
        error_reason: reason,
        error_message: error_message,
        error_at: DateTime.utc_now()
      })
    end)
  end

  defp retry_with_fallback(conn, route, payload, member, attempts_left, exclude, _status) do
    exclude = [route.credential.id | exclude]

    request_context = %{
      "messages" => payload["messages"] || [],
      :api_key_hash => conn.assigns.api_key_hash,
      :exclude_credential_ids => exclude
    }

    case Router.route(route.model_alias.name, member, request_context) do
      {:ok, new_route} ->
        execute(conn, new_route, payload, member, attempts_left - 1, exclude)

      {:error, :no_available_provider} ->
        render_proxy_error(conn, :all_providers_down)

      {:error, error} ->
        render_proxy_error(conn, error)
    end
  end

  ## Streaming execution ########################################################

  # SSE passthrough with first-token fallback: nothing is sent to the client
  # until the provider's first chunk arrives. If it never does (timeout or
  # error), the breaker records the failure and we fall back BEFORE committing
  # to a 200 status. `stream_options: {include_usage: true}` is the single
  # sanctioned payload mutation — the plan requires real usage for cost
  # accounting, and it only affects the provider's own usage reporting.
  defp execute_stream(conn, route, payload, member, attempts_left, exclude) do
    provider = route.model_provider.credential.provider
    # The client sends the alias name; the provider expects its own model id.
    payload =
      payload
      |> Map.put("model", route.model_responded)
      |> ensure_stream_options()

    # Measured just before the upstream call: TTFT is the time from this
    # point to the provider's first chunk.
    request_start = System.monotonic_time(:millisecond)
    receive_timeout = route.credential.receive_timeout_ms || 120_000

    case OpenAIAdapter.stream_chat_completion(provider, route.credential, payload,
           receive_timeout: receive_timeout
         ) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        case await_first_chunk(pid, ref) do
          {:ok, first_chunk} ->
            ttft_ms = System.monotonic_time(:millisecond) - request_start
            Router.record_outcome(route, :success)

            conn =
              conn
              |> put_resp_content_type("text/event-stream")
              |> put_resp_header("cache-control", "no-cache")
              |> send_chunked(200)

            stream_loop(conn, pid, ref, first_chunk, route, member, payload, %{
              usage: nil,
              completion: "",
              prompt_estimate: TokenEstimator.estimate_messages(payload["messages"] || []),
              ttft_ms: ttft_ms,
              latency_start: System.monotonic_time(:millisecond)
            })

          {:error, reason} ->
            Process.exit(pid, :kill)

            if reason == :auth_error do
              disable_credential_async(route.credential, "auth_error_stream")
            end

            Router.record_outcome(route, {:failure, breaker_reason(reason)})

            if attempts_left > 1 do
              retry_stream_with_fallback(conn, route, payload, member, attempts_left, exclude)
            else
              render_proxy_error(conn, {:upstream_error, reason, nil})
            end
        end
    end
  end

  defp retry_stream_with_fallback(conn, route, payload, member, attempts_left, exclude) do
    exclude = [route.credential.id | exclude]

    request_context = %{
      "messages" => payload["messages"] || [],
      :api_key_hash => conn.assigns.api_key_hash,
      :exclude_credential_ids => exclude
    }

    case Router.route(route.model_alias.name, member, request_context) do
      {:ok, new_route} ->
        execute_stream(conn, new_route, payload, member, attempts_left - 1, exclude)

      {:error, :no_available_provider} ->
        render_proxy_error(conn, :all_providers_down)

      {:error, error} ->
        render_proxy_error(conn, error)
    end
  end

  defp ensure_stream_options(payload) do
    options = Map.get(payload, "stream_options", %{})
    Map.put(payload, "stream_options", Map.put(options, "include_usage", true))
  end

  defp await_first_chunk(pid, ref) do
    timeout = Application.get_env(:tokengate, :first_token_timeout_ms, 15_000)

    receive do
      {:sse_chunk, chunk} -> {:ok, chunk}
      {:sse_done} -> {:error, :empty_stream}
      {:sse_error, reason} -> {:error, stream_error_reason(reason)}
      {:DOWN, ^ref, :process, ^pid, reason} -> {:error, stream_error_reason(reason)}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp stream_error_reason({reason, _status}), do: reason
  defp stream_error_reason(reason) when is_atom(reason), do: reason
  defp stream_error_reason(_), do: :server_error

  defp stream_loop(conn, pid, ref, pending_chunk, route, member, payload, acc) do
    case forward_stream_chunk(conn, pending_chunk, route, acc) do
      {:ok, conn, acc} ->
        receive do
          {:sse_chunk, chunk} ->
            stream_loop(conn, pid, ref, chunk, route, member, payload, acc)

          {:sse_done} ->
            finish_stream(conn, route, member, acc)

          {:sse_error, _reason} ->
            # Mid-stream failure: the 200 is already committed — close the
            # stream and record what we have.
            finish_stream(conn, route, member, acc)

          {:DOWN, ^ref, :process, ^pid, _reason} ->
            finish_stream(conn, route, member, acc)
        end

      {:client_gone, conn} ->
        Process.exit(pid, :kill)
        conn
    end
  end

  # Forwards one chunk as an SSE frame. When the chunk carries the provider's
  # final usage payload, the cost dimensions are injected before forwarding
  # (same contract as the non-streaming response).
  defp forward_stream_chunk(conn, chunk, route, acc) do
    {chunk, acc} = maybe_capture_usage(chunk, route, acc)

    case Plug.Conn.chunk(conn, "data: #{chunk}\n\n") do
      {:ok, conn} -> {:ok, conn, acc}
      {:error, _closed} -> {:client_gone, conn}
    end
  end

  defp maybe_capture_usage(chunk, route, acc) do
    case Jason.decode(chunk) do
      {:ok, decoded} ->
        case UsageNormalizer.from_openai_stream_chunk(decoded) do
          nil ->
            {chunk, %{acc | completion: acc.completion <> extract_delta_text(decoded)}}

          usage ->
            costs = stream_costs(route, usage, decoded)
            injected = inject_usage_costs(decoded, usage, costs)
            {Jason.encode!(injected), %{acc | usage: {usage, costs}}}
        end

      {:error, _} ->
        {chunk, acc}
    end
  end

  defp extract_delta_text(decoded) do
    case get_in(decoded, ["choices", Access.at(0), "delta", "content"]) do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  defp finish_stream(conn, route, member, acc) do
    conn =
      case Plug.Conn.chunk(conn, "data: [DONE]\n\n") do
        {:ok, conn} -> conn
        {:error, _closed} -> conn
      end

    latency_ms = System.monotonic_time(:millisecond) - acc.latency_start

    {usage, costs} =
      case acc.usage do
        {usage, costs} ->
          {usage, costs}

        nil ->
          # Provider sent no usage — fall back to the chars/4 heuristic over
          # the accumulated completion so cost accounting still works.
          usage = %{
            prompt_tokens: acc.prompt_estimate,
            completion_tokens: TokenEstimator.estimate_completion(acc.completion),
            cache_read_tokens: 0,
            cache_creation_tokens: 0
          }

          {usage, stream_costs(route, usage, nil)}
      end

    Budgets.record_spend(member.id, costs.cost_usd)

    Collector.record_request(%{
      model_alias_id: route.model_alias.id,
      provider_id: route.model_provider.credential.provider_id,
      agent_type: conn.assigns.agent_type,
      status: 200,
      latency_ms: latency_ms,
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      cost_usd: costs.cost_usd,
      savings_usd: costs.savings_usd,
      streaming: true
    })

    enqueue_log(route, member, conn.assigns.agent_type, usage, costs, latency_ms, 200, true,
      ttft_ms: acc.ttft_ms,
      think: conn.assigns[:think] || false,
      effort: conn.assigns[:effort]
    )

    conn
  end

  defp stream_costs(route, usage, body) do
    pricing = Providers.current_pricing(route.model_provider.id)

    provider_reported =
      if body, do: UsageNormalizer.extract_reported_cost(:openai, body), else: nil

    CostCalculator.breakdown(route.model_alias, pricing, usage,
      billing_mode: route.model_provider.billing_mode,
      provider_reported_cost: provider_reported
    )
  end

  ## Success finalization #######################################################

  defp finalize_success(conn, route, body, latency_ms, member) do
    usage = UsageNormalizer.normalize(:openai, body) || fallback_usage(conn.body_params, body)
    pricing = Providers.current_pricing(route.model_provider.id)
    provider_reported = UsageNormalizer.extract_reported_cost(:openai, body)

    costs =
      CostCalculator.breakdown(route.model_alias, pricing, usage,
        billing_mode: route.model_provider.billing_mode,
        provider_reported_cost: provider_reported
      )

    # Hot-path state updates (ETS only)
    Budgets.record_spend(member.id, costs.cost_usd)

    Collector.record_request(%{
      model_alias_id: route.model_alias.id,
      provider_id: route.model_provider.credential.provider_id,
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
    enqueue_log(route, member, conn.assigns.agent_type, usage, costs, latency_ms, 200, false,
      think: conn.assigns[:think] || false,
      effort: conn.assigns[:effort]
    )

    body = inject_usage_costs(body, usage, costs)

    conn
    |> put_resp_header("x-tokengate-cost", Decimal.to_string(costs.cost_usd, :normal))
    |> put_resp_header("x-tokengate-savings", Decimal.to_string(costs.savings_usd, :normal))
    |> json(body)
  end

  defp inject_usage_costs(body, usage, costs) do
    # Preserve the provider's own token counts (OpenAI's prompt_tokens
    # includes cached tokens — the client expects the original totals);
    # only fill in counts when the provider sent no usage at all.
    response_usage =
      body
      |> Map.get("usage", %{})
      |> Map.put_new("prompt_tokens", usage.prompt_tokens)
      |> Map.put_new("completion_tokens", usage.completion_tokens)
      |> Map.merge(%{
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

  defp enqueue_log(
         route,
         member,
         agent_type,
         usage,
         costs,
         latency_ms,
         status,
         streaming,
         extra
       ) do
    %{
      "team_member_id" => member.id,
      "provider_id" => route.model_provider.credential.provider_id,
      "model_provider_id" => route.model_provider.id,
      "model_alias_id" => route.model_alias.id,
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
      "ttft_ms" => Keyword.get(extra, :ttft_ms),
      "streaming" => streaming,
      "think" => Keyword.get(extra, :think, false),
      "effort" => Keyword.get(extra, :effort),
      "api_key_prefix" => member.api_key && member.api_key.key_prefix,
      "credential_name" => route.credential.name
    }
    |> WriteWorker.new()
    |> Oban.insert()
  end

  ## Errors ######################################################################

  defp breaker_reason(:timeout), do: :timeout
  defp breaker_reason(:rate_limited), do: :rate_limited
  defp breaker_reason(:auth_error), do: :auth_error
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

  defp error_details({:provider_rate_limited, retry_ms}),
    do:
      {429, "rate_limit_error", "provider_rate_limited",
       "Provider rate limit exceeded, retry in #{retry_ms}ms"}

  defp error_details(:provider_concurrency_exceeded),
    do:
      {429, "rate_limit_error", "provider_concurrency_exceeded",
       "Too many concurrent requests to provider"}

  defp error_details({:budget_exceeded, %{period: period}}),
    do: {402, "billing_error", "budget_exceeded", "Budget exceeded (#{period})"}

  defp error_details({:budget_exceeded, %{available: available}}),
    do:
      {402, "billing_error", "budget_exceeded",
       "Budget exceeded. Available: $#{Decimal.round(available, 4)}"}

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
