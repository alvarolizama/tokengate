defmodule TokengateWeb.ProxyController do
  @moduledoc """
  OpenAI-compatible proxy API.

    * `GET /v1/models` — only the models the API key can access
      (group grants + individual extras), each with its `context_window`.
    * `POST /v1/chat/completions` — transparent passthrough to the routed
      provider with full cost tracking. The response `usage` object gains
      `cost_usd` (the provider's own cost, USD) and the `X-Tokengate-Cost`
      header carries the same amount. A stream commits its 200 before the cost
      is known, so there are no headers to set: the cost rides the SSE instead
      — the upstream's own usage frame when it sends one, and a closing usage
      frame TokenGate emits right before `data: [DONE]` when it doesn't.
      There is a single cost dimension: the
      market-price fields (`estimated_cost_usd`) and the savings header were
      removed with `market_*`.
    * `POST /v1/embeddings` — embeddings passthrough. Non-streaming only.
      The request is forwarded as received and the upstream response is
      returned untouched; TokenGate only adds auth and cost tracking.
    * `POST /v1/audio/transcriptions`, `/v1/audio/speech`,
      `/v1/images/generations` — the
      rest of a provider's services, same passthrough contract as
      embeddings. Each URL is `base_url` + the path `ProviderPaths` resolves
      for that service (operator override → catalog hardcode → generic
      default), so one provider serves all of them off one `base_url`.

  ## Two-gate throttling

  Requests pass through two independent throttle layers:

    1. **Group limits** — protects TokenGate from abusive users (client-side).
       Limits are derived from group defaults + member overrides and keyed by
       the user's API key.

    2. **Provider limits** — protects the provider API key from upstream
       rate limits (provider-side). Limits are configured on the provider
       (`max_rpm`, `max_concurrent`, `max_concurrent_per_user`) and inherited
       by every credential — an API key is just an alias + secret. The global
       gates are keyed by credential.id; the per-user concurrency gate is
       keyed by {credential.id, api_key_id} so one heavy user can't swallow
       every slot of a shared subscription provider — when it trips, only
       that user falls back to the next provider.

  Both gates must pass for a request to proceed. Group limits are acquired
  first; if routing succeeds, credential limits are acquired before execution.

  Hot path discipline: auth, limits, budgets and routing read from
  ETS/atomics only. Postgres is touched asynchronously via Oban
  (`Tokengate.Logs.WriteWorker`).

  ## Gateway-local response cache

  An identical non-streaming request is served from ETS (`ResponseCache`) for
  $0: the upstream was already paid by the request that filled the entry, and
  this one never reaches it. The hit keeps the cost contract of the live answer
  — `X-Tokengate-Cost: 0` on every endpoint, plus `usage.cost_usd = 0` on chat,
  where service bodies stay untouched as always.
  """

  use TokengateWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Tokengate.Budgets.Manager, as: Budgets
  alias Tokengate.Budgets.Exemptions
  alias Tokengate.Accounts.GroupMember
  alias Tokengate.GlobalSettings
  alias Tokengate.Limits.Manager, as: Limits
  alias Tokengate.Logs.WriteWorker
  alias Tokengate.Metrics.Collector
  alias Tokengate.Providers
  alias Tokengate.Providers.{Credential, Provider, ProviderLimits}

  alias Tokengate.Proxy.{
    CostCalculator,
    DecisionsTranslator,
    OpenAIAdapter,
    ProviderAdapter,
    PromptOptimizer,
    RawResponse,
    ResponseCache,
    ServiceUsage,
    SessionId,
    TokenEstimator,
    UsageNormalizer
  }

  alias Tokengate.Routing.Router
  alias TokengateWeb.Plugs.MediaBodyParser

  @max_attempts 9
  @max_retries_per_provider 3

  # $0 as a Decimal: the cost a cache hit reports (the upstream was paid when
  # the entry was filled, this request never reached it).
  @zero_cost Decimal.new(0)

  # Política de 400 (ver `next_candidate/4`): antes de descartar la credencial
  # se reemite el MISMO body a la MISMA key — dos intentos inmediatos y
  # consecutivos. Agotados los dos, la credencial se excluye y el cascade sigue
  # con la siguiente key. En ningún caso cuenta como fallo del breaker ni
  # desactiva la key. Sin pausas: el proceso del request no duerme; el
  # enfriamiento real de un upstream que rechaza bodies lo lleva el breaker.
  @max_bad_request_retries 2

  # Timeout de inactividad de un stream proxied, en ms. Se lee en runtime
  # (`stream_idle_timeout_ms/0`), no en compile time, para que un cambio de
  # config aplique sin recompilar. Ver `stream_loop/8`.
  @default_stream_idle_timeout_ms 60_000

  @doc """
  Lists the models accessible to the authenticated API key.
  """
  def models(conn, _params) do
    member = conn.assigns.current_group_member
    json(conn, %{"object" => "list", "data" => Router.models_for(member)})
  end

  @doc """
  Proxies a chat completion request to the routed provider.
  """
  def chat_completions(conn, _params) do
    member = conn.assigns.current_group_member
    payload = conn.body_params
    model = payload["model"]
    limits = conn.assigns.effective_limits
    key_id = member.api_key.id
    request_start = System.monotonic_time(:millisecond)

    {think, effort} = Tokengate.Proxy.Reasoning.parse(payload)

    # Conversation-level cache affinity key. Affinity is keyed by
    # conversation, not by API key — without this, parallel conversations
    # sharing one key evict each other's cached prefixes upstream. Derived
    # from session_id / x-session-id / prompt_cache_key when the client
    # provides one, else hashed from the conversation opening (OpenRouter's
    # own fingerprint heuristic). Used for sticky routing and logging ONLY —
    # it never travels in the upstream body. nil falls back to api_key_hash.
    session_key =
      SessionId.derive(payload, session_id_header(conn))

    # Sticky-routing key: conversation first, API key as fallback. This is
    # what keeps a conversation on the provider that already holds its
    # cached prefix.
    affinity_key = session_key || conn.assigns.api_key_hash

    conn =
      conn
      |> assign(:think, think)
      |> assign(:effort, effort)
      |> assign(:session_key, session_key)
      |> assign(:affinity_key, affinity_key)
      # Stable per-request idempotency key: every upstream attempt of this
      # request (retries and provider fallbacks included) carries the same
      # Idempotency-Key header, so a provider that processed an attempt but
      # lost the response can deduplicate the replay.
      |> assign(:idempotency_key, Ecto.UUID.generate())

    # Limpia el estado por-request ANTES de reservar: la reserva escribe qué se
    # debitó (límite o top-up) y el finalize lo persiste en el log durable.
    # Borrarlo después de reservar descartaba justo el valor nuevo.
    Process.delete(:tg_budget_actual_cost)
    Process.delete(:tg_credit_topup_id)

    with :ok <- require_model(model),
         :ok <- acquire_group_limits(key_id, limits) do
      try do
        case route_and_acquire(member, payload, affinity_key, limits) do
          {:ok, route, hold} ->
            inflight = register_inflight(conn, member, payload, route)

            try do
              if payload["stream"] == true do
                execute_stream(conn, route, payload, member, @max_attempts, [])
              else
                execute(conn, route, payload, member, @max_attempts, [])
              end
            after
              settle_budget(member, hold)
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
  Proxies an embeddings request to the routed provider.

  Non-streaming only. Passthrough: the request is forwarded as received
  and the upstream response is returned untouched — TokenGate only adds
  authentication (provider API key) and cost tracking. The adapter is
  resolved from the routed provider's dialect, so the single OpenAI
  embeddings contract works across every provider.
  """
  def embeddings(conn, _params) do
    payload = conn.body_params

    with :ok <- require_input(payload) do
      simple_proxy(conn, payload, "embedding", &adapter_embeddings/4, :embedding)
    else
      {:error, error} -> render_proxy_error(conn, error)
    end
  end

  # Embeddings through the dialect adapter of the routed provider.
  defp adapter_embeddings(provider, credential, payload, opts) do
    ProviderAdapter.dispatch(provider).embeddings(provider, credential, payload, opts)
  end

  ## The rest of a provider's services #########################################
  #
  # Three capabilities that only differ in the upstream path, so they all run
  # through `service_passthrough/2` — the embeddings pipeline with the
  # service (not the endpoint) as the argument. The service key is the
  # `ProviderPaths` vocabulary and is the SAME one the Capacidades modal
  # writes, so an operator override lands on the wire without a redeploy.

  @doc "Audio → text (transcription) at the provider's speech-to-text service."
  def transcriptions(conn, _params), do: service_passthrough(conn, :stt)

  @doc "Text → audio (speech synthesis) at the provider's text-to-speech service."
  def speech(conn, _params), do: service_passthrough(conn, :tts)

  @doc "Image generation at the provider's images service."
  def image_generations(conn, _params), do: service_passthrough(conn, :image)

  # Shared entry point for the three non-chat services: same gates, routing,
  # fallback matrix, budget hold and accounting as embeddings — the only
  # difference is the path the adapter resolves for `service`.
  #
  # The routing capability IS the model's type: a model registered as `stt` is
  # only reachable from /audio/transcriptions, and that endpoint only serves
  # `stt` models (anything else 400s with model_type_mismatch). Media models
  # created before the vocabulary extension may still say `llm` — the operator
  # re-types them from the admin form.
  defp service_passthrough(conn, service) do
    payload = conn.body_params

    # The raw capture (multipart bodies, for one) travels to the adapter: the
    # upstream must receive the client's exact bytes and content-type, never
    # a re-encoded JSON version of the parsed fields. Nil for JSON requests.
    raw_body = conn.private[MediaBodyParser.raw_body_key()]
    raw_content_type = conn.private[MediaBodyParser.raw_content_type_key()]

    simple_proxy(
      conn,
      payload,
      Atom.to_string(service),
      &adapter_service(&1, &2, &3, &4, service, raw_body, raw_content_type),
      service
    )
  end

  # POST /v1/decisions — the public decisions surface, in the OpenAI
  # Decisions shape (`input` + ordered questions with predicate/choice/
  # score). Routing capability is the model's type: only `decision` models
  # are reachable here (the alias resolves like chat; the model rewrite to
  # the upstream id happens in execute_simple, same as every simple proxy).
  #
  # The shape is validated BEFORE the gates: a malformed body is the
  # caller's fault — it must not pick credentials, retry the fallback
  # matrix or pollute the error logs with a per-attempt 400.
  #
  # kind is :decision so cost accounting bills per token
  # (ServiceUsage "decision"), and the adapter_fun resolves the upstream per
  # provider: verbatim for OpenAI-shape speakers, translated through
  # DecisionsTranslator for System One speakers.
  def decisions(conn, _params) do
    payload = conn.body_params

    with :ok <- DecisionsTranslator.validate(payload) do
      simple_proxy(
        conn,
        payload,
        "decision",
        &Tokengate.Proxy.Decisions.post(&1, &2, &3, &4),
        :decision
      )
    else
      {:error, message} -> render_proxy_error(conn, {:invalid_request, message})
    end
  end

  # The service through the dialect adapter of the routed provider: the
  # adapter owns the URL (base_url + the path `ProviderPaths` resolves). A
  # captured raw body is forwarded byte-for-byte with the client's own
  # content-type (see `TokengateWeb.Plugs.MediaBodyParser`).
  defp adapter_service(provider, credential, payload, opts, service, raw_body, raw_content_type) do
    opts =
      case raw_body do
        raw when is_binary(raw) ->
          Keyword.merge(opts, raw_body: raw, content_type: raw_content_type)

        _ ->
          opts
      end

    ProviderAdapter.dispatch(provider).service_post(provider, credential, service, payload, opts)
  end

  # Shared gate pipeline for non-streaming, non-chat endpoints (embeddings
  # and the three path-routed services): same two-gate throttle, routing,
  # budget check, inflight registry, fallback matrix and cost accounting as
  # chat — minus the chat-only payload transforms (guard rails, prompt
  # optimizer, reasoning).
  defp simple_proxy(conn, payload, capability, adapter_fun, kind) do
    # Same stable idempotency key as the chat path — shared by every
    # upstream attempt of this request.
    conn = assign(conn, :idempotency_key, Ecto.UUID.generate())
    member = conn.assigns.current_group_member
    model = payload["model"]
    limits = conn.assigns.effective_limits
    key_id = member.api_key.id
    request_start = System.monotonic_time(:millisecond)

    # Limpia el estado por-request ANTES de reservar: la reserva escribe qué se
    # debitó (límite o top-up) y el finalize lo persiste en el log durable.
    # Borrarlo después de reservar descartaba justo el valor nuevo.
    Process.delete(:tg_budget_actual_cost)
    Process.delete(:tg_credit_topup_id)

    with :ok <- require_model(model),
         :ok <- acquire_group_limits(key_id, limits) do
      try do
        case route_and_acquire(member, payload, conn.assigns.api_key_hash, limits, [],
               capability: capability
             ) do
          {:ok, route, hold} ->
            inflight = register_inflight(conn, member, payload, route)

            try do
              execute_simple(conn, route, payload, member, @max_attempts, [], adapter_fun, kind,
                capability: capability
              )
            after
              settle_budget(member, hold)
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

    # Gateway-local response cache: identical non-streaming requests hit
    # the local ETS copy instead of paying upstream again.
    #
    # A request with a captured raw body (a multipart audio upload — where
    # the payload's own fields are `MediaFile` metadata) is never cached:
    # its cache key would be built from a payload that does not carry the
    # bytes, so two different uploads would hash EQUAL and the second would
    # get the first one's answer.
    cache_key =
      if conn.private[MediaBodyParser.raw_body_key()] do
        nil
      else
        ResponseCache.cache_key(conn.assigns.api_key_hash, route.model_responded, payload)
      end

    with :miss <- cache_lookup(conn, cache_key) do
      receive_timeout = receive_timeout(route.credential)

      case adapter_fun.(provider, route.credential, payload,
             receive_timeout: receive_timeout,
             forwarded_headers: extract_forwarded_headers(conn, route)
           ) do
        {:ok, body, latency_ms, resp_headers} ->
          Router.record_outcome(route, :success, latency_ms: latency_ms)
          cache_store(cache_key, body)
          finalize_simple_success(conn, route, body, latency_ms, member, kind, resp_headers)

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
            log_and_render_proxy_error(
              conn,
              route,
              member,
              {:upstream_error, :auth_error, status},
              error_reason: "auth_error",
              error_message: error_message
            )
          end

        {:error, :bad_request, status, error_message} ->
          # 400: the provider rejected THIS body for its own reasons — often
          # provider-specific (a field only it refuses, a limit only its model
          # enforces, a prefix over its context window). The shared policy
          # (`next_candidate/4`) reemits the body to the SAME credential twice,
          # back to back, and only then falls back to the next candidate. Either
          # way the rejection is a NON-counting failure: the credential is NOT
          # deactivated, stays in the pool, and the breaker does NOT count it.
          Router.record_outcome(route, {:failure, :bad_request})

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
              reason: :bad_request,
              error_message: error_message
            )
          else
            log_and_render_proxy_error(conn, route, member, {:upstream_client_error, status},
              error_reason: "bad_request",
              error_message: error_message
            )
          end

        {:error, :client_error, status, error_message} ->
          # 4xx other than 400 (404, 422, …). For a marketplace/aggregator a
          # 404 ("No available sellers for this model") is ROUTE-specific —
          # THIS key has no upstream for the model right now — so the cascade
          # moves to the next credential until the list is exhausted. Still a
          # NON-counting failure: the breaker never penalizes the key.
          Router.record_outcome(route, {:failure, :client_error})

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
              reason: :client_error,
              error_message: error_message
            )
          else
            log_and_render_proxy_error(conn, route, member, {:upstream_client_error, status},
              error_reason: "client_error",
              error_message: error_message
            )
          end

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
              error_reason: safe_reason(reason),
              error_message: error_message
            )
          end
      end
    else
      # Acierto de caché: la respuesta (y sus headers) YA salió — `with` sólo
      # tiene que devolver el conn ya enviado. Devolver el centinela `:handled`
      # rompía la acción (Plug.Builder la rechaza: "expected action/2 to return
      # a Plug.Conn … got: :handled") en cada hit.
      {:hit, sent_conn} -> sent_conn
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

    case Router.route(route.model.name, member, %{
           :api_key_hash => conn.assigns.api_key_hash,
           :exclude_credential_ids => exclude,
           :capability => Keyword.get(route_opts, :capability, ["llm", "decision"])
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

      {:error, :no_available_provider} when reason in [:bad_request, :client_error] ->
        # Every remaining candidate rejected the body with the same 4xx. That is
        # not a provider outage, so the client gets the upstream 4xx it can act
        # on instead of a 503.
        log_and_render_proxy_error(conn, route, member, {:upstream_client_error, status},
          error_reason: safe_reason(reason),
          error_message: error_message
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

  defp finalize_simple_success(conn, route, body, latency_ms, member, kind, resp_headers) do
    # A binary 2xx (audio bytes from tts, an asset) carries no usage to read;
    # only the upstream's cost HEADER can still report. `reportable_body/1`
    # keeps the accounting readers on the map shapes they expect.
    reportable = reportable_body(body)

    {usage, _} = simple_usage(conn.body_params, reportable, kind)
    provider_reported = UsageNormalizer.extract_reported_cost(:openai, reportable, resp_headers)

    # Las cantidades facturables del TIPO de esta llamada: es lo que el lane
    # necesita cuando cobra por unidad (imágenes, segundos, caracteres…) en vez
    # de por tokens. Barato y sin efectos: sólo lee request y respuesta.
    quantities = ServiceUsage.quantities(billable_type(route, kind), conn.body_params, reportable)

    cost = cost_with_fallback(route, provider_reported, usage, quantities)

    # Budget is settled in the caller's `after` (it owns the hold); stash the
    # real cost for it here.
    Process.put(:tg_budget_actual_cost, cost)

    Collector.record_request(%{
      model_id: route.model.id,
      provider_id: route.model_provider.credential.provider_id,
      credential_name: route.credential.name,
      agent_type: conn.assigns.agent_type,
      status: 200,
      latency_ms: latency_ms,
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      cost_usd: cost,
      streaming: false
    })

    conn =
      conn
      |> put_resp_header("x-tokengate-cost", Decimal.to_string(cost, :normal))
      |> send_service_response(body)

    # El log durable se encola DESPUÉS de que la respuesta ya salió. Con engine
    # Basic, `Oban.insert/1` es un INSERT en el proceso caller; hacerlo antes de
    # `json/2`/`send_resp` metía esa escritura en la latencia de CADA request.
    # Se mantiene en el mismo proceso (no Task.start): los tests y el
    # `assert_enqueued` siguen viendo el job al volver del request.
    enqueue_log(route, member, conn.assigns.agent_type, usage, cost, latency_ms, 200, false,
      client_agent: conn.assigns.client_agent,
      session_id: conn.assigns[:session_key],
      request_type: to_string(kind)
    )

    conn
  end

  # Usage/cost readers expect a decoded map; a raw 2xx body has nothing to
  # contribute beyond the headers, so it is normalized to an empty map.
  defp reportable_body(%RawResponse{}), do: %{}
  defp reportable_body(body), do: body

  # Renders a 2xx service response. A JSON body keeps the historical `json/1`
  # path; a non-JSON one (audio bytes, an asset) goes back byte-for-byte with
  # the upstream's own content-type — `json/1` cannot send it and would wrap
  # it in an object. `x-tokengate-cost` rides on both.
  defp send_service_response(conn, %RawResponse{} = raw) do
    conn
    |> put_resp_header("content-type", raw.content_type || "application/octet-stream")
    |> send_resp(200, raw.body)
  end

  defp send_service_response(conn, body), do: json(conn, body)

  # Resolves usage for non-chat responses, returning {usage, response_body}.
  #
  # Pure passthrough — the upstream response body is returned untouched.
  # Usage is read from the upstream `usage` object when present; otherwise
  # it's estimated over the request payload (inputs for :embedding).
  defp simple_usage(payload, body, :embedding) do
    usage = UsageNormalizer.normalize(:openai, body) || estimate_embedding_usage(payload)
    {usage, body}
  end

  # The three path-routed services. Their response shapes have almost nothing
  # in common — image generation reports the chat counters under other
  # names, and tts/stt report none at all
  # (audio bytes, a transcript) — so the rule is:
  #
  #   1. what the upstream reported wins (chat names, then the image API's);
  #   2. otherwise the request's own text is estimated, so manual pricing
  #      still books something proportional (the same honest estimate the
  #      embeddings path has always used);
  #   3. no text at all estimates to zero, and zero is `CostCalculator`'s
  #      explicit $0 — we never invent a cost.
  defp simple_usage(payload, body, kind)
       when kind in [:stt, :tts, :image, :decision] do
    {reported_or_estimated_usage(payload, body), body}
  end

  defp reported_or_estimated_usage(payload, body) do
    reported = UsageNormalizer.normalize(:openai, body)

    cond do
      reported != nil and not zero_usage?(reported) -> reported
      tokens = image_tokens(body) -> tokens
      true -> estimated_usage(payload)
    end
  end

  # `usage` present but all-zero means the upstream has no token shape to
  # offer (it echoed an empty object, or a shape we don't read); it must not
  # shadow the estimate.
  defp zero_usage?(usage) do
    Enum.all?(
      [:prompt_tokens, :completion_tokens, :cache_read_tokens, :cache_creation_tokens],
      &(Map.get(usage, &1, 0) == 0)
    )
  end

  # The other token naming an upstream may use for the same counters
  # (`input_tokens` / `output_tokens`, which is how the image generation API
  # labels them) maps onto the internal shape when present.
  defp image_tokens(%{"usage" => %{} = usage}) do
    case {count(usage["input_tokens"]), count(usage["output_tokens"])} do
      {nil, nil} ->
        nil

      {prompt, completion} ->
        %{
          prompt_tokens: prompt || 0,
          completion_tokens: completion || 0,
          cache_read_tokens: 0,
          cache_creation_tokens: 0
        }
    end
  end

  defp image_tokens(_body), do: nil

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: nil

  defp estimate_embedding_usage(payload) do
    %{
      prompt_tokens: estimate_strings(payload["input"]),
      completion_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0
    }
  end

  defp estimated_usage(payload) do
    %{
      prompt_tokens: estimated_prompt_tokens(payload),
      completion_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0
    }
  end

  # The request fields that carry the service's own text: `input` (tts, and
  # stt's JSON variant) and `prompt` (image).
  @estimated_text_fields ~w(input prompt)

  defp estimated_prompt_tokens(payload) do
    Enum.reduce(@estimated_text_fields, 0, fn field, acc ->
      acc + estimate_strings(payload[field])
    end)
  end

  # A field may be a bare string or a list of strings (embeddings inputs);
  # anything else — multimodal blocks, objects — is not
  # guessed at.
  defp estimate_strings(value) do
    value
    |> List.wrap()
    |> Enum.reduce(0, fn
      s, acc when is_binary(s) -> acc + TokenEstimator.estimate_completion(s)
      _, acc -> acc
    end)
  end

  ## Pipeline steps ############################################################

  defp require_model(nil), do: {:error, {:invalid_request, "model is required"}}
  defp require_model(model) when is_binary(model), do: :ok
  defp require_model(_), do: {:error, {:invalid_request, "model must be a string"}}

  defp acquire_group_limits(key_id, limits) do
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
  # embeddings). Decides whether the next attempt should re-select
  # the same credential or exclude it so the router moves to the next
  # provider.
  #
  #   * `:timeout` — the provider hung for the full receive_timeout (or the
  #     first_token_timeout in streaming). A hung provider won't recover in
  #     the milliseconds a retry takes, and each retry would cost another
  #     full timeout of client-perceived latency, so we exclude the
  #     credential immediately and move on.
  #   * `:bad_request` — the provider rejected the body (400). A 400 is often
  #     *route*-specific rather than body-specific: it names a field the
  #     resolved upstream refuses or a limit only that model enforces, and a
  #     marketplace can resolve a DIFFERENT upstream for the very next attempt.
  #     So the same credential gets up to @max_bad_request_retries attempts,
  #     back to back, before it is excluded and the cascade moves to the next
  #     key. The rejection says
  #     nothing about credential health: it is never counted as a failure (no
  #     breaker penalty, no deactivation), so the key stays in the pool for
  #     every other request.
  #   * `:client_error` — a 404 from a marketplace/aggregator ("No available
  #     sellers for this model") is ROUTE-specific: the credential is healthy
  #     but THIS key has no upstream for the model right now, so it is excluded
  #     from the cascade immediately and the next key tries (same treatment as
  #     a timeout — no same-credential retries, sellers don't appear in
  #     milliseconds). Still a NON-counting failure for the breaker.
  #   * any other reason — fast failures (5xx, 429, connection refused) are
  #     often transient and cost almost nothing to retry, so the same
  #     provider gets up to @max_retries_per_provider attempts before being
  #     excluded.
  defp next_candidate(route, exclude, _provider_retries, :timeout) do
    {[route.credential.id | exclude], 0}
  end

  # 404 (marketplace sin sellers del modelo): ver la nota de política arriba —
  # exclusión inmediata, la siguiente credencial de la lista intenta.
  defp next_candidate(route, exclude, _provider_retries, :client_error) do
    {[route.credential.id | exclude], 0}
  end

  # 400: retry the same credential before dropping it from this cascade (see the
  # policy note above).
  defp next_candidate(route, exclude, provider_retries, :bad_request) do
    if provider_retries < @max_bad_request_retries do
      {exclude, provider_retries + 1}
    else
      {[route.credential.id | exclude], 0}
    end
  end

  defp next_candidate(route, exclude, provider_retries, _reason) do
    if provider_retries < @max_retries_per_provider do
      {exclude, provider_retries + 1}
    else
      {[route.credential.id | exclude], 0}
    end
  end

  # Two-level provider-side gate, keyed by credential.id globally and by
  # {credential.id, api_key_id} per user. The limits themselves are owned by
  # the PROVIDER (every key of a provider inherits them):
  #
  #   1. Global — `provider.max_rpm` / `provider.max_concurrent` protect the
  #      upstream API key itself (quota and saturation). Shared by every user
  #      of the credential.
  #   2. Per user — `provider.max_concurrent_per_user` stops a single heavy
  #      user from swallowing every slot of a shared subscription provider.
  #      When it trips, only that user falls back to the next provider;
  #      everyone else keeps using it. nil means unlimited (track but don't
  #      block).
  defp acquire_credential_limits(credential, key_id) do
    provider = provider_of(credential)

    case Limits.acquire(credential.id, %{
           rpm_limit: provider.max_rpm,
           concurrency_limit: provider.max_concurrent
         }) do
      :ok ->
        case Limits.acquire_concurrency(
               {credential.id, key_id},
               provider.max_concurrent_per_user
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
    inflight =
      Tokengate.Logs.Inflight.start_request(%{
        group_member_id: member.id,
        subject_type: if(member.user_id == nil, do: "service", else: "user"),
        service_name: member.service_name,
        user_email: member.user && member.user.email,
        group_name: member.group && member.group.name,
        group_id: member.group_id,
        model_requested: payload["model"],
        agent_type: conn.assigns.agent_type,
        client_agent: conn.assigns.client_agent,
        streaming: payload["stream"] == true,
        think: conn.assigns[:think] || false,
        effort: conn.assigns[:effort],
        provider_name: route.model_provider.credential.provider.name,
        api_key_prefix: member.api_key && member.api_key.key_prefix,
        credential_name: route.credential.name,
        credential_id: route.credential.id,
        provider_key_suffix: provider_key_prefix(route.credential)
      })

    inflight
  end

  @max_route_retries 20

  defp route_and_acquire(member, payload, api_key_hash, limits, exclude \\ [], route_opts \\ []) do
    route_and_acquire(member, payload, api_key_hash, limits, exclude, route_opts, {0, nil})
  end

  # The accumulator threads {attempt, last_reject}: the attempt count caps the
  # cascade, and last_reject remembers WHY the most recent candidate was
  # dropped so an exhausted cascade reports an honest reason instead of always
  # blaming "too many concurrent requests to provider".
  defp route_and_acquire(
         _member,
         _payload,
         _api_key_hash,
         _limits,
         _exclude,
         _route_opts,
         {attempt, last_reject}
       )
       when attempt >= @max_route_retries do
    {:error, {:cascade_exhausted, last_reject || :provider_concurrency_exceeded}}
  end

  defp route_and_acquire(
         member,
         payload,
         api_key_hash,
         limits,
         exclude,
         route_opts,
         {attempt, last_reject}
       ) do
    key_id = member.api_key.id
    model_requested = payload["model"]

    request_context = %{
      "messages" => payload["messages"] || [],
      :api_key_hash => api_key_hash,
      :exclude_credential_ids => exclude,
      :capability => Keyword.get(route_opts, :capability, ["llm", "decision"])
    }

    with {:ok, route} <- Router.route(model_requested, member, request_context) do
      case acquire_credential_limits(route.credential, key_id) do
        :ok ->
          reserve_or_release(member, limits, route, key_id)

        {:error, :provider_concurrency_exceeded} ->
          # Credencial saturada: fallback inmediato al siguiente candidato.
          # No hay cola de espera por facturación — todo provider se trata igual.
          route_and_acquire(
            member,
            payload,
            api_key_hash,
            limits,
            [route.credential.id | exclude],
            route_opts,
            {attempt + 1, :provider_concurrency_exceeded}
          )

        {:error, :provider_user_concurrency_exceeded} ->
          route_and_acquire(
            member,
            payload,
            api_key_hash,
            limits,
            [route.credential.id | exclude],
            route_opts,
            {attempt + 1, :provider_concurrency_exceeded}
          )

        {:error, {:provider_rate_limited, _retry_ms}} ->
          # Rate-limited on this credential: it is excluded from the cascade
          # and the next candidate is tried IMMEDIATELY. No sleeping: the RPM
          # window is enforced by `Limits` on every later request (which will
          # exclude this same credential until the window frees), so making the
          # current request wait only burned client latency with the group and
          # credential slots still held.
          route_and_acquire(
            member,
            payload,
            api_key_hash,
            limits,
            [route.credential.id | exclude],
            route_opts,
            {attempt + 1, :provider_rate_limited}
          )
      end
    else
      {:error, :no_available_provider} when exclude != [] ->
        # Every remaining candidate was excluded during this cascade; the
        # accumulator knows why the last one was dropped.
        {:error, {:cascade_exhausted, last_reject}}

      {:error, error} ->
        {:error, error}
    end
  end

  # Reserves budget once the route + credential slot are locked in. A rejected
  # reservation releases the credential slot so it doesn't leak, and returns
  # the `{:ok, route, hold}` tri-tuple the callers expect. Reserving here (after
  # acquire, not before the retry loop) means route retries never double-hold.
  defp reserve_or_release(member, limits, route, key_id) do
    case reserve_budget(member, limits, route) do
      {:ok, hold} ->
        {:ok, route, hold}

      {:error, error} ->
        release_credential_limits(route.credential, key_id)
        {:error, error}
    end
  end

  # Budget-exemption subject for this request. Services authenticate as
  # virtual GroupMembers (service_name set, user/group nil) — see
  # ApiAuth.service_to_virtual_member/1. Group members check their own user
  # row AND their group's exemptions.
  defp budget_subject(%GroupMember{service_name: name} = member) when not is_nil(name),
    do: %{type: "service", id: member.id}

  defp budget_subject(%GroupMember{} = member), do: %{type: "user", id: member.user_id}

  defp group_subject(%GroupMember{service_name: nil} = member),
    do: %{type: "group", id: member.group_id}

  defp group_subject(_service_member), do: nil

  defp exemption_subjects(member) do
    %{subject: budget_subject(member), group: group_subject(member)}
  end

  defp exempt_from?(scope, member) do
    subjects = exemption_subjects(member)
    Exemptions.exempt?(scope, subjects.subject, subjects.group)
  end

  # Reserves budget for the request on both layers (monthly per subject +
  # global daily kill-switch). Returns `{:ok, hold}` with `%{monthly_micro,
  # global_micro, exempt_global?}`, settled — or released, if the request
  # produced no cost — in the caller's `after` via `settle_budget/2`. Every
  # provider goes through this gate; there is no billing-surface exemption.
  defp reserve_budget(member, limits, _route) do
    reserve_credit_budget(member, limits)
  end

  # Credit path: hold against the subject's spend plan — its monthly limit
  # first, then the top-up that expires soonest (resolved by
  # `Credits.plan/1`). Records WHAT the request debits (limit or top-up id) so
  # the durable log can persist it.
  defp reserve_credit_budget(member, limits) do
    plan = limits.credit_plan || Tokengate.Credits.plan(member)

    result =
      Budgets.reserve_plan(
        plan,
        GlobalSettings.get_daily_cap(),
        max_request_cost_usd(),
        exempt_from?("global_daily", member)
      )

    case result do
      {:ok, hold} ->
        Process.put(:tg_credit_topup_id, hold[:topup] && hold.topup.id)
        {:ok, hold}

      {:error, _} = error ->
        Process.delete(:tg_credit_topup_id)
        error
    end
  end

  # Settles the hold to the real cost recorded by the finalize step. When the
  # request never produced a cost (provider failure / exception), the hold is
  # released instead so it doesn't leak.
  defp settle_budget(_member, %{kind: kind} = hold) when kind in [:limit, :topup, :no_credit] do
    case Process.get(:tg_budget_actual_cost) do
      nil -> Budgets.release_credits(hold)
      cost -> Budgets.settle_credits(hold, cost)
    end
  end

  defp settle_budget(member, hold) do
    case Process.get(:tg_budget_actual_cost) do
      nil -> Budgets.release(member.id, hold)
      cost -> Budgets.settle(member.id, hold, cost)
    end
  end

  # Per-request cost ceiling used to hold budget before the real cost is known.
  # Configurable (`:proxy, :max_request_cost_usd`); defaults to $1.
  #
  # This value is HELD per in-flight request and settled to the real cost
  # afterwards, so it is multiplied by the concurrency level against the
  # global daily cap: an oversized ceiling trips the kill-switch on traffic
  # alone. Keep it close to a realistic request cost.
  defp max_request_cost_usd do
    raw =
      :tokengate
      |> Application.get_env(:proxy, [])
      |> Keyword.get(:max_request_cost_usd, 1)

    case raw do
      %Decimal{} = d -> d
      n when is_number(n) -> Decimal.new(n)
      s when is_binary(s) -> Decimal.new(s)
      _ -> Decimal.new(1)
    end
  end

  ## Provider execution with fallback ##########################################

  # Upstream receive timeout: the provider's own value wins when set; nil
  # falls back to the global config default (see ProviderLimits).
  defp receive_timeout(credential) do
    credential |> provider_of() |> ProviderLimits.receive_timeout_ms()
  end

  # The limits are provider-owned, so every gate below needs the provider
  # struct. Routing already preloads it (`credential: :provider`) and serves it
  # from the 60s routing cache, so the normal path is a plain struct read with
  # no DB hit. A credential that reaches us without it loaded (tests, direct
  # callers) pays one query instead of silently applying no limits at all.
  defp provider_of(%Credential{provider: %Provider{} = provider}), do: provider

  defp provider_of(%Credential{} = credential) do
    Tokengate.Repo.preload(credential, :provider).provider
  end

  # Extracts whitelisted client headers to forward upstream, plus the
  # gateway-generated Idempotency-Key (stable across all attempts of the
  # same client request).
  @forwarded_header_keys %{
    "user-agent" => "user-agent",
    "http-referer" => "http-referer",
    "x-title" => "x-title"
  }

  defp extract_forwarded_headers(conn, route) do
    forwarded =
      @forwarded_header_keys
      |> Enum.reduce(%{}, fn {client_key, upstream_key}, acc ->
        case Plug.Conn.get_req_header(conn, client_key) do
          [value | _] -> Map.put(acc, upstream_key, value)
          [] -> acc
        end
      end)

    forwarded
    |> Map.put("idempotency-key", conn.assigns.idempotency_key)
    # Upstream affinity: OpenRouter's documented sticky-routing key. The
    # conversation session key when available, else the API-key hash.
    |> Map.put("x-session-id", conn.assigns[:session_key] || conn.assigns.api_key_hash)
    # Legacy hint for providers running automatic prefix caching.
    |> Map.put("x-session-affinity", conn.assigns[:affinity_key] || conn.assigns.api_key_hash)
    |> drop_omitted_headers(route)
  end

  # Per model_provider header omissions (e.g. an upstream that rejects or
  # misbehaves on forwarded hints). Only strips the forwarded set —
  # authorization / content-type are adapter-owned and never forwarded here.
  defp drop_omitted_headers(headers, route) do
    case model_provider_setting(route, :omit_headers) || [] do
      [] -> headers
      omit -> Map.drop(headers, omit)
    end
  end

  defp session_id_header(conn) do
    case Plug.Conn.get_req_header(conn, "x-session-id") do
      [value | _] -> value
      [] -> nil
    end
  end

  # ── Gateway-local response cache hooks ──────────────────────────────────
  # lookup returns :miss to fall through to the upstream call; a hit sends the
  # cached body (headers included) and returns {:hit, conn} for the caller to
  # return — the conn is what the action must hand back to Plug.
  #
  # `body_shape` decides what the hit adds to the cached bytes so a hit is
  # indistinguishable from a fresh 200 of the same endpoint:
  #
  #   * `:chat_usage` — the chat body gains `usage.cost_usd` ($0), exactly the
  #     field a live chat completion carries.
  #   * `:passthrough` (default) — service bodies (embeddings, media)
  #     travel untouched, same as the live passthrough contract.
  #
  # A hit costs $0: the upstream was already paid by the request that filled
  # the entry, and this one never reached it.
  defp cache_lookup(conn, key, body_shape \\ :passthrough)

  defp cache_lookup(_conn, nil, _body_shape), do: :miss

  defp cache_lookup(conn, key, body_shape) do
    case ResponseCache.lookup(key) do
      {:ok, body_json, _age} ->
        conn =
          conn
          |> put_resp_header("content-type", "application/json")
          |> put_resp_header("x-tokengate-cache", "hit")
          |> put_resp_header("x-tokengate-cost", Decimal.to_string(@zero_cost, :normal))
          |> send_resp(200, cached_body(body_json, body_shape))

        {:hit, conn}

      :miss ->
        :miss
    end
  end

  # Chat: `usage.cost_usd` is part of the response contract, so the hit carries
  # it too (at $0). An upstream body without a `usage` object (some providers
  # omit it) still gets the cost field rather than losing the contract.
  defp cached_body(body_json, :chat_usage) do
    case Jason.decode(body_json) do
      {:ok, body} when is_map(body) ->
        usage =
          case Map.get(body, "usage") do
            %{} = usage -> usage
            _ -> %{}
          end

        body
        |> Map.put("usage", Map.put(usage, "cost_usd", 0.0))
        |> Jason.encode!()

      _ ->
        body_json
    end
  end

  defp cached_body(body_json, :passthrough), do: body_json

  defp cache_store(nil, _body), do: :ok

  # A raw (non-JSON) body is never cached: it is bytes, not a decoded map.
  defp cache_store(_key, %RawResponse{}), do: :ok

  defp cache_store(key, body) when is_map(body) and not is_struct(body) do
    ResponseCache.store(key, Jason.encode!(body))
  end

  defp cache_store(_key, _body), do: :ok

  defp execute(conn, route, payload, member, attempts_left, exclude) do
    execute(conn, route, payload, member, attempts_left, exclude, 0)
  end

  defp execute(conn, route, payload, member, attempts_left, exclude, provider_retries) do
    provider = route.model_provider.credential.provider

    # El body que viaja a ESTE upstream se construye SIEMPRE desde el body
    # original del cliente: las guard rails del modelo, el dialecto de
    # reasoning que habla el upstream y los overrides del model_provider
    # (`extra_body`, `omit_body_fields`) son POR-UPSTREAM. El body ya reescrito
    # NO se hereda a los reintentos ni al fallback; heredarlo (a) manda el pin
    # del agregador (`provider`) al proveedor DIRECTO que le toca el fallback
    # —que 400ea en un campo que no documenta— y (b) apila las guard rails una
    # vez por intento. `payload` sigue siendo el del cliente para la cascada:
    # cada intento se reescribe desde cero con las reglas de SU upstream.
    attempt_payload =
      payload
      |> Map.put("model", route.model_responded)
      |> inject_guard_rails(route.model)
      |> maybe_optimize(optimize_ctx(conn, route))

    # The effort value THIS attempt sends to the wire: consumed by the log
    # row if the attempt wins (fallbacks rebuild from the client payload, so
    # every attempt re-derives its own value).
    conn = assign(conn, :effort_applied, wire_effort(attempt_payload))

    # Gateway-local response cache (non-streaming chat only): identical
    # requests served from ETS. The key is the body THIS upstream receives, so
    # it stays stable across the retries/fallbacks of one request (they all
    # rebuild the same body for the same route) and never picks up another
    # route's overrides.
    cache_key =
      ResponseCache.cache_key(conn.assigns.api_key_hash, route.model_responded, attempt_payload)

    with :miss <- cache_lookup(conn, cache_key, :chat_usage) do
      receive_timeout = receive_timeout(route.credential)

      case OpenAIAdapter.chat_completion(provider, route.credential, attempt_payload,
             receive_timeout: receive_timeout,
             forwarded_headers: extract_forwarded_headers(conn, route)
           ) do
        {:ok, body, latency_ms, resp_headers} ->
          Router.record_outcome(route, :success, latency_ms: latency_ms)
          cache_store(cache_key, body)
          finalize_success(conn, route, body, latency_ms, member, resp_headers)

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
            log_and_render_proxy_error(
              conn,
              route,
              member,
              {:upstream_error, :auth_error, status},
              error_reason: "auth_error",
              error_message: error_message
            )
          end

        {:error, :bad_request, status, error_message} ->
          # 400: the provider rejected THIS body for its own reasons — often
          # provider-specific (a field only it refuses, a limit only its model
          # enforces, a prefix over its context window). The shared policy
          # (`next_candidate/4`) reemits the body to the SAME credential twice,
          # back to back, and only then falls back to the next candidate. Either
          # way the rejection is a NON-counting failure: the credential is NOT
          # deactivated, stays in the pool, and the breaker does NOT count it.
          Router.record_outcome(route, {:failure, :bad_request})

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
              :bad_request,
              error_message
            )
          else
            log_and_render_proxy_error(conn, route, member, {:upstream_client_error, status},
              error_reason: "bad_request",
              error_message: error_message
            )
          end

        {:error, :client_error, status, error_message} ->
          # 4xx other than 400 (404, 422, …). For a marketplace/aggregator a
          # 404 ("No available sellers for this model") is ROUTE-specific —
          # THIS key has no upstream for the model right now — so the cascade
          # moves to the next credential until the list is exhausted. Still a
          # NON-counting failure: the breaker never penalizes the key.
          Router.record_outcome(route, {:failure, :client_error})

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
              :client_error,
              error_message
            )
          else
            log_and_render_proxy_error(conn, route, member, {:upstream_client_error, status},
              error_reason: "client_error",
              error_message: error_message
            )
          end

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
              error_reason: safe_reason(reason),
              error_message: error_message
            )
          end
      end
    else
      # Acierto de caché: la respuesta (y sus headers) YA salió — `with` sólo
      # tiene que devolver el conn ya enviado. Devolver el centinela `:handled`
      # rompía la acción (Plug.Builder la rechaza: "expected action/2 to return
      # a Plug.Conn … got: :handled") en cada hit.
      {:hit, sent_conn} -> sent_conn
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

      # Aviso de Telegram: una credencial de proveedor fuera de juego (401/402/403
      # — key inválida, sin saldo, prohibida) es exactamente el "se bloqueó una
      # API key de proveedor" que un operador quiere saber al instante. Corre en
      # esta Task para no tocar el camino caliente del proxy.
      Tokengate.Notifications.emit(:credential_disabled, %{
        entity_type: "credential",
        entity_id: credential.id,
        target_label: credential.name,
        reason: reason,
        payload: %{reason: reason}
      })
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
    # are often transient, so those keep the per-provider retries. A 400 goes
    # through the shared policy too (see `next_candidate/4`): same credential
    # twice before it is dropped.
    {exclude, provider_retries} = next_candidate(route, exclude, provider_retries, reason)

    request_context = %{
      "messages" => payload["messages"] || [],
      :api_key_hash => conn.assigns.api_key_hash,
      :exclude_credential_ids => exclude
    }

    case Router.route(route.model.name, member, request_context) do
      {:ok, new_route} ->
        execute(conn, new_route, payload, member, attempts_left - 1, exclude, provider_retries)

      {:error, :no_available_provider} when reason in [:bad_request, :client_error] ->
        # Every remaining candidate rejected the body with the same 4xx. That is
        # not a provider outage, so the client gets the upstream 4xx it can act
        # on instead of a 503.
        log_and_render_proxy_error(conn, route, member, {:upstream_client_error, status},
          error_reason: safe_reason(reason),
          error_message: error_message
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

    # Mismo contrato que `execute/7`: el body por-intento se construye desde el
    # body ORIGINAL del cliente (nunca desde el del intento anterior).
    attempt_payload =
      payload
      |> Map.put("model", route.model_responded)
      |> ensure_stream_options()
      |> inject_guard_rails(route.model)
      |> maybe_optimize(optimize_ctx(conn, route))

    # Same contract as `execute/7`: the applied effort of THIS attempt, for
    # the log row if the attempt wins.
    conn = assign(conn, :effort_applied, wire_effort(attempt_payload))

    # Measured just before the upstream call: TTFT is the time from this
    # point to the provider's first chunk.
    request_start = System.monotonic_time(:millisecond)
    receive_timeout = receive_timeout(route.credential)

    case OpenAIAdapter.stream_chat_completion(provider, route.credential, attempt_payload,
           receive_timeout: receive_timeout,
           forwarded_headers: extract_forwarded_headers(conn, route)
         ) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        case await_first_chunk(pid, ref) do
          {:ok, first_chunk, resp_headers} ->
            ttft_ms = System.monotonic_time(:millisecond) - request_start
            Router.record_outcome(route, :success, latency_ms: ttft_ms)

            conn =
              conn
              |> put_resp_content_type("text/event-stream")
              |> put_resp_header("cache-control", "no-cache")
              |> send_chunked(200)

            stream_loop(conn, pid, ref, first_chunk, route, member, attempt_payload, %{
              usage: nil,
              # Completion deltas accumulate as iodata (a reversed list of
              # binaries) — O(1) per chunk instead of O(n) binary append.
              # Materialized once in finish_stream when the provider omits
              # usage (token-estimator fallback).
              completion: [],
              prompt_estimate:
                TokenEstimator.estimate_messages(attempt_payload["messages"] || []),
              ttft_ms: ttft_ms,
              latency_start: System.monotonic_time(:millisecond),
              resp_headers: resp_headers
            })

          {:error, reason, status, error_message} ->
            # Kill the upstream stream FIRST — before any fallback work. The
            # Finch.stream_while task holds a real HTTP connection open; if we
            # left it running it would only die after the full receive_timeout,
            # leaking connections and file descriptors while the provider is
            # hung. Killing it here closes the socket immediately and frees
            # the credential's concurrency slot.
            Process.exit(pid, :kill)
            Process.demonitor(ref, [:flush])

            if reason == :auth_error do
              disable_credential_async(route.credential, "auth_error_stream")
            end

            Router.record_outcome(route, {:failure, breaker_reason(reason)})

            cond do
              # 400: the provider rejected THIS body. That rejection is often
              # provider-specific, so the shared policy retries the SAME
              # credential twice, back to back, and only then moves to the next
              # candidate. It was already recorded above as a non-counting
              # failure: no breaker penalty, credential stays enabled.
              reason == :bad_request and attempts_left > 1 ->
                log_fallback_attempt(conn, route, member, status, error_message)

                retry_stream_with_fallback(
                  conn,
                  route,
                  payload,
                  member,
                  attempts_left,
                  exclude,
                  provider_retries,
                  :bad_request,
                  status,
                  error_message
                )

              # Un 404 de marketplace/aggregator ("No available sellers") es
              # específico de la RUTA — ESTA key no tiene upstream del modelo
              # ahora mismo — así que la credencial se excluye y la siguiente
              # de la lista intenta, como en el camino no-streaming. Sigue
              # sin contar para el breaker.
              reason == :client_error and attempts_left > 1 ->
                log_fallback_attempt(conn, route, member, status, error_message)

                retry_stream_with_fallback(
                  conn,
                  route,
                  payload,
                  member,
                  attempts_left,
                  exclude,
                  provider_retries,
                  :client_error,
                  status,
                  error_message
                )

              # Any other non-auth 4xx surfacing here (a 400 whose cascade is
              # exhausted, a 404/422 with no candidate left) is delivered as
              # the upstream 4xx the client can act on — never a 503.
              reason in [:client_error, :bad_request] ->
                log_and_render_proxy_error(
                  conn,
                  route,
                  member,
                  {:upstream_client_error, status},
                  error_reason: safe_reason(reason),
                  error_message: error_message
                )

              attempts_left > 1 ->
                log_fallback_attempt(conn, route, member, status, error_message)

                retry_stream_with_fallback(
                  conn,
                  route,
                  payload,
                  member,
                  attempts_left,
                  exclude,
                  provider_retries,
                  reason,
                  status,
                  error_message
                )

              true ->
                log_and_render_proxy_error(conn, route, member, {:upstream_error, reason, status},
                  error_reason: safe_reason(reason),
                  error_message: error_message
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
         reason,
         status,
         error_message
       ) do
    # Same shared policy as retry_with_fallback: timeouts fall back
    # immediately, 400s get their two same-credential attempts, and fast
    # errors retry the same provider up to @max_retries_per_provider.
    {exclude, provider_retries} = next_candidate(route, exclude, provider_retries, reason)

    request_context = %{
      "messages" => payload["messages"] || [],
      :api_key_hash => conn.assigns.api_key_hash,
      :exclude_credential_ids => exclude
    }

    case Router.route(route.model.name, member, request_context) do
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

      {:error, :no_available_provider} when reason in [:bad_request, :client_error] ->
        # Every remaining candidate rejected the body with the same 4xx. That is
        # not a provider outage, so the client gets the upstream 4xx it can act
        # on instead of a 503.
        log_and_render_proxy_error(conn, route, member, {:upstream_client_error, status},
          error_reason: safe_reason(reason),
          error_message: error_message
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

  # `stream_options` is the gateway's: the plan needs real usage for cost
  # accounting, so `include_usage` is forced on regardless of what the client
  # sent. The client's value is merged, not replaced — but a client may send
  # an explicit `null` (SDKs serialise unused knobs that way) and
  # `Map.get(payload, "stream_options", %{})` would NOT fall back to the
  # default, because the key exists with a nil value: `Map.put(nil, …)` then
  # raised BadMapError and a streaming request died with a 500. A
  # non-map value (a string, a list) is refused the same way.
  defp ensure_stream_options(payload) do
    options =
      case Map.get(payload, "stream_options") do
        %{} = map -> map
        _ -> %{}
      end

    Map.put(payload, "stream_options", Map.put(options, "include_usage", true))
  end

  # Injects the model's guard_rails at the beginning of the system prompt.
  # If there is no system message yet, creates one. If there is one, prepends
  # the guard_rails text. No-op when guard_rails is nil or empty.
  defp inject_guard_rails(payload, model) do
    case model.guard_rails do
      nil ->
        payload

      "" ->
        payload

      guard_rails ->
        # `payload["messages"] || []` — not `Map.get(…, [])`: an explicit
        # `null` in the client body returns nil (the key exists), and
        # `[msg | nil]` is an improper list that dies later in Jason.encode!.
        messages = payload["messages"] || []

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

  # Applies the mandatory prompt-pre-flight transforms for LLM (chat)
  # models: system messages are hoisted to the front and deduped
  # (stable_prefix), then noisy tool output is trimmed and deduped
  # (lazy_cleanup), reasoning artifacts are stripped from historical
  # assistant messages (strip_reasoning). All passes are pure; the input is
  # never mutated. No cache-routing body hint (`prompt_cache_key`,
  # `session_id`) is attached to anyone — strict upstreams (Fireworks) 400 on
  # undocumented body fields; affinity travels in the session HEADER only.
  # Non-LLM models (and embeddings routes, which never call this function)
  # pass through unchanged.
  defp maybe_optimize(payload, %{model_type: "llm"} = route_ctx) do
    messages = payload["messages"] || []

    payload
    |> Map.put("messages", PromptOptimizer.stable_prefix(messages))
    |> Map.update!("messages", &PromptOptimizer.lazy_cleanup/1)
    |> Map.update!("messages", &PromptOptimizer.strip_reasoning/1)
    |> drop_strict_fields(provider_key(route_ctx))
    |> normalize_reasoning(route_ctx)
    # Operator overrides run LAST so they can strip/replace anything the
    # gateway or the client put in the body (a per-row `omit_body_fields`
    # can pull a client field back out, and `extra_body` can add/replace).
    |> apply_request_overrides(route_ctx)
  end

  defp maybe_optimize(payload, _model_model), do: payload

  # Body keys the gateway owns (model mapping, passthrough body, usage
  # accounting): never a valid rename target nor an override target — an
  # override there would break routing or cost tracking.
  @protected_body_keys ~w(model messages stream_options)

  @reasoning_knob_keys ~w(reasoning reasoning_effort thinking)

  # Reshapes the client's reasoning knobs into the ONE wire dialect the
  # serving upstream documents: `Catalog.reasoning_dialect/1` of the route's
  # provider catalog key. `:passthrough` (no dialect declared) sends the
  # body untouched — except for the operator's effort policy, which can only
  # rewrite an effort knob the client actually sent (there is no dialect to
  # emit a field the client left out).
  defp normalize_reasoning(payload, route_ctx) do
    case Tokengate.Providers.Catalog.reasoning_dialect(provider_key(route_ctx)) do
      :passthrough ->
        rewrite_passthrough_effort(payload, effort_policy(route_ctx))

      dialect ->
        intent =
          payload
          |> read_reasoning_intent()
          |> apply_effort_policy(effort_policy(route_ctx), dialect)

        reshape_reasoning(payload, intent, dialect)
    end
  end

  # The operator's effort policy for this attempt's logical model, read from
  # the routing context (built per attempt by `optimize_ctx/2`). Both nil =
  # no-op: the body stays byte-identical to the ungated behaviour.
  defp effort_policy(route_ctx) do
    %{effort_default: route_ctx[:effort_default], effort_override: route_ctx[:effort_override]}
  end

  # Applies the operator's effort policy to the client's reasoning intent.
  # Precedence: `effort_override` > (effort in ~w(none minimal) →
  # `effort_default`) > client effort > absence.
  #
  # An `effort_override` also lifts a client hard-off (`enabled: false`):
  # leaving it in place would flatten the wire effort back to "none"/a
  # disabled toggle and defeat the override — exactly the 400 the policy
  # exists to prevent. The dialects keep deciding FIELD PLACEMENT; the policy
  # only substitutes the VALUE.
  defp apply_effort_policy({_effort, enabled}, %{effort_override: override}, _dialect)
       when is_binary(override) and override != "" do
    # Lift a hard-off only; a client that sent nothing keeps `nil` enabled so
    # the dialect emits just the effort field, no extra toggle.
    {override, if(enabled == false, do: true, else: enabled)}
  end

  # `:scalar` fabricates `reasoning_effort: "none"` from a client hard-off on
  # its own — one of the two 400 sources the policy exists to prevent (the
  # other is the client's explicit `none`). An `effort_default` replaces that
  # gateway-made value too, which means lifting the disable: in this dialect
  # it only exists to express `none`. Every other dialect renders a hard-off
  # as a toggle, never as an effort, so their disable is left alone.
  defp apply_effort_policy({effort, false}, %{effort_default: default}, :scalar)
       when (is_nil(effort) or effort in ~w(none minimal)) and is_binary(default) and
              default != "" do
    {default, true}
  end

  defp apply_effort_policy({effort, enabled}, %{effort_default: default}, _dialect)
       when effort in ~w(none minimal) and is_binary(default) and default != "" do
    {default, enabled}
  end

  defp apply_effort_policy(intent, _policy, _dialect), do: intent

  # Effort policy over a `:passthrough` body: the client body travels
  # verbatim, so the policy rewrites the effort knob the client actually sent
  # (scalar beats nested, same precedence as `read_reasoning_intent/1`) and
  # never invents one. With no client effort there is nothing to rewrite —
  # not even for an override, whose value only lands when a dialect emits it.
  defp rewrite_passthrough_effort(payload, policy)

  defp rewrite_passthrough_effort(payload, %{effort_override: override})
       when is_binary(override) and override != "" do
    rewrite_passthrough_effort_value(payload, override)
  end

  defp rewrite_passthrough_effort(payload, %{effort_default: default})
       when is_binary(default) and default != "" do
    case read_reasoning_intent(payload) do
      {effort, _enabled} when effort in ~w(none minimal) ->
        rewrite_passthrough_effort_value(payload, default)

      _ ->
        payload
    end
  end

  defp rewrite_passthrough_effort(payload, _policy), do: payload

  defp rewrite_passthrough_effort_value(%{"reasoning_effort" => effort} = payload, new_effort)
       when is_binary(effort) and effort != "" do
    Map.put(payload, "reasoning_effort", new_effort)
  end

  defp rewrite_passthrough_effort_value(
         %{"reasoning" => %{"effort" => effort} = reasoning} = payload,
         new_effort
       )
       when is_binary(effort) and effort != "" do
    Map.put(payload, "reasoning", Map.put(reasoning, "effort", new_effort))
  end

  defp rewrite_passthrough_effort_value(payload, _new_effort), do: payload

  # The effort value THIS attempt's body carries to the wire (nil = no effort
  # field): what `request_logs.effort_applied` stores for the winning
  # attempt. Covers every dialect — scalar (and the disabled flatten) emit
  # the top-level key, OpenRouter nests it, `:passthrough` keeps the client's
  # verbatim knob.
  defp wire_effort(%{"reasoning_effort" => effort}) when is_binary(effort) and effort != "",
    do: effort

  defp wire_effort(%{"reasoning" => %{"effort" => effort}})
       when is_binary(effort) and effort != "",
       do: effort

  defp wire_effort(_payload), do: nil

  # The client's reasoning intent, read from any of the three wire forms.
  # Precedence: an explicit scalar beats the nested object's effort; a nested
  # `enabled: false` is a hard off. Returns {effort_or_nil, enabled_boolean}.
  defp read_reasoning_intent(payload) do
    nested = payload["reasoning"]
    scalar = payload["reasoning_effort"]
    toggle = payload["thinking"]

    nested_effort = if is_map(nested), do: nested["effort"], else: nil
    nested_enabled = if is_map(nested), do: nested["enabled"], else: nil

    toggle_enabled =
      cond do
        is_map(toggle) -> toggle["type"] != "disabled"
        is_boolean(toggle) -> toggle
        true -> nil
      end

    effort =
      cond do
        is_binary(scalar) and scalar != "" -> scalar
        is_binary(nested_effort) and nested_effort != "" -> nested_effort
        true -> nil
      end

    enabled =
      cond do
        is_boolean(nested_enabled) -> nested_enabled
        is_boolean(toggle_enabled) -> toggle_enabled
        effort -> true
        true -> nil
      end

    {effort, enabled}
  end

  defp reshape_reasoning(payload, {effort, enabled}, dialect) do
    base = Map.drop(payload, @reasoning_knob_keys)

    fields =
      case dialect do
        :scalar ->
          # Fireworks/DeepInfra: scalar only; disabled flattens to "none".
          if enabled == false, do: %{"reasoning_effort" => "none"}, else: maybe_effort(effort)

        :openrouter_nested ->
          # OpenRouter: the nested object form; absence of knobs means the
          # upstream default (we never invent an effort the client didn't send).
          cond do
            enabled == false -> %{"reasoning" => %{"enabled" => false}}
            effort -> %{"reasoning" => %{"effort" => effort}}
            true -> %{}
          end

        :toggle_xor_effort ->
          # Moonshot/Kimi: mutually exclusive (400 with both) — effort wins
          # when present, else the toggle (an explicit toggle survives; no
          # knobs at all means no fields, matching thinking_toggle_extras).
          cond do
            enabled == false -> %{"thinking" => %{"type" => "disabled"}}
            effort -> %{"reasoning_effort" => effort}
            enabled == true -> %{"thinking" => %{"type" => "enabled"}}
            true -> %{}
          end

        :toggle_and_effort ->
          # Z.AI/GLM: both coexist; only emit what the client expressed
          # (server default is thinking on).
          cond do
            enabled == false ->
              %{"thinking" => %{"type" => "disabled"}}

            true ->
              fields = maybe_effort(effort)

              if enabled == true,
                do: Map.put(fields, "thinking", %{"type" => "enabled"}),
                else: fields
          end

        :deepseek_native ->
          # DeepSeek v4+: the toggle is ALWAYS emitted explicitly (omitted
          # defaults thinking on and then demands reasoning_content echoes).
          toggle_type = if enabled == false, do: "disabled", else: "enabled"
          Map.put(maybe_effort(effort), "thinking", %{"type" => toggle_type})
      end

    Map.merge(base, fields)
  end

  defp maybe_effort(nil), do: %{}

  defp maybe_effort(effort) when is_binary(effort) and effort != "",
    do: %{"reasoning_effort" => effort}

  defp maybe_effort(_), do: %{}

  # Per model_provider upstream overrides, applied last in the payload
  # pipeline so they win over every gateway injection (session hints).
  # Defaults are no-ops. `model`, `messages` and
  # `stream_options` are protected: the gateway owns them (model mapping,
  # passthrough body, usage accounting) and an override there would break
  # routing or cost tracking.
  defp apply_request_overrides(payload, route_ctx) do
    extra = model_provider_setting(route_ctx, :extra_body) || %{}
    omit = model_provider_setting(route_ctx, :omit_body_fields) || []

    payload
    |> Map.merge(Map.drop(extra, @protected_body_keys))
    |> Map.drop(omit -- @protected_body_keys)
  end

  # The provider's catalog key, used to select the safe session-hint fields
  # (and any other provider-specific behaviour). Tolerates structs or plain
  # maps and a missing credential/provider — nil falls back to the tolerant
  # default field list.
  defp provider_key(route_ctx) do
    mp = Map.get(route_ctx, :model_provider) || Map.get(route_ctx, "model_provider") || %{}
    credential = Map.get(mp, :credential) || Map.get(mp, "credential") || %{}
    provider = Map.get(credential, :provider) || Map.get(credential, "provider") || %{}

    Map.get(provider, :key) || Map.get(provider, "key")
  end

  # Reads a model_provider field tolerating structs or plain maps (the route
  # may come from the routing cache) and atom or string keys.
  defp model_provider_setting(route_ctx, key) do
    mp = Map.get(route_ctx, :model_provider) || %{}

    case Map.get(mp, key, :__missing__) do
      :__missing__ -> Map.get(mp, Atom.to_string(key))
      value -> value
    end
  end

  # Context for the pre-flight transform pipeline: everything the passes
  # need that isn't in the payload itself. Built once per attempt from the
  # conn assigns and the routed model_provider.
  defp optimize_ctx(_conn, route) do
    %{
      model_type: route.model && route.model.model_type,
      model_provider: route.model_provider,
      # Operator effort policy of the logical model (nil/nil = no-op).
      effort_default: route.model && route.model.effort_default,
      effort_override: route.model && route.model.effort_override,
      extra_body: model_provider_setting(route, :extra_body),
      omit_body_fields: model_provider_setting(route, :omit_body_fields),
      omit_headers: model_provider_setting(route, :omit_headers)
    }
  end

  # Removes the body fields a provider's catalog entry declares unacceptable.
  # Nothing declares any today (the Fireworks `session_id` entry is gone: that
  # field is no longer injected at all), so this pass is a no-op for every
  # provider — it stays as the seam for a strict upstream, and as the reason
  # `Catalog.omit_body_fields/1` still exists. Per-ROW omissions are a
  # different knob (`apply_request_overrides`, driven by the model_provider
  # column). `model`, `messages` and `stream_options` are protected: the
  # gateway owns them.
  defp drop_strict_fields(payload, provider_key) do
    case Tokengate.Providers.Catalog.omit_body_fields(provider_key) do
      [] -> payload
      fields -> Map.drop(payload, fields -- @protected_body_keys)
    end
  end

  defp await_first_chunk(pid, ref) do
    timeout = Application.get_env(:tokengate, :first_token_timeout_ms, 15_000)

    receive do
      {:sse_headers, headers} ->
        # Headers arrive before any data chunk — keep waiting for the first
        # actual content chunk, but stash the headers for the caller to pick up.
        case await_first_chunk_after_headers(pid, ref, timeout) do
          {:ok, chunk} -> {:ok, chunk, headers}
          error -> error
        end

      {:sse_chunk, chunk} ->
        {:ok, chunk, []}

      {:sse_done} ->
        {:error, :empty_stream, nil, nil}

      {:sse_error, {reason, status, message}} ->
        {:error, stream_error_reason(reason), status, message}

      {:sse_error, {reason, status}} ->
        {:error, stream_error_reason(reason), status, nil}

      {:sse_error, reason} ->
        {:error, stream_error_reason(reason), nil, nil}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, stream_error_reason(reason), nil, nil}
    after
      timeout -> {:error, :timeout, nil, nil}
    end
  end

  # Waits for the first data chunk after headers have been received.
  defp await_first_chunk_after_headers(pid, ref, timeout) do
    receive do
      {:sse_chunk, chunk} ->
        {:ok, chunk}

      {:sse_done} ->
        {:error, :empty_stream, nil, nil}

      {:sse_error, {reason, status, message}} ->
        {:error, stream_error_reason(reason), status, message}

      {:sse_error, {reason, status}} ->
        {:error, stream_error_reason(reason), status, nil}

      {:sse_error, reason} ->
        {:error, stream_error_reason(reason), nil, nil}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, stream_error_reason(reason), nil, nil}
    after
      timeout -> {:error, :timeout, nil, nil}
    end
  end

  defp stream_error_reason({reason, _status}) when is_atom(reason), do: reason
  defp stream_error_reason(reason) when is_atom(reason), do: reason
  # Un Task que muere por excepción entrega `{excepción, stacktrace}` como
  # reason. Dejarlo pasar tal cual (struct) revienta más tarde en
  # `error_details/1`, que hace `to_string/1` sobre el reason: 500 sin fila de
  # log. Un crash sin clasificar es un fallo del proveedor visto desde el
  # cliente, así que degrada al reason genérico.
  defp stream_error_reason({_exception, _stacktrace}), do: :server_error
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
        after
          stream_idle_timeout_ms() ->
            # El upstream quedó mudo con la conexión abierta (el
            # `receive_timeout` de Finch es por lectura de socket, así que un
            # stream que gotea o un upstream colgado no lo disparan). Sin este
            # `after` el proceso del request, su slot de concurrencia y la
            # conexión Finch quedaban retenidos para siempre y el cliente veía
            # un stream que nunca cerraba.
            Process.exit(pid, :kill)
            Process.demonitor(ref, [:flush])

            Router.record_outcome(route, {:failure, :timeout})

            conn =
              send_stream_frame(
                conn,
                ~s(data: {"error":{"message":"upstream stream stalled"}}\n\n)
              )

            finish_stream(conn, route, member, acc)
        end

      {:client_gone, conn} ->
        Process.exit(pid, :kill)
        conn
    end
  end

  # Idle window of a stream, in ms: the maximum gap between two chunks from
  # the upstream before the request is cut off. Runtime read (not a module
  # attribute) so the config applies without recompiling.
  defp stream_idle_timeout_ms do
    Application.get_env(
      :tokengate,
      :stream_idle_timeout_ms,
      @default_stream_idle_timeout_ms
    )
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

  # Fast path: the only chunk that needs decoding is the provider's final
  # usage frame. Everything else (99%+ of chunks in a long stream) is
  # forwarded untouched after a cheap binary scan — decoding every SSE
  # payload just to detect usage used to burn CPU per emitted token.
  defp maybe_capture_usage(chunk, route, acc) do
    if :binary.match(chunk, "\"usage\"") == :nomatch or
         not String.starts_with?(String.trim(chunk), "{") do
      {chunk, acc}
    else
      decode_usage_chunk(chunk, route, acc)
    end
  end

  defp decode_usage_chunk(chunk, route, acc) do
    case Jason.decode(chunk) do
      {:ok, decoded} ->
        case UsageNormalizer.from_openai_stream_chunk(decoded, acc.resp_headers) do
          nil ->
            if acc.usage == nil do
              {chunk, %{acc | completion: [extract_delta_text(decoded) | acc.completion]}}
            else
              {chunk, acc}
            end

          usage ->
            cost = stream_cost(route, usage, decoded, acc.resp_headers)
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
    # Latency se mide ANTES de nuestros frames de cierre: describe el stream
    # del upstream, no lo que escribimos después de que terminó.
    latency_ms = System.monotonic_time(:millisecond) - acc.latency_start

    {usage, cost} =
      case acc.usage do
        {usage, cost} ->
          {usage, cost}

        nil ->
          # Provider sent no usage — fall back to the chars/4 heuristic over
          # the accumulated completion so cost accounting still works.
          completion_text = acc.completion |> Enum.reverse() |> IO.iodata_to_binary()

          usage = %{
            prompt_tokens: acc.prompt_estimate,
            completion_tokens: TokenEstimator.estimate_completion(completion_text),
            cache_read_tokens: 0,
            cache_creation_tokens: 0
          }

          cost = stream_cost(route, usage, nil, acc.resp_headers)
          {usage, cost}
      end

    # El costo SIEMPRE llega al cliente en un stream, igual que en el
    # no-streaming. Cuando el upstream emitió su frame de usage, ese frame ya
    # viajó con `cost_usd` inyectado (ver `decode_usage_chunk/3`) y no se
    # duplica; cuando no lo emitió —ignoró `include_usage`, o su dialecto no
    # reporta usage— lo emitimos nosotros antes del `[DONE]` con el mismo shape
    # de OpenAI y el costo del request (`stream_cost/4`: lo reportado por el
    # upstream, luego pricing manual, luego $0). Sin esto el cliente se quedaba
    # sin costo justo cuando el upstream callaba.
    conn = maybe_send_usage_frame(conn, acc.usage != nil, route, usage, cost)
    conn = send_stream_frame(conn, "data: [DONE]\n\n")

    # Budget is settled in the caller's `after` (it owns the hold); stash the
    # real cost for it here.
    Process.put(:tg_budget_actual_cost, cost)

    Collector.record_request(%{
      model_id: route.model.id,
      provider_id: route.model_provider.credential.provider_id,
      credential_name: route.credential.name,
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
      effort_applied: conn.assigns[:effort_applied],
      session_id: conn.assigns[:session_key],
      client_agent: conn.assigns.client_agent
    )

    conn
  end

  # El upstream ya mandó su frame de usage (con `cost_usd` inyectado): no se
  # agrega otro.
  defp maybe_send_usage_frame(conn, true, _route, _usage, _cost), do: conn

  # El upstream no reportó usage: se emite el frame de cierre con el costo del
  # request, mismo shape que OpenAI (`choices: []` + `usage`), para que un
  # cliente que sólo lee el stream reciba igual el costo. Las cuentas de tokens
  # son las MISMAS con las que se contabiliza el request (el estimador, ver
  # `finish_stream/4`), igual que el camino no-streaming inyecta su estimación
  # cuando el proveedor no manda `usage`.
  defp maybe_send_usage_frame(conn, false, route, usage, cost) do
    frame =
      Jason.encode!(%{
        "object" => "chat.completion.chunk",
        "model" => route.model_responded,
        "choices" => [],
        "usage" => %{
          "prompt_tokens" => usage.prompt_tokens,
          "completion_tokens" => usage.completion_tokens,
          "total_tokens" => usage.prompt_tokens + usage.completion_tokens,
          "cost_usd" => Decimal.to_float(cost)
        }
      })

    send_stream_frame(conn, "data: #{frame}\n\n")
  end

  # Un frame SSE al cliente. Un socket cerrado no es un error del request: el
  # cliente se fue y el resto del stream ya no le importa.
  defp send_stream_frame(conn, frame) do
    case Plug.Conn.chunk(conn, frame) do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
    end
  end

  defp stream_cost(route, usage, body, resp_headers) do
    provider_reported =
      if body, do: UsageNormalizer.extract_reported_cost(:openai, body, resp_headers), else: nil

    if provider_reported do
      CostCalculator.provider_cost(provider_reported)
    else
      # Body had no cost — try headers alone (LiteLLM proxies report cost only
      # in headers, not in the streaming body).
      header_cost = UsageNormalizer.extract_reported_cost(:openai, %{}, resp_headers)

      if header_cost do
        CostCalculator.provider_cost(header_cost)
      else
        # Neither body nor headers reported a cost — try manual pricing fallback.
        manual_cost(route, usage)
      end
    end
  end

  # Computes cost using the full fallback chain: reported cost first, then
  # manual pricing, then $0.
  #
  # Manual pricing has TWO shapes and the lane declares which one it uses
  # (`model_providers.pricing_unit`): token units read the three
  # `*_cost_per_million` columns against the token counts, and every other unit
  # (per image/second/minute/character/request) reads `unit_cost` against the
  # billable `quantities` of the call — which is what makes the media services
  # priceable at all.
  #
  # Used by finalize_simple_success and finalize_success (non-streaming).
  defp cost_with_fallback(route, provider_reported, usage, quantities) do
    mp = route.model_provider

    CostCalculator.provider_cost(provider_reported,
      manual_pricing: %{
        input_cost_per_million: mp.input_cost_per_million,
        output_cost_per_million: mp.output_cost_per_million,
        cache_cost_per_million: mp.cache_cost_per_million
      },
      usage: usage,
      pricing_unit: mp.pricing_unit,
      unit_cost: mp.unit_cost,
      quantities: quantities
    )
  end

  # Computes cost from manual pricing alone. Used by stream_cost when neither
  # body nor headers reported a cost. The quantities are the chat's own: only
  # `per_request` (a lane can be priced per call), token units are read from
  # the usage by token_pricing, not from this map.
  defp manual_cost(route, usage) do
    cost_with_fallback(route, nil, usage, ServiceUsage.quantities("llm", %{}, %{}))
  end

  # El tipo con el que se factura la llamada: el del modelo registrado, y si
  # ese quedó en `"llm"` (rows creados antes de que existieran los tipos de
  # servicio) el del propio endpoint, que sí sabe qué servicio se llamó.
  defp billable_type(route, kind) do
    case route.model.model_type do
      type when is_binary(type) and type != "llm" -> type
      _ -> to_string(kind)
    end
  end

  ## Success finalization #######################################################

  defp finalize_success(conn, route, body, latency_ms, member, resp_headers) do
    usage =
      UsageNormalizer.normalize(:openai, body, resp_headers) ||
        fallback_usage(conn.body_params, body)

    provider_reported = UsageNormalizer.extract_reported_cost(:openai, body, resp_headers)

    # El chat cobra por tokens casi siempre, pero `Pricing` también ofrece
    # `per_request` para lanes llm: sin quantities un lane así facturaba $0
    # (la cantidad de "per_request" es la llamada misma, 1). El mapa que
    # devuelve ya trae `"per_request" => 1` SIEMPRE, así que el camino de
    # tokens no cambia.
    cost =
      cost_with_fallback(
        route,
        provider_reported,
        usage,
        ServiceUsage.quantities("llm", conn.body_params, reportable_body(body))
      )

    # Hot-path state updates (ETS only)
    # Budget is settled in the caller's `after` (it owns the hold); stash the
    # real cost for it here.
    Process.put(:tg_budget_actual_cost, cost)

    Collector.record_request(%{
      model_id: route.model.id,
      provider_id: route.model_provider.credential.provider_id,
      credential_name: route.credential.name,
      agent_type: conn.assigns.agent_type,
      status: 200,
      latency_ms: latency_ms,
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      cost_usd: cost,
      streaming: false
    })

    # Durable log + webhooks, async via Oban — encolado DESPUÉS de responder
    # (ver `finalize_simple_success/7`: el INSERT corría antes del `json/2`).
    body = inject_usage_costs(body, usage, cost)

    conn =
      conn
      |> put_resp_header("x-tokengate-cost", Decimal.to_string(cost, :normal))
      |> json(body)

    enqueue_log(route, member, conn.assigns.agent_type, usage, cost, latency_ms, 200, false,
      think: conn.assigns[:think] || false,
      effort: conn.assigns[:effort],
      effort_applied: conn.assigns[:effort_applied],
      session_id: conn.assigns[:session_key],
      client_agent: conn.assigns.client_agent
    )

    conn
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

  # Resolves the subject identity for a durable log. Services arrive as
  # "virtual" members (`user_id == nil`) — their logs store `service_id` and a
  # null `group_member_id`, while real group members store `group_member_id`.
  defp log_subject(%GroupMember{user_id: nil} = member) do
    %{subject_type: "service", group_member_id: nil, service_id: member.id}
  end

  defp log_subject(%GroupMember{} = member) do
    %{subject_type: "user", group_member_id: member.id, service_id: nil}
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
    subject = log_subject(member)

    %{
      "group_member_id" => subject.group_member_id,
      "user_id" => member.user_id,
      "service_id" => subject.service_id,
      "subject_type" => subject.subject_type,
      "provider_id" => route.model_provider.credential.provider_id,
      "model_provider_id" => route.model_provider.id,
      "model_id" => route.model.id,
      "model_requested" => route.model.name,
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
      "credit_topup_id" => Process.get(:tg_credit_topup_id),
      "latency_ms" => latency_ms,
      "ttft_ms" => Keyword.get(extra, :ttft_ms),
      "streaming" => streaming,
      "request_type" => Keyword.get(extra, :request_type, "chat"),
      "think" => Keyword.get(extra, :think, false),
      "effort" => Keyword.get(extra, :effort),
      # What the WINNING attempt sent to the wire (nil = no effort on the
      # wire). `effort` keeps the client's intent; the pair makes the
      # operator effort policy's rewrite visible.
      "effort_applied" => Keyword.get(extra, :effort_applied),
      "api_key_prefix" => member.api_key && member.api_key.key_prefix,
      "api_key_id" => member.api_key && member.api_key.id,
      "session_id" => Keyword.get(extra, :session_id),
      "credential_name" => route.credential.name,
      "credential_id" => route.credential.id,
      "provider_key_prefix" => provider_key_prefix(route.credential),
      # Idempotencia (C2): fijado UNA vez en enqueue — cada reintento de Oban
      # lleva la MISMA pareja (oban_job_id, inserted_at) y cae en la MISMA
      # partición. Sin esto, log_request regeneraría el timestamp por intento.
      "inserted_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
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

    # El texto del vendor (ya scrubbeado y truncado por el adapter) es la
    # ÚNICA pista accionable de un rechazo upstream. Sin pasarlo a las dos
    # salidas — la fila de `request_logs.error_message` y el body del
    # cliente — el diagnóstico queda en "Provider rejected the request (400)"
    # y no hay forma de saber QUÉ campo rechazó el upstream.
    upstream_message = Keyword.get(opts, :error_message)

    # La respuesta al cliente sale PRIMERO; el INSERT del log durable (Oban,
    # engine Basic) ya no está en el camino de latencia del error.
    conn = render_proxy_error(conn, error, upstream_message)

    enqueue_error_log(conn, route, member,
      client_status: client_status,
      provider_status: provider_status,
      error_reason: Keyword.get(opts, :error_reason, code),
      error_message: upstream_message,
      latency_ms: Keyword.get(opts, :latency_ms, 0),
      streaming: conn.body_params["stream"] == true
    )

    Collector.record_request(%{
      model_id: route.model.id,
      provider_id: route.model_provider.credential.provider_id,
      credential_name: route.credential.name,
      agent_type: conn.assigns.agent_type,
      status: client_status,
      latency_ms: Keyword.get(opts, :latency_ms, 0),
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd: Decimal.new(0),
      streaming: conn.body_params["stream"] == true
    })

    conn
  end

  # Gate-level errors (before routing succeeded): no provider was contacted,
  # so there is no provider status to record. Still logs the failure — and
  # resolves the model id so these rows show up in the per-model stats
  # drill-down (stats page, provider breakdown). Without it, a burst of gate
  # errors (concurrency exceeded, rate limited) would leave the model's
  # stats page looking empty even though traffic hit the gateway.
  defp log_and_render_gate_error(conn, member, model, error, opts) do
    {client_status, _type, code, _message} = error_details(error)

    # Igual que `log_and_render_proxy_error/5`: la respuesta primero.
    conn = render_proxy_error(conn, error)

    enqueue_gate_error_log(member, model, conn.assigns.agent_type,
      client_status: client_status,
      error_reason: Keyword.get(opts, :error_reason, code),
      latency_ms: Keyword.get(opts, :latency_ms, 0),
      streaming: conn.body_params["stream"] == true,
      client_agent: conn.assigns.client_agent
    )

    conn
  end

  # Resolves the model id by name for gate-error logs. Alias names are
  # globally unique. The gate path is cold (the request already failed), so a
  # single indexed lookup is acceptable; a miss (model_not_found) returns nil.
  defp model_id_for_name(nil), do: nil

  defp model_id_for_name(name) when is_binary(name) do
    Tokengate.Repo.one(
      from ma in Tokengate.Providers.Model,
        where: ma.name == ^name,
        select: ma.id
    )
  end

  defp enqueue_error_log(conn, route, member, opts) do
    subject = log_subject(member)

    %{
      "group_member_id" => subject.group_member_id,
      "user_id" => member.user_id,
      "service_id" => subject.service_id,
      "subject_type" => subject.subject_type,
      "provider_id" => route.model_provider.credential.provider_id,
      "model_provider_id" => route.model_provider.id,
      "model_id" => route.model.id,
      "model_requested" => route.model.name,
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
      "api_key_id" => member.api_key && member.api_key.id,
      "session_id" => conn.assigns[:session_key],
      "credential_name" => route.credential.name,
      "credential_id" => route.credential.id,
      "provider_key_prefix" => provider_key_prefix(route.credential),
      # Idempotencia (C2): fijado UNA vez en enqueue — cada reintento de Oban
      # lleva la MISMA pareja (oban_job_id, inserted_at) y cae en la MISMA
      # partición. Sin esto, log_request regeneraría el timestamp por intento.
      "inserted_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
    |> WriteWorker.new()
    |> Oban.insert()
  end

  defp enqueue_gate_error_log(member, model, agent_type, opts) do
    subject = log_subject(member)

    %{
      "group_member_id" => subject.group_member_id,
      "user_id" => member.user_id,
      "service_id" => subject.service_id,
      "subject_type" => subject.subject_type,
      "model_id" => model_id_for_name(model),
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
      "api_key_id" => member.api_key && member.api_key.id,
      "credential_name" => nil,
      "provider_key_prefix" => nil,
      # Idempotencia (C2): fijado UNA vez en enqueue — cada reintento de Oban
      # lleva la MISMA pareja (oban_job_id, inserted_at) y cae en la MISMA
      # partición. Sin esto, log_request regeneraría el timestamp por intento.
      "inserted_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
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
  defp log_fallback_attempt(conn, route, member, status, error_message) do
    error_reason =
      case status do
        400 -> "provider_bad_request"
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
    # Un adapter que devuelva una razón fuera del vocabulario (una tupla, un
    # mapa) no debe tumbar la request: se serializa, no se crashea.
    if is_atom(code), do: to_string(code), else: inspect(code)
  end

  defp elapsed(start_ms), do: System.monotonic_time(:millisecond) - start_ms

  ## Errors ######################################################################

  defp breaker_reason(:timeout), do: :timeout
  defp breaker_reason(:rate_limited), do: :rate_limited
  defp breaker_reason(:auth_error), do: :auth_error
  defp breaker_reason(:connection_error), do: :server_error
  defp breaker_reason(:server_error), do: :server_error
  # The streaming path records through this function. Without these two clauses
  # a 4xx would fall into the catch-all and be counted as :server_error, burning
  # the breaker on a healthy credential. Both map to themselves, which the
  # breaker ignores (see CircuitBreaker.@counting_reasons).
  defp breaker_reason(:bad_request), do: :bad_request
  defp breaker_reason(:client_error), do: :client_error
  defp breaker_reason(_), do: :server_error

  defp render_proxy_error(conn, error, upstream_message \\ nil) do
    {status, type, code, message} = error_details(error)

    # El detalle del upstream se ANEXA al mensaje genérico (el prefijo se
    # conserva: un cliente que matchea "Provider rejected the request (400)"
    # sigue funcionando) porque el texto del vendor nombra el campo culpable
    # y sin él el 400 es indiagnosticable desde el lado del cliente.
    message =
      case upstream_message do
        detail when is_binary(detail) and detail != "" -> message <> ": " <> detail
        _ -> message
      end

    body = %{"error" => %{"message" => message, "type" => type, "code" => code}}

    conn =
      conn
      |> put_resp_content_type("application/json")

    # Standard Retry-After (seconds, rounded up) on rate-limit responses so
    # well-behaved clients and SDKs back off instead of hammering.
    conn =
      case {status, error} do
        {429, {:rate_limited, retry_ms}} ->
          put_resp_header(conn, "retry-after", Integer.to_string(div(retry_ms, 1000) + 1))

        {429, {:provider_rate_limited, retry_ms}} ->
          put_resp_header(conn, "retry-after", Integer.to_string(div(retry_ms, 1000) + 1))

        _ ->
          conn
      end

    send_resp(conn, status, Jason.encode!(body))
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

  # Routing cascade exhausted: every candidate credential was excluded (or
  # the attempt cap hit). The reason is threaded from the last rejection so
  # the client sees WHY the cascade died instead of a generic concurrency
  # blame: saturation keeps the historical 429 provider_concurrency_exceeded
  # code (API compatibility), rate-limit keeps provider_rate_limited.
  defp error_details({:cascade_exhausted, :provider_concurrency_exceeded}),
    do:
      {429, "rate_limit_error", "provider_concurrency_exceeded",
       "All provider candidates are saturated (too many concurrent requests to provider)"}

  defp error_details({:cascade_exhausted, :provider_rate_limited}),
    do:
      {429, "rate_limit_error", "provider_rate_limited",
       "All provider candidates are rate limited; retry later"}

  defp error_details({:cascade_exhausted, _other}),
    do: {503, "service_unavailable", "cascade_exhausted", "All provider candidates were rejected"}

  defp error_details({:budget_exceeded, %{layer: :global}}),
    do: {402, "billing_error", "budget_exceeded", "Global daily spending cap reached"}

  defp error_details({:budget_exceeded, %{layer: :subject}}),
    do: {402, "billing_error", "budget_exceeded", "Monthly spend limit exceeded"}

  # «Sin crédito»: no hay límite mensual (ni propio ni del perfil de límites), no está
  # marcado ilimitado y no hay top-ups vigentes. Copy propio — NO comparte el
  # mensaje del tope global ni el del límite agotado.
  defp error_details({:budget_exceeded, %{layer: :no_credit}}),
    do:
      {402, "billing_error", "no_credit",
       "No spending path: no monthly limit, not marked unlimited and no active top-ups"}

  defp error_details({:budget_exceeded, _}),
    do: {402, "billing_error", "budget_exceeded", "Budget exceeded"}

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
    do: {upstream_status(status), "api_error", safe_reason(reason), "Upstream provider error"}

  defp error_details(other), do: {500, "api_error", "internal_error", inspect(other)}

  defp upstream_status(status) when is_integer(status) and status in 400..599, do: status
  defp upstream_status(_), do: 502

  # Las cuatro llamadas de error que serializan la razón (`error_reason:`,
  # `error_details/1`) deben tolerar un adapter que se salga del vocabulario
  # de `failure_reason` — históricamente una tupla `{:task, "FAILED"}` del
  # polling de vídeo crasheaba aquí con Protocol.UndefinedError y la request
  # moría en un 500 interno. Los átomos se serializan igual que siempre; lo
  # demás se inspecciona.
  defp safe_reason(reason) when is_atom(reason), do: to_string(reason)
  defp safe_reason(reason) when is_binary(reason), do: reason
  defp safe_reason(reason), do: inspect(reason)
end
