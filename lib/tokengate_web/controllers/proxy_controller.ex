defmodule TokengateWeb.ProxyController do
  @moduledoc """
  OpenAI-compatible proxy API.

    * `GET /v1/models` — only the models the API key can access
      (group grants + individual extras), each with its `context_window`.
    * `POST /v1/chat/completions` — transparent passthrough to the routed
      provider with full cost tracking. The response `usage` object gains
      `cost_usd` (the provider's own cost, USD) and the `X-Tokengate-Cost`
      header carries the same amount. There is a single cost dimension: the
      market-price fields (`estimated_cost_usd`) and the savings header were
      removed with `market_*`.
    * `POST /v1/embeddings` — embeddings passthrough. Non-streaming only.
      The request is forwarded as received and the upstream response is
      returned untouched; TokenGate only adds auth and cost tracking.
    * `POST /v1/rerank`, `/v1/audio/transcriptions`, `/v1/audio/speech`,
      `/v1/images/generations`, `/v1/videos`, `/v1/music/generations` — the
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

  # Política de 400 (ver `next_candidate/4`): antes de descartar la credencial
  # se reemite el MISMO body a la MISMA key — un reintento inmediato y, si
  # también falla, otro tras esta pausa. Agotados los dos, la credencial se
  # excluye y el cascade sigue con la siguiente key. En ningún caso cuenta como
  # fallo del breaker ni desactiva la key.
  @max_bad_request_retries 2
  @bad_request_retry_delay_ms 3_000

  # Cap on the per-credential rate-limit backoff inside the routing cascade,
  # so a provider demanding a long retry window can't stall the request:
  # the cascade moves on to the next credential after at most this long.
  @max_route_backoff_ms 2_000

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
  # Six capabilities that only differ in the upstream path, so they all run
  # through `service_passthrough/2` — the embeddings pipeline with the
  # service (not the endpoint) as the argument. The service key is the
  # `ProviderPaths` vocabulary and is the SAME one the Capacidades modal
  # writes, so an operator override lands on the wire without a redeploy.

  @doc "Reranks documents against a query at the provider's rerank service."
  def rerank(conn, _params), do: service_passthrough(conn, :rerank)

  @doc "Audio → text (transcription) at the provider's speech-to-text service."
  def transcriptions(conn, _params), do: service_passthrough(conn, :stt)

  @doc "Text → audio (speech synthesis) at the provider's text-to-speech service."
  def speech(conn, _params), do: service_passthrough(conn, :tts)

  @doc "Image generation at the provider's images service."
  def image_generations(conn, _params), do: service_passthrough(conn, :image)

  @doc "Video generation at the provider's videos service."
  def video_generations(conn, _params), do: service_passthrough(conn, :video)

  @doc "Music generation at the provider's music service."
  def music_generations(conn, _params), do: service_passthrough(conn, :music)

  # Shared entry point for the six non-chat services: same gates, routing,
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
  # and the six path-routed services): same two-gate throttle, routing,
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
          # (`next_candidate/4`) reemits the body to the SAME credential twice
          # (the second attempt after @bad_request_retry_delay_ms) and only then
          # falls back to the next candidate. Either way the rejection is a
          # NON-counting failure: the credential is NOT deactivated, stays in
          # the pool, and the breaker does NOT count it.
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
          # 4xx other than 400 (404, 422, …): the caller's payload is at fault and
          # — unlike a 400 — the rejection is not provider-specific. Surface it
          # without burning the breaker or trying other providers.
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
              error_reason: safe_reason(reason),
              error_message: error_message
            )
          end
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
    maybe_wait_before_retry(reason, provider_retries)

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

      {:error, :no_available_provider} when reason == :bad_request ->
        # Every remaining candidate rejected the body with a 400. That is not a
        # provider outage, so the client gets the upstream 4xx it can act on
        # instead of a 503.
        log_and_render_proxy_error(conn, route, member, {:upstream_client_error, status},
          error_reason: "bad_request",
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

    enqueue_log(route, member, conn.assigns.agent_type, usage, cost, latency_ms, 200, false,
      client_agent: conn.assigns.client_agent,
      session_id: conn.assigns[:session_key],
      request_type: to_string(kind)
    )

    conn
    |> put_resp_header("x-tokengate-cost", Decimal.to_string(cost, :normal))
    |> send_service_response(body)
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

  # The six path-routed services. Their response shapes have almost nothing
  # in common — rerank reports tokens, image generation reports the same
  # counters under other names, and tts/stt/video/music report none at all
  # (audio bytes, a transcript, a job id) — so the rule is:
  #
  #   1. what the upstream reported wins (chat names, then the image API's);
  #   2. otherwise the request's own text is estimated, so manual pricing
  #      still books something proportional (the same honest estimate the
  #      embeddings path has always used);
  #   3. no text at all estimates to zero, and zero is `CostCalculator`'s
  #      explicit $0 — we never invent a cost.
  defp simple_usage(payload, body, kind)
       when kind in [:rerank, :stt, :tts, :image, :video, :music] do
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
  # stt's JSON variant), `prompt` (image/video/music) and `query` (rerank).
  @estimated_text_fields ~w(input prompt query)

  defp estimated_prompt_tokens(payload) do
    Enum.reduce(@estimated_text_fields, 0, fn field, acc ->
      acc + estimate_strings(payload[field])
    end)
  end

  # A field may be a bare string or a list of strings (embeddings inputs,
  # rerank documents); anything else — multimodal blocks, objects — is not
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
  #     So the same credential gets up to @max_bad_request_retries attempts —
  #     one immediate, the next after @bad_request_retry_delay_ms — before it is
  #     excluded and the cascade moves to the next key. The rejection says
  #     nothing about credential health: it is never counted as a failure (no
  #     breaker penalty, no deactivation), so the key stays in the pool for
  #     every other request.
  #   * any other reason — fast failures (5xx, 429, connection refused) are
  #     often transient and cost almost nothing to retry, so the same
  #     provider gets up to @max_retries_per_provider attempts before being
  #     excluded.
  defp next_candidate(route, exclude, _provider_retries, :timeout) do
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

  # Pausa antes de reemitir el body a la MISMA credencial. `provider_retries`
  # llega YA incrementado por `next_candidate/4`: el primer reintento de un 400
  # sale inmediato (es el barato y el que más acierta) y a partir del segundo se
  # respeta @bad_request_retry_delay_ms, para no martillar a un upstream que
  # acaba de rechazar. Solo aplica a :bad_request — los demás motivos ya tienen
  # su timing (timeout: sin reintento; rate limit: el backoff del proveedor).
  defp maybe_wait_before_retry(:bad_request, provider_retries) when provider_retries >= 2 do
    Process.sleep(@bad_request_retry_delay_ms)
  end

  defp maybe_wait_before_retry(_reason, _provider_retries), do: :ok

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

        {:error, {:provider_rate_limited, retry_ms}} ->
          # Rate-limited on this credential: hold the retry to honor the
          # provider's window (bounded, so the @max_route_retries cap still
          # dominates worst-case latency), then re-route excluding it.
          backoff = min(retry_ms, @max_route_backoff_ms)

          if backoff > 0 do
            Process.sleep(backoff)
          end

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
  # lookup returns :miss to fall through to the upstream call; a hit renders
  # the cached body with cache headers and short-circuits execution.
  defp cache_lookup(_conn, nil), do: :miss

  defp cache_lookup(conn, key) do
    case ResponseCache.lookup(key) do
      {:ok, body_json, _age} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> put_resp_header("x-tokengate-cache", "hit")
        |> send_resp(200, body_json)

        # send_resp halts the conn — the with-chain treats any non-:miss as
        # "already handled".
        :handled

      :miss ->
        :miss
    end
  end

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
    # The client sends the model name; the provider expects its own model id.
    payload =
      payload
      |> Map.put("model", route.model_responded)
      |> inject_guard_rails(route.model)
      |> maybe_optimize(optimize_ctx(conn, route))

    # Gateway-local response cache (non-streaming chat only): identical
    # requests served from ETS. The cache key uses the PRE-transform payload
    # so retried/fallback attempts hash consistently.
    cache_key = ResponseCache.cache_key(conn.assigns.api_key_hash, route.model_responded, payload)

    with :miss <- cache_lookup(conn, cache_key) do
      receive_timeout = receive_timeout(route.credential)

      case OpenAIAdapter.chat_completion(provider, route.credential, payload,
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
          # (`next_candidate/4`) reemits the body to the SAME credential twice
          # (the second attempt after @bad_request_retry_delay_ms) and only then
          # falls back to the next candidate. Either way the rejection is a
          # NON-counting failure: the credential is NOT deactivated, stays in
          # the pool, and the breaker does NOT count it.
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
          # 4xx other than 400 (404, 422, …): the caller's payload is at fault and
          # — unlike a 400 — the rejection is not provider-specific. Surface it
          # without burning the breaker or trying other providers.
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
              error_reason: safe_reason(reason),
              error_message: error_message
            )
          end
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
    maybe_wait_before_retry(reason, provider_retries)

    request_context = %{
      "messages" => payload["messages"] || [],
      :api_key_hash => conn.assigns.api_key_hash,
      :exclude_credential_ids => exclude
    }

    case Router.route(route.model.name, member, request_context) do
      {:ok, new_route} ->
        execute(conn, new_route, payload, member, attempts_left - 1, exclude, provider_retries)

      {:error, :no_available_provider} when reason == :bad_request ->
        # Every remaining candidate rejected the body with a 400. That is not a
        # provider outage, so the client gets the upstream 4xx it can act on
        # instead of a 503.
        log_and_render_proxy_error(conn, route, member, {:upstream_client_error, status},
          error_reason: "bad_request",
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
    # The client sends the model name; the provider expects its own model id.
    payload =
      payload
      |> Map.put("model", route.model_responded)
      |> ensure_stream_options()
      |> inject_guard_rails(route.model)
      |> maybe_optimize(optimize_ctx(conn, route))

    # Measured just before the upstream call: TTFT is the time from this
    # point to the provider's first chunk.
    request_start = System.monotonic_time(:millisecond)
    receive_timeout = receive_timeout(route.credential)

    case OpenAIAdapter.stream_chat_completion(provider, route.credential, payload,
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

            stream_loop(conn, pid, ref, first_chunk, route, member, payload, %{
              usage: nil,
              # Completion deltas accumulate as iodata (a reversed list of
              # binaries) — O(1) per chunk instead of O(n) binary append.
              # Materialized once in finish_stream when the provider omits
              # usage (token-estimator fallback).
              completion: [],
              prompt_estimate: TokenEstimator.estimate_messages(payload["messages"] || []),
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
              # credential twice (second attempt after
              # @bad_request_retry_delay_ms) and only then moves to the next
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

              # Any other non-auth 4xx (404, 422, …) is the client's payload at
              # fault: the same body fails identically on every provider, so
              # retrying and falling back is pointless. Surface it (mirroring
              # the non-streaming path) and keep the provider's message —
              # instead of masking it as a retryable `provider_error_<status>`.
              # A 400 landing here had no candidate left to fall back to, so it
              # is surfaced the same way.
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
    maybe_wait_before_retry(reason, provider_retries)

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

      {:error, :no_available_provider} when reason == :bad_request ->
        # Every remaining candidate rejected the body with a 400. That is not a
        # provider outage, so the client gets the upstream 4xx it can act on
        # instead of a 503.
        log_and_render_proxy_error(conn, route, member, {:upstream_client_error, status},
          error_reason: "bad_request",
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
    |> rename_body_fields(provider_key(route_ctx))
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

  # Remaps client-supplied body keys to the name the upstream expects
  # (`Catalog.rename_body_fields/1`). The VALUE is adapted, not just moved:
  # an OpenRouter-style nested reasoning object (`%{"effort" => "high"}` or
  # `%{"enabled" => false}`) flattens to the scalar Fireworks-style knobs
  # expect. A rename whose target key already exists is skipped — the field
  # the client sent explicitly wins over a remapped one. Protected keys are
  # never a valid rename target (the gateway owns them).
  defp rename_body_fields(payload, provider_key) do
    renames = Tokengate.Providers.Catalog.rename_body_fields(provider_key)

    Enum.reduce(renames, payload, fn {from, to}, acc ->
      cond do
        to in @protected_body_keys or not Map.has_key?(acc, from) -> acc
        # The explicit target field wins, but the source key is still
        # consumed: leaving it in the body would recreate the strict-upstream
        # 400 the rename exists to prevent.
        Map.has_key?(acc, to) -> Map.delete(acc, from)
        true -> move_renamed_field(acc, from, to)
      end
    end)
  end

  defp move_renamed_field(payload, from, to) do
    case rename_value(Map.get(payload, from)) do
      # nil = "adapt away": the source field is dropped and nothing replaces
      # it, so the upstream applies its own default (e.g. reasoning enabled
      # without an explicit effort level).
      nil -> Map.delete(payload, from)
      value -> payload |> Map.put(to, value) |> Map.delete(from)
    end
  end

  # OpenRouter-style nested objects flatten to the scalar the target knob
  # expects; a scalar travels untouched. A nested object that matches NO
  # known shape is dropped (nil): the target knob expects a scalar, and
  # forwarding the object would recreate the 400 the rename exists to fix.
  defp rename_value(%{"effort" => effort}) when is_binary(effort) and effort != "", do: effort
  defp rename_value(%{"enabled" => false}), do: "none"
  defp rename_value(%{"enabled" => true}), do: nil
  defp rename_value(other) when is_map(other), do: nil
  defp rename_value(other), do: other

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
      session_id: conn.assigns[:session_key],
      client_agent: conn.assigns.client_agent
    )

    conn
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

    # Durable log + webhooks, async via Oban
    enqueue_log(route, member, conn.assigns.agent_type, usage, cost, latency_ms, 200, false,
      think: conn.assigns[:think] || false,
      effort: conn.assigns[:effort],
      session_id: conn.assigns[:session_key],
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
      "api_key_prefix" => member.api_key && member.api_key.key_prefix,
      "api_key_id" => member.api_key && member.api_key.id,
      "session_id" => Keyword.get(extra, :session_id),
      "credential_name" => route.credential.name,
      "credential_id" => route.credential.id,
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

    # El texto del vendor (ya scrubbeado y truncado por el adapter) es la
    # ÚNICA pista accionable de un rechazo upstream. Sin pasarlo a las dos
    # salidas — la fila de `request_logs.error_message` y el body del
    # cliente — el diagnóstico queda en "Provider rejected the request (400)"
    # y no hay forma de saber QUÉ campo rechazó el upstream.
    upstream_message = Keyword.get(opts, :error_message)

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

    render_proxy_error(conn, error, upstream_message)
  end

  # Gate-level errors (before routing succeeded): no provider was contacted,
  # so there is no provider status to record. Still logs the failure — and
  # resolves the model id so these rows show up in the per-model stats
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
      "provider_key_prefix" => provider_key_prefix(route.credential)
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
