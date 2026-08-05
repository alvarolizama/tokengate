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
       (`max_rpm`, `max_concurrent`, `max_concurrent_per_user`). The global
       gates are keyed by credential.id; the per-user concurrency gate is
       keyed by {credential.id, api_key_id} so one heavy user can't swallow
       every slot of a shared subscription credential — when it trips, only
       that user falls back to the next provider.

  Both gates must pass for a request to proceed. Team limits are acquired
  first; if routing succeeds, credential limits are acquired before execution.

  Hot path discipline: auth, limits, budgets and routing read from
  ETS/atomics only. Postgres is touched asynchronously via Oban
  (`Tokengate.Logs.WriteWorker`).
  """

  use TokengateWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Accounts
  alias Tokengate.Budgets.Manager, as: Budgets
  alias Tokengate.Limits.Manager, as: Limits
  alias Tokengate.Logs.WriteWorker
  alias Tokengate.Metrics.Collector
  alias Tokengate.Providers

  alias Tokengate.Proxy.{
    CostCalculator,
    OpenAIAdapter,
    PromptOptimizer,
    TokenEstimator,
    UsageNormalizer
  }

  alias Tokengate.Routing.Router

  @max_attempts 9
  @max_retries_per_provider 3

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
    request_start = System.monotonic_time(:millisecond)

    {think, effort} = Tokengate.Proxy.Reasoning.parse(payload)

    conn =
      conn
      |> assign(:think, think)
      |> assign(:effort, effort)

    with :ok <- require_model(model),
         :ok <- acquire_team_limits(key_id, limits) do
      try do
        case route_and_acquire(member, payload, conn.assigns.api_key_hash, limits) do
          {:ok, route} ->
            inflight = register_inflight(conn, member, payload, route)

            try do
              if payload["stream"] == true do
                execute_stream(conn, route, payload, member, @max_attempts, [])
              else
                execute(conn, route, payload, member, @max_attempts, [])
              end
            after
              Tokengate.Logs.Inflight.finish_request(inflight.id)
              release_credential_limits(route.credential, key_id)
            end

          {:error, error} ->
            log_and_render_gate_error(conn, member, model, error,
              latency_ms: elapsed(request_start)
            )
        end
      after
        Limits.release(key_id)
      end
    else
      {:error, error} ->
        log_and_render_gate_error(conn, member, model, error, latency_ms: elapsed(request_start))
    end
  end

  @doc """
  Proxies an embeddings request (OpenAI format) to the routed provider.

  Non-streaming only. Works against any OpenAI-compatible `/embeddings`
  surface — oMLX, OpenRouter and Fireworks all speak the same shape and
  report `usage.prompt_tokens`; when the upstream omits usage, token counts
  fall back to the chars/4 estimator over the inputs.
  """
  def embeddings(conn, _params) do
    payload = conn.body_params

    with :ok <- require_input(payload) do
      simple_proxy(conn, payload, "embedding", &OpenAIAdapter.embeddings/4, :embedding)
    else
      {:error, error} -> render_proxy_error(conn, error)
    end
  end

  @doc """
  Proxies a rerank request (Cohere format: `query`, `documents[]`,
  optional `top_n` / `return_documents` / `task`) to the routed provider.

  Providers disagree on the response list key: oMLX answers Cohere-style
  `results`, Fireworks answers Jina-style `data`. TokenGate normalizes
  every upstream response to the Cohere shape (`results`) so clients see
  one stable contract regardless of backend. Fireworks reports usage;
  oMLX does not (falls back to the estimator).
  """
  def rerank(conn, _params) do
    payload = conn.body_params

    with :ok <- require_query(payload),
         :ok <- require_documents(payload) do
      simple_proxy(conn, payload, "rerank", &OpenAIAdapter.rerank/4, :rerank)
    else
      {:error, error} -> render_proxy_error(conn, error)
    end
  end

  # Shared gate pipeline for non-streaming, non-chat endpoints (embeddings,
  # rerank): same two-gate throttle, routing, budget check, inflight
  # registry, fallback matrix and cost accounting as chat — minus the
  # chat-only payload transforms (guard rails, prompt optimizer, reasoning).
  defp simple_proxy(conn, payload, capability, adapter_fun, kind) do
    member = conn.assigns.current_team_member
    model = payload["model"]
    limits = Accounts.effective_limits(member)
    key_id = member.api_key.id
    request_start = System.monotonic_time(:millisecond)

    with :ok <- require_model(model),
         :ok <- acquire_team_limits(key_id, limits) do
      try do
        case route_and_acquire(member, payload, conn.assigns.api_key_hash, limits, [],
               capability: capability
             ) do
          {:ok, route} ->
            inflight = register_inflight(conn, member, payload, route)

            try do
              execute_simple(conn, route, payload, member, @max_attempts, [], adapter_fun, kind,
                capability: capability
              )
            after
              Tokengate.Logs.Inflight.finish_request(inflight.id)
              release_credential_limits(route.credential, key_id)
            end

          {:error, error} ->
            log_and_render_gate_error(conn, member, model, error,
              latency_ms: elapsed(request_start)
            )
        end
      after
        Limits.release(key_id)
      end
    else
      {:error, error} ->
        log_and_render_gate_error(conn, member, model, error, latency_ms: elapsed(request_start))
    end
  end

  defp require_input(%{"input" => input}) when is_binary(input) or is_list(input), do: :ok
  defp require_input(_), do: {:error, {:invalid_request, "input is required (string or array)"}}

  defp require_query(%{"query" => query}) when is_binary(query), do: :ok
  defp require_query(_), do: {:error, {:invalid_request, "query is required (string)"}}

  defp require_documents(%{"documents" => docs}) when is_list(docs) and docs != [], do: :ok

  defp require_documents(_),
    do: {:error, {:invalid_request, "documents is required (non-empty array)"}}

  # Non-streaming execution with the same fallback matrix as chat's
  # execute/6: auth errors disable the credential, other 4xx surface
  # without burning the breaker, everything else retries across credentials.
  defp execute_simple(
         conn,
         route,
         payload,
         member,
         attempts_left,
         exclude,
         adapter_fun,
         kind,
         route_opts
       ) do
    execute_simple(
      conn,
      route,
      payload,
      member,
      attempts_left,
      exclude,
      adapter_fun,
      kind,
      route_opts,
      provider_retries: 0
    )
  end

  defp execute_simple(
         conn,
         route,
         payload,
         member,
         attempts_left,
         exclude,
         adapter_fun,
         kind,
         route_opts,
         provider_retries: provider_retries
       ) do
    provider = route.model_provider.credential.provider
    payload = Map.put(payload, "model", route.model_responded)

    receive_timeout = receive_timeout(route.credential)

    case adapter_fun.(provider, route.credential, payload,
           receive_timeout: receive_timeout,
           forwarded_headers: extract_forwarded_headers(conn)
         ) do
      {:ok, body, latency_ms} ->
        Router.record_outcome(route, :success, latency_ms: latency_ms)
        finalize_simple_success(conn, route, body, latency_ms, member, kind)

      {:error, :auth_error, status, error_message} ->
        disable_credential_async(route.credential, "auth_error_#{status}", error_message)
        Router.record_outcome(route, {:failure, :auth_error, error_message})

        if attempts_left > 1 do
          retry_simple_with_fallback(
            conn,
            route,
            payload,
            member,
            attempts_left,
            exclude,
            status,
            adapter_fun,
            kind,
            route_opts,
            provider_retries: provider_retries,
            reason: :auth_error,
            error_message: error_message
          )
        else
          log_and_render_proxy_error(conn, route, member, {:upstream_error, :auth_error, status},
            error_reason: "auth_error",
            error_message: error_message
          )
        end

      {:error, :client_error, status, error_message} ->
        Router.record_outcome(route, {:failure, :client_error})

        log_and_render_proxy_error(conn, route, member, {:upstream_client_error, status},
          error_reason: "client_error",
          error_message: error_message
        )

      {:error, reason, status, error_message} ->
        Router.record_outcome(route, {:failure, breaker_reason(reason), error_message})

        if attempts_left > 1 do
          retry_simple_with_fallback(
            conn,
            route,
            payload,
            member,
            attempts_left,
            exclude,
            status,
            adapter_fun,
            kind,
            route_opts,
            provider_retries: provider_retries,
            reason: reason,
            error_message: error_message
          )
        else
          log_and_render_proxy_error(conn, route, member, {:upstream_error, reason, status},
            error_reason: to_string(reason),
            error_message: error_message
          )
        end
    end
  end

  defp retry_simple_with_fallback(
         conn,
         route,
         payload,
         member,
         attempts_left,
         exclude,
         status,
         adapter_fun,
         kind,
         route_opts,
         provider_retries: provider_retries,
         reason: reason,
         error_message: error_message
       ) do
    log_fallback_attempt(conn, route, member, status, error_message)

    # Per-provider retry: same policy as retry_with_fallback.
    {exclude, provider_retries} = next_candidate(route, exclude, provider_retries, reason)

    case Router.route(route.model_alias.name, member, %{
           :api_key_hash => conn.assigns.api_key_hash,
           :exclude_credential_ids => exclude,
           :capability => Keyword.get(route_opts, :capability, "llm")
         }) do
      {:ok, new_route} ->
        execute_simple(
          conn,
          new_route,
          payload,
          member,
          attempts_left - 1,
          exclude,
          adapter_fun,
          kind,
          route_opts,
          provider_retries: provider_retries
        )

      {:error, :no_available_provider} ->
        log_and_render_proxy_error(conn, route, member, :all_providers_down,
          error_reason: "all_providers_down"
        )

      {:error, error} ->
        log_and_render_proxy_error(conn, route, member, error,
          error_reason: error_reason_string(error)
        )
    end
  end

  defp finalize_simple_success(conn, route, body, latency_ms, member, kind) do
    {usage, body} = simple_usage(conn.body_params, body, kind)
    provider_reported = UsageNormalizer.extract_reported_cost(:openai, body)

    cost = CostCalculator.provider_cost(route.model_provider.billing_mode, provider_reported)

    Budgets.record_spend(member.id, cost)

    Collector.record_request(%{
      model_alias_id: route.model_alias.id,
      provider_id: route.model_provider.credential.provider_id,
      agent_type: conn.assigns.agent_type,
      status: 200,
      latency_ms: latency_ms,
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      cost_usd: cost,
      streaming: false
    })

    enqueue_log(route, member, conn.assigns.agent_type, usage, cost, latency_ms, 200, false,
      client_agent: conn.assigns.client_agent,
      request_type: to_string(kind)
    )

    conn
    |> put_resp_header("x-tokengate-cost", Decimal.to_string(cost, :normal))
    |> json(body)
  end

  # Resolves usage for non-chat responses, returning {usage, response_body}.
  #
  # :embedding — OpenAI shape; usage comes from the upstream when present,
  #   otherwise estimated over the inputs. The body passes through untouched.
  # :rerank — the response body is normalized to the Cohere shape
  #   (`results`) so clients see one contract across oMLX and Fireworks.
  #   Usage is read BEFORE stripping the provider's usage key (Fireworks
  #   reports real prompt_tokens; oMLX reports nothing → estimate over
  #   query + documents).
  defp simple_usage(payload, body, :embedding) do
    usage = UsageNormalizer.normalize(:openai, body) || estimate_embedding_usage(payload)
    {usage, body}
  end

  defp simple_usage(payload, body, :rerank) do
    usage = UsageNormalizer.normalize(:openai, body) || estimate_rerank_usage(payload)
    {usage, normalize_rerank_body(body)}
  end

  defp estimate_embedding_usage(payload) do
    tokens =
      payload["input"]
      |> List.wrap()
      |> Enum.reduce(0, fn
        s, acc when is_binary(s) -> acc + TokenEstimator.estimate_completion(s)
        _, acc -> acc
      end)

    %{prompt_tokens: tokens, completion_tokens: 0, cache_read_tokens: 0, cache_creation_tokens: 0}
  end

  defp estimate_rerank_usage(payload) do
    query_tokens = TokenEstimator.estimate_completion(payload["query"] || "")

    doc_tokens =
      payload["documents"]
      |> List.wrap()
      |> Enum.reduce(0, fn
        s, acc when is_binary(s) -> acc + TokenEstimator.estimate_completion(s)
        _, acc -> acc
      end)

    %{
      prompt_tokens: query_tokens + doc_tokens,
      completion_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0
    }
  end

  # Normalizes provider-specific rerank responses to the Cohere shape.
  # oMLX already answers with `results`; Fireworks answers Jina-style with
  # `object: "list"` + `data`. Item fields (`index`, `relevance_score`,
  # optional `document`) are identical across providers.
  defp normalize_rerank_body(%{"results" => _} = body), do: body

  defp normalize_rerank_body(%{"data" => data} = body) when is_list(data) do
    body
    |> Map.delete("data")
    |> Map.delete("object")
    |> Map.put("results", data)
  end

  defp normalize_rerank_body(body), do: body

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

  # Shared retry policy for all three execution paths (chat, streaming,
  # embeddings/rerank). Decides whether the next attempt should re-select
  # the same credential or exclude it so the router moves to the next
  # provider.
  #
  #   * `:timeout` — the provider hung for the full receive_timeout (or the
  #     first_token_timeout in streaming). A hung provider won't recover in
  #     the milliseconds a retry takes, and each retry would cost another
  #     full timeout of client-perceived latency, so we exclude the
  #     credential immediately and move on.
  #   * any other reason — fast failures (5xx, 429, connection refused) are
  #     often transient and cost almost nothing to retry, so the same
  #     provider gets up to @max_retries_per_provider attempts before being
  #     excluded.
  defp next_candidate(route, exclude, _provider_retries, :timeout) do
    {[route.credential.id | exclude], 0}
  end

  defp next_candidate(route, exclude, provider_retries, _reason) do
    if provider_retries < @max_retries_per_provider do
      {exclude, provider_retries + 1}
    else
      {[route.credential.id | exclude], 0}
    end
  end

  # Two-level provider-side gate, keyed by credential.id globally and by
  # {credential.id, api_key_id} per user:
  #
  #   1. Global — `max_rpm` / `max_concurrent` protect the upstream API key
  #      itself (quota and saturation). Shared by every user of the credential.
  #   2. Per user — `max_concurrent_per_user` stops a single heavy user from
  #      swallowing every slot of a shared subscription credential. When it
  #      trips, only that user falls back to the next provider; everyone else
  #      keeps using the subscription. nil means unlimited (track but don't block).
  defp acquire_credential_limits(credential, key_id) do
    case Limits.acquire(credential.id, %{
           rpm_limit: credential.max_rpm,
           concurrency_limit: credential.max_concurrent
         }) do
      :ok ->
        case Limits.acquire_concurrency(
               {credential.id, key_id},
               credential.max_concurrent_per_user
             ) do
          :ok ->
            :ok

          {:error, :concurrency_exceeded} ->
            # Roll back the global slot so it doesn't leak while the user's
            # request falls back to another provider.
            Limits.release(credential.id)
            {:error, :provider_user_concurrency_exceeded}
        end

      {:error, :rate_limited, retry_after_ms} ->
        {:error, {:provider_rate_limited, retry_after_ms}}

      {:error, :concurrency_exceeded} ->
        {:error, :provider_concurrency_exceeded}
    end
  end

  defp release_credential_limits(credential, key_id) do
    Limits.release(credential.id)
    Limits.release_concurrency({credential.id, key_id})
  end

  # Registers the request in the in-flight registry so the Logs UI shows it
  # as "Pending" while it executes. think/effort are already in conn assigns.
  defp register_inflight(conn, member, payload, route) do
    Tokengate.Logs.Inflight.start_request(%{
      team_member_id: member.id,
      user_email: member.user && member.user.email,
      team_name: member.team && member.team.name,
      team_id: member.team_id,
      model_requested: payload["model"],
      agent_type: conn.assigns.agent_type,
      client_agent: conn.assigns.client_agent,
      streaming: payload["stream"] == true,
      think: conn.assigns[:think] || false,
      effort: conn.assigns[:effort],
      provider_name: route.model_provider.credential.provider.name,
      api_key_prefix: member.api_key && member.api_key.key_prefix,
      credential_name: route.credential.name,
      provider_key_suffix: provider_key_prefix(route.credential)
    })
  end

  defp route_and_acquire(member, payload, api_key_hash, limits, exclude \\ [], route_opts \\ []) do
    key_id = member.api_key.id

    request_context = %{
      "messages" => payload["messages"] || [],
      :api_key_hash => api_key_hash,
      :exclude_credential_ids => exclude,
      :capability => Keyword.get(route_opts, :capability, "llm")
    }

    with {:ok, route} <- Router.route(payload["model"], member, request_context),
         :ok <- check_budget(member, limits, route, payload) do
      case acquire_credential_limits(route.credential, key_id) do
        :ok ->
          {:ok, route}

        {:error, :provider_concurrency_exceeded} ->
          # This credential is saturated — try the next one by priority.
          route_and_acquire(member, payload, api_key_hash, limits, [route.credential.id | exclude])

        {:error, :provider_user_concurrency_exceeded} ->
          # This user hit their per-user ceiling on this credential — only
          # they fall back to the next provider; others keep the subscription.
          route_and_acquire(member, payload, api_key_hash, limits, [route.credential.id | exclude])

        {:error, {:provider_rate_limited, _retry_ms}} ->
          # Provider RPM limit hit — same fallback: try the next credential.
          route_and_acquire(member, payload, api_key_hash, limits, [route.credential.id | exclude])
      end
    else
      # All credentials excluded or unavailable — if we got here through
      # concurrency fallback, surface the concurrency error instead of the
      # generic "no available provider".
      {:error, :no_available_provider} when exclude != [] ->
        {:error, :provider_concurrency_exceeded}

      {:error, error} ->
        {:error, error}
    end
  end

  defp check_budget(member, _limits, route, _payload) do
    member_monthly_budget = Accounts.effective_limits(member).monthly_budget_usd
    member_monthly_spend = Budgets.spend(member.id).monthly_usd

    # Since the 2026-07-30 refactor we no longer estimate the upstream cost
    # up-front (the upstream is the source of truth and we don't make up a
    # number when it doesn't report one). The pre-check therefore asks a
    # simpler question: "has the member already exhausted their monthly cap?"
    # If yes, reject. If not, let the request through; the post-pipeline
    # records the real reported cost and `record_spend` keeps the counter in
    # sync. A subsequent request will see the updated spend and reject.
    projected_cost = CostCalculator.provider_cost(route.model_provider.billing_mode, nil)

    case Budgets.check_ladder(
           member_monthly_budget,
           member_monthly_spend,
           projected_cost
         ) do
      :ok -> :ok
      {:error, :budget_exceeded, details} -> {:error, {:budget_exceeded, details}}
    end
  end

  ## Provider execution with fallback ##########################################

  # Upstream receive timeout: the credential's own value wins when set; nil
  # falls back to the global config default (60s). Credentials created before
  # the default was relaxed carry an explicit value and keep it.
  defp receive_timeout(credential) do
    credential.receive_timeout_ms ||
      Application.get_env(:tokengate, :proxy, [])
      |> Keyword.get(:receive_timeout_ms, 60_000)
  end

  # Extracts whitelisted client headers to forward upstream.
  @forwarded_header_keys %{
    "user-agent" => "user-agent",
    "http-referer" => "http-referer",
    "x-title" => "x-title"
  }

  defp extract_forwarded_headers(conn) do
    @forwarded_header_keys
    |> Enum.reduce(%{}, fn {client_key, upstream_key}, acc ->
      case Plug.Conn.get_req_header(conn, client_key) do
        [value | _] -> Map.put(acc, upstream_key, value)
        [] -> acc
      end
    end)
  end

  defp execute(conn, route, payload, member, attempts_left, exclude) do
    execute(conn, route, payload, member, attempts_left, exclude, 0)
  end

  defp execute(conn, route, payload, member, attempts_left, exclude, provider_retries) do
    provider = route.model_provider.credential.provider
    # The client sends the alias name; the provider expects its own model id.
    payload =
      payload
      |> Map.put("model", route.model_responded)
      |> inject_guard_rails(route.model_alias)
      |> maybe_optimize(route.model_alias)

    receive_timeout = receive_timeout(route.credential)

    case OpenAIAdapter.chat_completion(provider, route.credential, payload,
           receive_timeout: receive_timeout,
           forwarded_headers: extract_forwarded_headers(conn)
         ) do
      {:ok, body, latency_ms} ->
        Router.record_outcome(route, :success, latency_ms: latency_ms)
        finalize_success(conn, route, body, latency_ms, member)

      {:error, :auth_error, status, error_message} ->
        # 401/402/403: the credential is bad (invalid key, insufficient credit,
        # forbidden). Disable it permanently in the DB and fall back.
        disable_credential_async(route.credential, "auth_error_#{status}", error_message)
        Router.record_outcome(route, {:failure, :auth_error, error_message})

        if attempts_left > 1 do
          retry_with_fallback(
            conn,
            route,
            payload,
            member,
            attempts_left,
            exclude,
            status,
            provider_retries,
            :auth_error,
            error_message
          )
        else
          log_and_render_proxy_error(conn, route, member, {:upstream_error, :auth_error, status},
            error_reason: "auth_error",
            error_message: error_message
          )
        end

      {:error, :client_error, status, error_message} ->
        # Other 4xx from the provider: the caller's payload is at fault — surface
        # it without burning the breaker or trying other providers.
        Router.record_outcome(route, {:failure, :client_error})

        log_and_render_proxy_error(conn, route, member, {:upstream_client_error, status},
          error_reason: "client_error",
          error_message: error_message
        )

      {:error, reason, status, error_message} ->
        Router.record_outcome(route, {:failure, breaker_reason(reason), error_message})

        if attempts_left > 1 do
          retry_with_fallback(
            conn,
            route,
            payload,
            member,
            attempts_left,
            exclude,
            status,
            provider_retries,
            reason,
            error_message
          )
        else
          log_and_render_proxy_error(conn, route, member, {:upstream_error, reason, status},
            error_reason: to_string(reason),
            error_message: error_message
          )
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

      Phoenix.PubSub.broadcast(
        Tokengate.PubSub,
        "alerts",
        {:credential_error, credential.id, reason}
      )
    end)
  end

  defp retry_with_fallback(
         conn,
         route,
         payload,
         member,
         attempts_left,
         exclude,
         status,
         provider_retries,
         reason,
         error_message
       ) do
    log_fallback_attempt(conn, route, member, status, error_message)

    # A timeout means the provider is hung or saturated — fall back to the
    # next provider immediately; the condition that hung it won't clear in
    # the milliseconds a retry takes, and each retry would cost a full
    # receive_timeout of client-perceived latency. Fast errors (5xx, 429)
    # are often transient, so those keep the per-provider retries.
    {exclude, provider_retries} = next_candidate(route, exclude, provider_retries, reason)

    request_context = %{
      "messages" => payload["messages"] || [],
      :api_key_hash => conn.assigns.api_key_hash,
      :exclude_credential_ids => exclude
    }

    case Router.route(route.model_alias.name, member, request_context) do
      {:ok, new_route} ->
        execute(conn, new_route, payload, member, attempts_left - 1, exclude, provider_retries)

      {:error, :no_available_provider} ->
        log_and_render_proxy_error(conn, route, member, :all_providers_down,
          error_reason: "all_providers_down"
        )

      {:error, error} ->
        log_and_render_proxy_error(conn, route, member, error,
          error_reason: error_reason_string(error)
        )
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
    execute_stream(conn, route, payload, member, attempts_left, exclude, 0)
  end

  defp execute_stream(conn, route, payload, member, attempts_left, exclude, provider_retries) do
    provider = route.model_provider.credential.provider
    # The client sends the alias name; the provider expects its own model id.
    payload =
      payload
      |> Map.put("model", route.model_responded)
      |> ensure_stream_options()
      |> inject_guard_rails(route.model_alias)
      |> maybe_optimize(route.model_alias)

    # Measured just before the upstream call: TTFT is the time from this
    # point to the provider's first chunk.
    request_start = System.monotonic_time(:millisecond)
    receive_timeout = receive_timeout(route.credential)

    case OpenAIAdapter.stream_chat_completion(provider, route.credential, payload,
           receive_timeout: receive_timeout,
           forwarded_headers: extract_forwarded_headers(conn)
         ) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        case await_first_chunk(pid, ref) do
          {:ok, first_chunk} ->
            ttft_ms = System.monotonic_time(:millisecond) - request_start
            Router.record_outcome(route, :success, latency_ms: ttft_ms)

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

          {:error, reason, status} ->
            Process.exit(pid, :kill)

            if reason == :auth_error do
              disable_credential_async(route.credential, "auth_error_stream")
            end

            Router.record_outcome(route, {:failure, breaker_reason(reason)})

            if attempts_left > 1 do
              log_fallback_attempt(conn, route, member, status)

              retry_stream_with_fallback(
                conn,
                route,
                payload,
                member,
                attempts_left,
                exclude,
                provider_retries,
                reason
              )
            else
              log_and_render_proxy_error(conn, route, member, {:upstream_error, reason, status},
                error_reason: to_string(reason)
              )
            end
        end
    end
  end

  defp retry_stream_with_fallback(
         conn,
         route,
         payload,
         member,
         attempts_left,
         exclude,
         provider_retries,
         reason
       ) do
    # Same policy as retry_with_fallback: timeouts fall back immediately,
    # fast errors retry the same provider up to @max_retries_per_provider.
    {exclude, provider_retries} = next_candidate(route, exclude, provider_retries, reason)

    request_context = %{
      "messages" => payload["messages"] || [],
      :api_key_hash => conn.assigns.api_key_hash,
      :exclude_credential_ids => exclude
    }

    case Router.route(route.model_alias.name, member, request_context) do
      {:ok, new_route} ->
        execute_stream(
          conn,
          new_route,
          payload,
          member,
          attempts_left - 1,
          exclude,
          provider_retries
        )

      {:error, :no_available_provider} ->
        log_and_render_proxy_error(conn, route, member, :all_providers_down,
          error_reason: "all_providers_down"
        )

      {:error, error} ->
        log_and_render_proxy_error(conn, route, member, error,
          error_reason: error_reason_string(error)
        )
    end
  end

  defp ensure_stream_options(payload) do
    options = Map.get(payload, "stream_options", %{})
    Map.put(payload, "stream_options", Map.put(options, "include_usage", true))
  end

  # Injects the model_alias's guard_rails at the beginning of the system prompt.
  # If there is no system message yet, creates one. If there is one, prepends
  # the guard_rails text. No-op when guard_rails is nil or empty.
  defp inject_guard_rails(payload, model_alias) do
    case model_alias.guard_rails do
      nil ->
        payload

      "" ->
        payload

      guard_rails ->
        messages = Map.get(payload, "messages", [])

        case messages do
          [%{"role" => "system", "content" => content} | rest] ->
            Map.put(payload, "messages", [
              %{"role" => "system", "content" => guard_rails <> "\n\n" <> content} | rest
            ])

          _ ->
            Map.put(payload, "messages", [
              %{"role" => "system", "content" => guard_rails} | messages
            ])
        end
    end
  end

  # Applies the model_alias's prompt-pre-flight transforms to the payload.
  # Both passes are pure and return a fresh messages list; the input is never
  # mutated. When neither flag is set, returns the payload unchanged so the
  # pipeline stays a zero-cost passthrough.
  defp maybe_optimize(payload, model_alias) do
    cond do
      model_alias.prompt_cache_enabled and model_alias.lazy_cleanup_enabled ->
        messages = payload["messages"] || []

        payload
        |> Map.put("messages", PromptOptimizer.stable_prefix(messages))
        |> Map.update!("messages", &PromptOptimizer.lazy_cleanup/1)

      model_alias.prompt_cache_enabled ->
        Map.put(payload, "messages", PromptOptimizer.stable_prefix(payload["messages"] || []))

      model_alias.lazy_cleanup_enabled ->
        Map.put(payload, "messages", PromptOptimizer.lazy_cleanup(payload["messages"] || []))

      true ->
        payload
    end
  end

  defp await_first_chunk(pid, ref) do
    timeout = Application.get_env(:tokengate, :first_token_timeout_ms, 15_000)

    receive do
      {:sse_chunk, chunk} -> {:ok, chunk}
      {:sse_done} -> {:error, :empty_stream, nil}
      {:sse_error, {reason, status}} -> {:error, stream_error_reason(reason), status}
      {:sse_error, reason} -> {:error, stream_error_reason(reason), nil}
      {:DOWN, ^ref, :process, ^pid, reason} -> {:error, stream_error_reason(reason), nil}
    after
      timeout -> {:error, :timeout, nil}
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
            cost = stream_cost(route, usage, decoded)
            injected = inject_usage_costs(decoded, usage, cost)
            {Jason.encode!(injected), %{acc | usage: {usage, cost}}}
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

    {usage, cost} =
      case acc.usage do
        {usage, cost} ->
          {usage, cost}

        nil ->
          # Provider sent no usage — fall back to the chars/4 heuristic over
          # the accumulated completion so cost accounting still works.
          usage = %{
            prompt_tokens: acc.prompt_estimate,
            completion_tokens: TokenEstimator.estimate_completion(acc.completion),
            cache_read_tokens: 0,
            cache_creation_tokens: 0
          }

          cost = stream_cost(route, usage, nil)
          {usage, cost}
      end

    Budgets.record_spend(member.id, cost)

    Collector.record_request(%{
      model_alias_id: route.model_alias.id,
      provider_id: route.model_provider.credential.provider_id,
      agent_type: conn.assigns.agent_type,
      status: 200,
      latency_ms: latency_ms,
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      cost_usd: cost,
      streaming: true
    })

    enqueue_log(route, member, conn.assigns.agent_type, usage, cost, latency_ms, 200, true,
      ttft_ms: acc.ttft_ms,
      think: conn.assigns[:think] || false,
      effort: conn.assigns[:effort],
      client_agent: conn.assigns.client_agent
    )

    conn
  end

  defp stream_cost(route, _usage, body) do
    provider_reported =
      if body, do: UsageNormalizer.extract_reported_cost(:openai, body), else: nil

    CostCalculator.provider_cost(route.model_provider.billing_mode, provider_reported)
  end

  ## Success finalization #######################################################

  defp finalize_success(conn, route, body, latency_ms, member) do
    usage = UsageNormalizer.normalize(:openai, body) || fallback_usage(conn.body_params, body)
    provider_reported = UsageNormalizer.extract_reported_cost(:openai, body)

    cost = CostCalculator.provider_cost(route.model_provider.billing_mode, provider_reported)

    # Hot-path state updates (ETS only)
    Budgets.record_spend(member.id, cost)

    Collector.record_request(%{
      model_alias_id: route.model_alias.id,
      provider_id: route.model_provider.credential.provider_id,
      agent_type: conn.assigns.agent_type,
      status: 200,
      latency_ms: latency_ms,
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      cost_usd: cost,
      streaming: false
    })

    # Durable log + webhooks, async via Oban
    enqueue_log(route, member, conn.assigns.agent_type, usage, cost, latency_ms, 200, false,
      think: conn.assigns[:think] || false,
      effort: conn.assigns[:effort],
      client_agent: conn.assigns.client_agent
    )

    body = inject_usage_costs(body, usage, cost)

    conn
    |> put_resp_header("x-tokengate-cost", Decimal.to_string(cost, :normal))
    |> json(body)
  end

  defp inject_usage_costs(body, usage, cost) do
    # Preserve the provider's own token counts (OpenAI's prompt_tokens
    # includes cached tokens — the client expects the original totals);
    # only fill in counts when the provider sent no usage at all.
    response_usage =
      body
      |> Map.get("usage", %{})
      |> Map.put_new("prompt_tokens", usage.prompt_tokens)
      |> Map.put_new("completion_tokens", usage.completion_tokens)
      |> Map.merge(%{
        "cost_usd" => Decimal.to_float(cost)
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

  defp enqueue_log(
         route,
         member,
         agent_type,
         usage,
         cost,
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
      "client_agent" => Keyword.get(extra, :client_agent),
      "status_code" => status,
      "provider_status_code" => Keyword.get(extra, :provider_status_code),
      "error_reason" => Keyword.get(extra, :error_reason),
      "prompt_tokens" => usage.prompt_tokens,
      "completion_tokens" => usage.completion_tokens,
      "cache_read_tokens" => Map.get(usage, :cache_read_tokens, 0),
      "cache_creation_tokens" => Map.get(usage, :cache_creation_tokens, 0),
      "provider_cost_usd" => Decimal.to_string(cost, :normal),
      "latency_ms" => latency_ms,
      "ttft_ms" => Keyword.get(extra, :ttft_ms),
      "streaming" => streaming,
      "request_type" => Keyword.get(extra, :request_type, "chat"),
      "think" => Keyword.get(extra, :think, false),
      "effort" => Keyword.get(extra, :effort),
      "api_key_prefix" => member.api_key && member.api_key.key_prefix,
      "credential_name" => route.credential.name,
      "provider_key_prefix" => provider_key_prefix(route.credential)
    }
    |> WriteWorker.new()
    |> Oban.insert()
  end

  # Enqueues a durable log for a failed request, then renders the error to the
  # client. `route` is available (the request got past routing), so we capture
  # the provider status code (if any) and the error reason for observability.
  defp log_and_render_proxy_error(conn, route, member, error, opts) do
    {client_status, _type, code, _message} = error_details(error)

    provider_status = provider_status_from_error(error)

    enqueue_error_log(conn, route, member,
      client_status: client_status,
      provider_status: provider_status,
      error_reason: Keyword.get(opts, :error_reason, code),
      latency_ms: Keyword.get(opts, :latency_ms, 0),
      streaming: conn.body_params["stream"] == true
    )

    Collector.record_request(%{
      model_alias_id: route.model_alias.id,
      provider_id: route.model_provider.credential.provider_id,
      agent_type: conn.assigns.agent_type,
      status: client_status,
      latency_ms: Keyword.get(opts, :latency_ms, 0),
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd: Decimal.new(0),
      streaming: conn.body_params["stream"] == true
    })

    render_proxy_error(conn, error)
  end

  # Gate-level errors (before routing succeeded): no provider was contacted,
  # so there is no provider status to record. Still logs the failure — and
  # resolves the model alias id so these rows show up in the per-model stats
  # drill-down (stats page, provider breakdown). Without it, a burst of gate
  # errors (concurrency exceeded, rate limited) would leave the model's
  # stats page looking empty even though traffic hit the gateway.
  defp log_and_render_gate_error(conn, member, model, error, opts) do
    {client_status, _type, code, _message} = error_details(error)

    enqueue_gate_error_log(member, model, conn.assigns.agent_type,
      client_status: client_status,
      error_reason: Keyword.get(opts, :error_reason, code),
      latency_ms: Keyword.get(opts, :latency_ms, 0),
      streaming: conn.body_params["stream"] == true,
      client_agent: conn.assigns.client_agent
    )

    render_proxy_error(conn, error)
  end

  # Resolves the alias id by name for gate-error logs. Alias names are
  # globally unique. The gate path is cold (the request already failed), so a
  # single indexed lookup is acceptable; a miss (model_not_found) returns nil.
  defp alias_id_for_name(nil), do: nil

  defp alias_id_for_name(name) when is_binary(name) do
    Tokengate.Repo.one(
      from ma in Tokengate.Providers.ModelAlias,
        where: ma.name == ^name,
        select: ma.id
    )
  end

  defp enqueue_error_log(conn, route, member, opts) do
    %{
      "team_member_id" => member.id,
      "provider_id" => route.model_provider.credential.provider_id,
      "model_provider_id" => route.model_provider.id,
      "model_alias_id" => route.model_alias.id,
      "model_requested" => route.model_alias.name,
      "model_responded" => route.model_responded,
      "agent_type" => conn.assigns.agent_type,
      "client_agent" => conn.assigns.client_agent,
      "status_code" => Keyword.get(opts, :client_status),
      "provider_status_code" => Keyword.get(opts, :provider_status),
      "error_reason" => Keyword.get(opts, :error_reason),
      "error_message" => Keyword.get(opts, :error_message),
      "prompt_tokens" => 0,
      "completion_tokens" => 0,
      "cache_read_tokens" => 0,
      "cache_creation_tokens" => 0,
      "provider_cost_usd" => "0",
      "latency_ms" => Keyword.get(opts, :latency_ms, 0),
      "streaming" => Keyword.get(opts, :streaming, false),
      "think" => conn.assigns[:think] || false,
      "effort" => conn.assigns[:effort],
      "api_key_prefix" => member.api_key && member.api_key.key_prefix,
      "credential_name" => route.credential.name,
      "provider_key_prefix" => provider_key_prefix(route.credential)
    }
    |> WriteWorker.new()
    |> Oban.insert()
  end

  defp enqueue_gate_error_log(member, model, agent_type, opts) do
    %{
      "team_member_id" => member.id,
      "model_alias_id" => alias_id_for_name(model),
      "model_requested" => model,
      "agent_type" => agent_type,
      "client_agent" => Keyword.get(opts, :client_agent),
      "status_code" => Keyword.get(opts, :client_status),
      "provider_status_code" => nil,
      "error_reason" => Keyword.get(opts, :error_reason),
      "prompt_tokens" => 0,
      "completion_tokens" => 0,
      "provider_cost_usd" => "0",
      "latency_ms" => Keyword.get(opts, :latency_ms, 0),
      "streaming" => Keyword.get(opts, :streaming, false),
      "api_key_prefix" => member.api_key && member.api_key.key_prefix,
      "credential_name" => nil,
      "provider_key_prefix" => nil
    }
    |> WriteWorker.new()
    |> Oban.insert()
  end

  # Extracts the provider's HTTP status code from an upstream error tuple.
  # Returns nil when the failure was not an HTTP response (timeout, connection
  # error, etc.).
  defp provider_status_from_error({:upstream_error, _reason, status})
       when is_integer(status),
       do: status

  defp provider_status_from_error({:upstream_client_error, status})
       when is_integer(status),
       do: status

  defp provider_status_from_error(_), do: nil

  # Extracts a short prefix from a credential's api_key_encrypted. Shows the
  # last 4 characters so admins can identify which provider key was used
  # without exposing the full key. Returns nil when the key is missing.
  defp provider_key_prefix(%{api_key_encrypted: key}) when is_binary(key) and byte_size(key) > 4,
    do: String.slice(key, -4, 4)

  defp provider_key_prefix(%{api_key_encrypted: key}) when is_binary(key), do: key
  defp provider_key_prefix(_), do: nil

  ## Fallback logging ##########################################################

  # Logs a failed provider attempt before falling back to the next one.
  # The client never sees this — it is purely for observability. The upstream
  # error message (when present) is persisted so admins can see *why* the
  # provider failed (rate limit, connection limit, etc.), not just the status.
  defp log_fallback_attempt(conn, route, member, status, error_message \\ nil) do
    error_reason =
      case status do
        429 -> "provider_rate_limited"
        503 -> "provider_overloaded"
        502 -> "provider_gateway_error"
        500 -> "provider_internal_error"
        401 -> "provider_auth_error"
        nil -> "provider_error"
        _ -> "provider_error_#{status}"
      end

    enqueue_error_log(conn, route, member,
      client_status: 200,
      provider_status: status,
      error_reason: error_reason,
      error_message: error_message,
      latency_ms: 0,
      streaming: conn.body_params["stream"] == true
    )
  end

  defp error_reason_string(error) do
    {_status, _type, code, _msg} = error_details(error)
    to_string(code)
  end

  defp elapsed(start_ms), do: System.monotonic_time(:millisecond) - start_ms

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

  defp error_details(:model_type_mismatch),
    do:
      {400, "invalid_request_error", "model_type_mismatch",
       "Model exists but does not serve this endpoint's capability"}

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
