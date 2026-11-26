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

  require Logger

  alias Tokengate.Budgets.Manager, as: Budgets
  alias Tokengate.Accounts
  alias Tokengate.Accounts.GroupMember
  alias Tokengate.Limits.Manager, as: Limits
  alias Tokengate.Logs.WriteWorker
  alias Tokengate.Metrics.Collector
  alias Tokengate.Providers
  alias Tokengate.Providers.{Credential, Provider, ProviderLimits}
  alias Tokengate.SmartRouter
  alias Tokengate.SmartRouter.ShadowEvaluator

  alias Tokengate.Proxy.{
    AudioMultipart,
    CostCalculator,
    DecisionsTranslator,
    ProviderAdapter,
    PromptOptimizer,
    RawResponse,
    ResponseCache,
    ServiceUsage,
    SessionId,
    TokenEstimator,
    UsageNormalizer
  }

  alias Tokengate.Routing.{CircuitBreakerManager, Router}
  alias TokengateWeb.Plugs.MediaBodyParser

  @max_attempts 9
  @max_retries_per_provider 1

  # The `response_format` enum of the TTS surface — identical in OpenAI's audio
  # docs and in the OpenAPI of the openai-dialect media cluster (Helmcode/NaN).
  @tts_response_formats ~w(mp3 wav flac aac pcm opus)

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
    Process.delete(:tg_acquired_credential)
    Process.delete(:tg_active_probe)
    Process.delete(:tg_deferred_fallback_logs)
    Process.delete(:tg_upstream_retry_after_ms)
    Process.delete(:tg_inflight_id)
    Process.delete(:tg_router)
    Process.delete(:tg_router_decision_logged)
    Process.delete(:tg_router_raw_payload)

    with :ok <- require_model(model),
         :ok <- acquire_group_limits(key_id, limits) do
      try do
        if model == "router" do
          execute_router_chat(conn, member, payload, limits, request_start)
        else
          case route_and_acquire(member, payload, affinity_key, limits) do
            {:ok, route, hold} ->
              inflight = register_inflight(conn, member, payload, route)
              Process.put(:tg_inflight_id, inflight.id)

              try do
                if payload["stream"] == true do
                  execute_stream(conn, route, payload, member, @max_attempts, [])
                else
                  execute(conn, route, payload, member, @max_attempts, [])
                end
              after
                settle_budget(member, hold)
                Tokengate.Logs.Inflight.finish_request(inflight.id)
                release_active_probe()
                release_active_credential_limits()
                flush_deferred_fallback_logs(conn, member)
                Process.delete(:tg_inflight_id)
              end

            {:error, error} ->
              log_and_render_gate_error(conn, member, model, error,
                latency_ms: elapsed(request_start)
              )
          end
        end
      after
        Limits.release(key_id)
      end
    else
      {:error, error} ->
        log_and_render_gate_error(conn, member, model, error, latency_ms: elapsed(request_start))
    end
  end

  ## SmartRouter chat path #####################################################
  #
  # `"model": "router"` is a reserved alias, not a `models` row: the decision
  # engine resolves it to a concrete model and every step below reuses the
  # ordinary chat pipeline (streaming, ResponseCache, fallback matrix, cost
  # accounting). The only thing the router adds is WHERE the route comes from.

  @router_alias "router"
  # Cascade cap for the router's destination walk (same bound the direct
  # route/acquire loop uses).
  @max_route_retries 20
  # Chat is served by `llm` models; `decision` stays accepted exactly like the
  # direct path (`route_and_acquire/5` passes both).
  @router_capabilities ["llm", "decision"]

  # Gates + budget first, decision second, route third. The budget hold is
  # taken BEFORE the classifier runs: paying a classifier for a subject that
  # cannot spend is pure loss, and the hold is settled (or released) by the
  # same `settle_budget/2` every other request uses.
  defp execute_router_chat(conn, member, payload, limits, request_start) do
    with :ok <- router_gate(),
         :ok <- router_access_gate(member) do
      case reserve_credit_budget(member, limits) do
        {:ok, hold} ->
          case prepare_router_route(conn, member, payload) do
            {:ok, route} ->
              conn = assign_router(conn, Process.get(:tg_router))
              inflight = register_inflight(conn, member, payload, route)
              Process.put(:tg_inflight_id, inflight.id)

              try do
                if payload["stream"] == true do
                  execute_stream(conn, route, payload, member, @max_attempts, [])
                else
                  execute(conn, route, payload, member, @max_attempts, [])
                end
              after
                close_router_request(conn, member, hold, inflight)
              end

            {:error, error} ->
              close_router_request(conn, member, hold, nil)

              log_and_render_gate_error(conn, member, @router_alias, error,
                latency_ms: elapsed(request_start)
              )
          end

        {:error, error} ->
          log_and_render_gate_error(conn, member, @router_alias, error,
            latency_ms: elapsed(request_start)
          )
      end
    else
      {:error, error} ->
        log_and_render_gate_error(conn, member, @router_alias, error,
          latency_ms: elapsed(request_start)
        )
    end
  end

  # Exactly-once teardown for a router request, whatever the outcome: the
  # classifier's own row (when it is charged to the subject), the budget hold,
  # the in-flight entry, the probe lease, the credential slot, the deferred
  # fallback rows and the per-request process state.
  defp close_router_request(conn, member, hold, inflight) do
    record_router_decision_cost(conn, member)
    settle_budget(member, hold)

    if inflight, do: Tokengate.Logs.Inflight.finish_request(inflight.id)

    release_active_probe()
    release_active_credential_limits()
    flush_deferred_fallback_logs(conn, member)

    Process.delete(:tg_inflight_id)
    Process.delete(:tg_router)
    Process.delete(:tg_router_decision_logged)
    Process.delete(:tg_prompt_tokens_saved)
    Process.delete(:tg_router_raw_payload)
  end

  # A disabled router is a 503 even for a subject that opted in: the kill
  # switch must not depend on per-subject state.
  defp router_gate do
    if SmartRouter.enabled?(), do: :ok, else: {:error, :router_disabled}
  end

  # Discovery and authorization are the same predicate: `/v1/models` only
  # advertises the alias to subjects this gate would let through.
  defp router_access_gate(member) do
    if Accounts.router_enabled?(member), do: :ok, else: {:error, :router_access_disabled}
  end

  defp prepare_router_route(conn, member, payload) do
    context = router_decision_context(conn, member)

    case SmartRouter.decide(payload, context) do
      {:ok, decision} ->
        ctx = decision |> router_state() |> Map.put(:context, context)
        Process.put(:tg_router, ctx)

        case acquire_router_route(ctx, member, payload, conn, 0, 0) do
          {:ok, route, ctx} ->
            Process.put(:tg_router, ctx)
            {:ok, route}

          {:error, error} ->
            {:error, error}
        end

      {:error, reason} ->
        {:error, router_decision_error(reason)}
    end
  end

  # The decision context: who is asking, in which conversation, on which
  # surface. `subject_id` is the SPEND subject (the user behind the member, or
  # the virtual service member), so a pin follows the person across keys.
  defp router_decision_context(conn, member) do
    %{
      subject_id: router_subject_id(member),
      # The USER behind the member (nil for a service member): the spend
      # subject is what a session/user rule must match, and the deterministic
      # `user_ids` rule reads it from HERE, so the proxy — not the rule
      # evaluator — decides who the caller is.
      user_id: member.user_id,
      group_id: member.group_id,
      service_id: router_service_id(member),
      session_id: session_id_header(conn) || conn.assigns[:session_key],
      agent_type: conn.assigns[:agent_type]
    }
  end

  defp router_subject_id(%GroupMember{user_id: nil} = member), do: member.id
  defp router_subject_id(%GroupMember{user_id: user_id}), do: user_id
  defp router_subject_id(_), do: nil

  defp router_service_id(%GroupMember{user_id: nil} = member), do: member.id
  defp router_service_id(_), do: nil

  # The cascade cursor: the decision's chain is walked forward, one model at a
  # time, with a per-model exclusion list — a credential that failed (or is
  # saturated) is skipped for THAT model without pinning a healthy key out of
  # an unrelated fallback destination.
  defp router_state(decision) do
    chain = [decision.primary | Enum.reject(decision.fallbacks, &is_nil/1)]
    config = router_config()

    %{
      decision: decision,
      chain: chain,
      position: 0,
      # Which configuration version decided: `request_logs.router_config_id`
      # and the shadow comparison both read it from the decision itself.
      config_id: Map.get(decision.decision_meta, :config_id),
      exclude: %{},
      effort_overrides: router_effort_overrides(chain),
      decision_lane_cost: router_decision_lane_cost(decision.decision_meta),
      charge_decision?: Map.get(config, :charge_decision_to_subject) == true,
      last_reject: nil,
      last_reason: nil
    }
  end

  defp router_config do
    case router_snapshot() do
      %{config: %{} = config} -> config
      _ -> %{}
    end
  end

  defp router_snapshot do
    SmartRouter.snapshot()
  rescue
    _ -> %{}
  end

  # `effort_override` belongs to the use-case BINDING, not to the shared model
  # row: resolve it once per destination so `optimize_ctx/2` can prefer it.
  defp router_effort_overrides(chain) do
    Enum.reduce(chain, %{}, fn entry, acc ->
      with binding_id when is_binary(binding_id) <- Map.get(entry, :use_case_model_id),
           override when is_binary(override) <- SmartRouter.effort_override(binding_id) do
        Map.put(acc, entry.model_id, override)
      else
        _ -> acc
      end
    end)
  end

  # The classifier's own price, from the usage the engine returned and the
  # decision model's global lane. `nil` when it cannot be priced honestly (no
  # usage, no lane, no rates) — a decision cost is never invented either.
  #
  # Only a REAL Layer-2 call has a cost to book. A `DecisionCache` hit re-uses
  # an answer whose `usage` belongs to the request that populated the cache —
  # charging it again would bill the same classifier tokens once per cache hit;
  # a deterministic layer (`rules`, `session_pin`, `fast_path`, tier
  # substitution) never called a model at all. Both leave the cost `nil`, which
  # also means no `router_decision` row and no debit.
  defp router_decision_lane_cost(meta) do
    usage = Map.get(meta, :usage)
    model_id = Map.get(meta, :model_id)

    with true <- Map.get(meta, :classifier) == true,
         true <- Map.get(meta, :cache_hit) != true,
         true <- is_map(usage),
         model_id when is_binary(model_id) <- model_id,
         {:ok, lane} <- SmartRouter.resolve_decision_lane(model_id) do
      prompt = Map.get(usage, "prompt_tokens") || Map.get(usage, "input_tokens") || 0
      completion = Map.get(usage, "completion_tokens") || Map.get(usage, "output_tokens") || 0
      mp = lane.model_provider

      cost =
        CostCalculator.provider_cost(nil,
          manual_pricing: %{
            input_cost_per_million: mp.input_cost_per_million,
            output_cost_per_million: mp.output_cost_per_million,
            cache_cost_per_million: mp.cache_cost_per_million,
            cache_write_cost_per_million: mp.cache_write_cost_per_million
          },
          usage: %{prompt_tokens: prompt, completion_tokens: completion},
          pricing_unit: mp.pricing_unit
        )

      if Decimal.compare(cost, @zero_cost) == :gt do
        %{
          cost: cost,
          model_id: model_id,
          model_name: router_model_name(model_id),
          provider_id: lane.credential.provider_id,
          credential_id: lane.credential.id,
          credential_name: lane.credential.name,
          prompt_tokens: prompt,
          completion_tokens: completion
        }
      end
    else
      _ -> nil
    end
  end

  defp router_model_name(model_id) do
    case Map.get(router_snapshot(), :decision_model) do
      %{id: ^model_id, name: name} -> name
      _ -> nil
    end
  end

  defp router_decision_error(:router_disabled), do: :router_disabled

  defp router_decision_error(reason) do
    Logger.warning("smart router decision failed: #{inspect(reason)}")
    :router_no_candidates
  end

  # Walks the decision's chain from `position`, trying every visible lane of
  # each destination. Model-level failures (`:no_available_provider`, a
  # credential gate) advance the position; a credential refused by the
  # provider gate is excluded and the SAME destination is retried.
  defp acquire_router_route(_ctx, _member, _payload, _conn, _position, attempt)
       when attempt >= @max_route_retries do
    {:error, {:cascade_exhausted, :provider_concurrency_exceeded}}
  end

  defp acquire_router_route(ctx, member, payload, conn, position, attempt) do
    case Enum.at(ctx.chain, position) do
      nil ->
        {:error, router_chain_error(ctx)}

      entry ->
        exclude = Map.get(ctx.exclude, entry.model_id, [])
        request_context = router_request_context(conn, payload, exclude)

        case Router.route_by_model_id(entry.model_id, member, request_context) do
          {:ok, route} ->
            key_id = member.api_key.id

            case acquire_credential_limits(route.credential, key_id) do
              :ok ->
                Process.put(:tg_acquired_credential, {route.credential, key_id})
                {:ok, route, %{ctx | position: position, last_reject: nil}}

              {:error, reject} ->
                ctx = %{
                  ctx
                  | exclude:
                      Map.put(ctx.exclude, entry.model_id, [route.credential.id | exclude]),
                    last_reject: router_reject(reject)
                }

                acquire_router_route(ctx, member, payload, conn, position, attempt + 1)
            end

          {:error, reason} ->
            ctx = %{ctx | position: position + 1, last_reject: router_reject(reason)}
            acquire_router_route(ctx, member, payload, conn, position + 1, attempt + 1)
        end
    end
  end

  defp router_request_context(conn, payload, exclude) do
    %{
      "messages" => payload["messages"] || [],
      :api_key_hash => conn.assigns[:affinity_key] || conn.assigns.api_key_hash,
      :exclude_credential_ids => exclude,
      :capability => @router_capabilities
    }
  end

  defp router_reject({:provider_rate_limited, _retry_ms}), do: :provider_rate_limited
  defp router_reject(:provider_user_concurrency_exceeded), do: :provider_concurrency_exceeded
  defp router_reject(reject), do: reject

  # Every destination failed. A saturation/rate-limit refusal keeps its honest
  # 429; anything else means the router had no servable destination at all.
  defp router_chain_error(%{last_reject: reject})
       when reject in [:provider_concurrency_exceeded, :provider_rate_limited] do
    {:cascade_exhausted, reject}
  end

  defp router_chain_error(_ctx), do: :router_no_candidates

  # Router-side replacement of `route_and_acquire_fallback/8`: the current
  # credential is excluded for ITS model, then the chain is walked from the
  # current position — the same destination first (another lane), then the next
  # `decision.fallbacks` entry (potent alternative -> use-case fallback ->
  # global default). The serving model, the in-flight row and the session pin
  # follow the hop.
  #
  # `reason` is the failure that triggered the hop (`:timeout`, `:server_error`,
  # …). It is kept on the context so `router_decision_source_for/2` can say
  # `"fallback_timeout"` instead of a generic `"fallback_error"` — the
  # classification is the caller's, not something this function could infer.
  defp advance_router_route(conn, route, payload, member, ctx, reason) do
    release_active_credential_limits()

    model_id = route.model.id
    exclude = [route.credential.id | Map.get(ctx.exclude, model_id, [])]
    ctx = %{ctx | exclude: Map.put(ctx.exclude, model_id, exclude)}

    case acquire_router_route(ctx, member, payload, conn, ctx.position, 0) do
      {:ok, new_route, ctx} ->
        ctx = %{ctx | last_reason: reason || ctx.last_reject}
        Process.put(:tg_router, ctx)
        update_inflight_route(conn, member, payload, new_route)
        maybe_repin_session(conn, ctx, route, new_route)

        {:ok, new_route, Map.get(ctx.exclude, new_route.model.id, []), 0}

      {:error, error} ->
        {:error, error}
    end
  end

  # Leaving the pinned model is exactly what the pin exists to prevent — but a
  # dead destination must not sentence every later turn to a failed attempt:
  # when the cascade hops, the pin follows the NEW model, keeping the use case
  # and the conversation's requirements.
  defp maybe_repin_session(conn, ctx, old_route, new_route) do
    session_key = conn.assigns[:session_key]
    member = conn.assigns.current_group_member
    subject_id = router_subject_id(member)
    entry = router_entry_for(ctx, new_route.model.id)
    ttl_ms = router_sticky_ttl_ms()

    with true <- new_route.model.id != old_route.model.id,
         true <- Map.get(ctx.decision.use_case, :pin_session) == true,
         true <- is_binary(session_key) and is_binary(subject_id) and ttl_ms > 0,
         %{} = pin <- SmartRouter.SessionPin.get(subject_id, session_key) do
      SmartRouter.SessionPin.put(
        subject_id,
        session_key,
        %{
          use_case_id: Map.get(pin, :use_case_id) || ctx.decision.use_case.id,
          use_case_key: Map.get(pin, :use_case_key) || ctx.decision.use_case.key,
          use_case_model_id: entry && entry.use_case_model_id,
          model_id: new_route.model.id,
          model_name: new_route.model.name,
          effort_tier: entry && entry.effort_tier,
          requirements: Map.get(pin, :requirements, %{})
        },
        ttl_ms
      )
    end

    :ok
  end

  defp router_sticky_ttl_ms do
    case Map.get(router_config(), :sticky_ttl_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds * 1000
      _ -> 0
    end
  end

  defp router_entry_for(ctx, model_id) do
    Enum.find(ctx.chain, &(&1.model_id == model_id))
  end

  # The conn carries the router context for the whole request: the log
  # builders, the in-flight row and `optimize_ctx/2` all read it from here.
  defp assign_router(conn, nil), do: conn

  defp assign_router(conn, ctx) do
    conn
    |> assign(:router, ctx)
    |> assign(:router_prompt_policy, Map.get(ctx.decision, :prompt_policy))
    |> assign(:router_effort_overrides, ctx.effort_overrides)
    |> assign(:router_pinned, Map.get(ctx.decision.decision_meta, :pinned) == true)
  end

  defp router_effort_override(conn, route) do
    case conn.assigns[:router_effort_overrides] do
      %{} = overrides -> Map.get(overrides, route.model.id)
      _ -> nil
    end
  end

  # The body the CLIENT sent — before the `model` rewrite, the guard rails and
  # any prompt optimisation. A Shadow version must re-decide exactly what
  # arrived, not the gateway's rewrite of it (S4).
  #
  # It lives on the conn (a consumer of the request can see it) AND in the
  # request process (the log builders never carry the conn). Only routed
  # requests pay for the assign.
  defp capture_router_payload(conn, payload) do
    if Process.get(:tg_router) do
      Process.put(:tg_router_raw_payload, payload)
      assign(conn, :router_raw_payload, payload)
    else
      conn
    end
  end

  # The classifier paid for this request and the operator decided the subject
  # pays for it: book a SEPARATE `router_decision` row (so
  # `Budgets.SyncWorker`, which reconciles from `request_logs.provider_cost_usd`,
  # matches the debit exactly) and add the amount to the same hold settlement.
  defp record_router_decision_cost(conn, member) do
    with %{charge_decision?: true} = ctx <- Process.get(:tg_router),
         %{cost: %Decimal{} = cost} = lane_cost <- Map.get(ctx, :decision_lane_cost),
         false <- Process.get(:tg_router_decision_logged, false) do
      Process.put(:tg_router_decision_logged, true)
      enqueue_router_decision_log(conn, member, lane_cost)
      add_router_decision_cost(cost)
    else
      _ -> :ok
    end
  end

  defp add_router_decision_cost(cost) do
    total =
      case Process.get(:tg_budget_actual_cost) do
        %Decimal{} = actual -> Decimal.add(actual, cost)
        _ -> cost
      end

    Process.put(:tg_budget_actual_cost, total)
  end

  # The classifier's own row. It is a SEPARATE debit, not a routed request:
  # `routed_via_router` is false (this row was not routed BY the router — it IS
  # the router's own spend) and `router_decision_cost_usd` is nil (the column
  # lives on the request whose decision it paid for; leaving it here would add
  # the same amount to every SUM over the column). `session_id` is nil for the
  # same reason: the decision has no conversation of its own, and a session id
  # here made the switch counters read a phantom session change per request.
  # `credit_topup_id` names the SAME hold the served request debited, so
  # `Budgets.SyncWorker` reconciles both rows against one top-up.
  defp enqueue_router_decision_log(conn, member, lane_cost) do
    subject = log_subject(member)

    %{
      "group_member_id" => subject.group_member_id,
      "user_id" => member.user_id,
      "service_id" => subject.service_id,
      "subject_type" => subject.subject_type,
      "provider_id" => lane_cost.provider_id,
      "model_id" => lane_cost.model_id,
      "model_requested" => @router_alias,
      "model_resolved" => lane_cost.model_name,
      "agent_type" => conn.assigns[:agent_type],
      "client_agent" => conn.assigns[:client_agent],
      "status_code" => 200,
      "prompt_tokens" => lane_cost.prompt_tokens,
      "completion_tokens" => lane_cost.completion_tokens,
      "provider_cost_usd" => Decimal.to_string(lane_cost.cost, :normal),
      "latency_ms" => 0,
      "streaming" => false,
      # The row the durable reconciliation reads: the router's own spend,
      # separate from the served request it helped route.
      "request_type" => "router_decision",
      "routed_via_router" => false,
      "router_decision_source" => "classifier",
      "router_decision_cost_usd" => nil,
      "api_key_prefix" => member.api_key && member.api_key.key_prefix,
      "api_key_id" => member.api_key && member.api_key.id,
      "session_id" => nil,
      "credit_topup_id" => Process.get(:tg_credit_topup_id),
      "credential_name" => lane_cost.credential_name,
      "credential_id" => lane_cost.credential_id,
      "provider_key_prefix" => nil,
      "inserted_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
    |> WriteWorker.new()
    |> insert_log_job(%{
      model_id: lane_cost.model_id,
      provider_id: lane_cost.provider_id,
      status: 200,
      request_type: "router_decision"
    })
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

    with :ok <- reject_router_alias(payload["model"]),
         :ok <- validate_service_contract(service, payload) do
      simple_proxy(
        conn,
        payload,
        Atom.to_string(service),
        &adapter_service(&1, &2, &3, &4, service),
        service,
        on_route: &canonical_upload(&1, service, &2)
      )
    else
      {:error, error} -> render_proxy_error(conn, error)
    end
  end

  # Contract of the non-chat services that the gateway can decide WITHOUT a
  # provider round trip — verified against the OpenAPI of the openai-dialect
  # media cluster in the catalog (Helmcode/NaN, same platform) and against
  # OpenAI's own surface:
  #
  #   * tts: `voice` is required by the wire (omitting it earned a 400/422 after
  #     the request had already been routed, held and billed as an attempt), and
  #     `response_format` is the closed enum `mp3|wav|flac|aac|pcm|opus`.
  #   * image: `n` is a positive integer and `size` is `auto` or `WxH` with
  #     positive sides. The per-model RANGES (256–1536 for `flux-2-klein`,
  #     512–1280 for `qwen-image-2.1`, `n` ≤ 4) are deliberately NOT enforced
  #     here: they are lane knowledge that lives in the catalog (W14) and differ
  #     per model, and the same body is perfectly valid on another provider.
  #
  # Nothing is translated and nothing is invented: a value the wire documents as
  # unservable is refused with the gateway's own code and zero provider calls;
  # the rest travels verbatim and the upstream decides (F15/F26 stay local
  # rejections until a real key verifies them in W15).
  defp validate_service_contract(:tts, %{"model" => model} = payload) when is_binary(model) do
    with :ok <- require_tts_voice(payload),
         :ok <- validate_tts_format(payload["response_format"]) do
      :ok
    end
  end

  defp validate_service_contract(:image, %{"model" => model} = payload) when is_binary(model) do
    with :ok <- validate_image_count(payload["n"]),
         :ok <- validate_image_size(payload["size"]) do
      :ok
    end
  end

  # No model yet: `simple_proxy/6` owns that error (and its log row).
  defp validate_service_contract(_service, _payload), do: :ok

  defp require_tts_voice(%{"voice" => voice}) when is_binary(voice) do
    if String.trim(voice) == "" do
      {:error, {:missing_voice, missing_voice_message()}}
    else
      :ok
    end
  end

  defp require_tts_voice(_payload), do: {:error, {:missing_voice, missing_voice_message()}}

  defp missing_voice_message do
    "voice is required: name one of the provider's voice packs (the OpenAI voice " <>
      "names do not exist in every upstream — e.g. Kokoro serves af_heart/ef_dora)"
  end

  defp validate_tts_format(nil), do: :ok

  defp validate_tts_format(format) when format in @tts_response_formats, do: :ok

  defp validate_tts_format(format) do
    {:error,
     {:unsupported_response_format,
      "response_format \"#{format}\" is not supported by this endpoint: use one of " <>
        Enum.join(@tts_response_formats, ", ")}}
  end

  defp validate_image_count(nil), do: :ok
  defp validate_image_count(n) when is_integer(n) and n > 0, do: :ok

  # JSON numbers arrive as floats when the client writes `2.0`: a whole positive
  # float is still a valid count.
  defp validate_image_count(n) when is_float(n) and n > 0 and n == trunc(n), do: :ok

  defp validate_image_count(n) do
    {:error, {:invalid_image_parameter, "n must be a positive integer (got: #{inspect(n)})"}}
  end

  defp validate_image_size(nil), do: :ok
  defp validate_image_size("auto"), do: :ok

  defp validate_image_size(size) when is_binary(size) do
    case String.split(size, "x", parts: 2) do
      [w, h] -> if positive_integer?(w) and positive_integer?(h), do: :ok, else: bad_size(size)
      _ -> bad_size(size)
    end
  end

  defp validate_image_size(size), do: bad_size(size)

  defp positive_integer?(value) do
    case Integer.parse(value) do
      {n, ""} -> n > 0
      _ -> false
    end
  end

  defp bad_size(size) do
    {:error,
     {:invalid_image_parameter,
      "size must be \"auto\" or \"WIDTHxHEIGHT\" with positive sides (got: #{inspect(size)})"}}
  end

  # The audio gate runs AFTER routing on purpose: a request for a model this key
  # cannot reach has to answer the error it always did (404 model_not_found, 429
  # rate_limited, 400 model_type_mismatch) — and only a request that would really
  # reach an audio-body adapter is judged. The dialect decides: DashScope and the
  # Alibaba Token Plan take the audio as a JSON field (`audio_url`, `url`), so
  # their bodies are never touched. See `Tokengate.Proxy.AudioMultipart`.
  defp canonical_upload(conn, :stt, route) do
    provider = route.model_provider.credential.provider
    raw_body = conn.private[MediaBodyParser.raw_body_key()]
    raw_content_type = conn.private[MediaBodyParser.raw_content_type_key()]

    if AudioMultipart.multipart_upload?(provider.dialect) do
      with :ok <- reject_unsupported_format(provider, conn.body_params) do
        # A rebuilt body is built from the payload, so it takes the lane's
        # upstream id — same rule the JSON surfaces get from `execute_simple`.
        payload = Map.put(conn.body_params, "model", route.model_responded)

        case AudioMultipart.canonicalize(raw_body, raw_content_type, payload) do
          {:ok, body, content_type, :unchanged} ->
            {:ok, conn, media_opts(body, content_type)}

          {:ok, body, content_type, :rebuilt} ->
            {:ok, conn, media_opts(body, content_type)}

          {:error, message} ->
            {:error, {:missing_audio, message}}
        end
      end
    else
      {:ok, conn, media_opts(raw_body, raw_content_type)}
    end
  end

  defp canonical_upload(conn, _service, _route) do
    {:ok, conn,
     media_opts(
       conn.private[MediaBodyParser.raw_body_key()],
       conn.private[MediaBodyParser.raw_content_type_key()]
     )}
  end

  # `response_format` on the multipart transcription surface is a closed enum of
  # `json`/`verbose_json` for EVERY dialect the gateway can send it to: OpenRouter
  # documents that enum, and so does the openai-dialect media cluster
  # (Helmcode/NaN — `enum: [json, verbose_json]`). The old gate only guarded
  # OpenRouter, so the same body answered 200 there (translated) and 400 on the
  # other two. Rejecting here costs no attempt and no provider call, and names
  # the way out instead of forwarding a body the upstream refuses.
  defp reject_unsupported_format(_provider, payload) do
    case payload["response_format"] do
      nil ->
        :ok

      format ->
        if AudioMultipart.stt_response_format_supported?(format) do
          :ok
        else
          {:error,
           {:unsupported_response_format,
            "response_format \"#{format}\" is not supported by this provider: ask for " <>
              "\"verbose_json\" and build the subtitles, or omit it for the plain " <>
              "transcript (json)"}}
        end
    end
  end

  # The raw capture travels to the adapter through the route opts so a retry or a
  # fallback resends the same bytes; a JSON request carries none and is encoded
  # as always.
  defp media_opts(nil, _content_type), do: []

  defp media_opts(body, content_type) when is_binary(body),
    do: [raw_body: body, content_type: content_type]

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
  # adapter owns the URL (base_url + the path `ProviderPaths` resolves) and the
  # body it receives in `opts[:raw_body]` travels byte-for-byte, with the
  # client's own content-type (see `TokengateWeb.Plugs.MediaBodyParser`).
  defp adapter_service(provider, credential, payload, opts, service) do
    ProviderAdapter.dispatch(provider).service_post(provider, credential, service, payload, opts)
  end

  # Shared gate pipeline for non-streaming, non-chat endpoints (embeddings
  # and the three path-routed services): same two-gate throttle, routing,
  # budget check, inflight registry, fallback matrix and cost accounting as
  # chat — minus the chat-only payload transforms (guard rails, prompt
  # optimizer, reasoning).
  defp simple_proxy(conn, payload, capability, adapter_fun, kind, opts \\ []) do
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
    Process.delete(:tg_acquired_credential)
    Process.delete(:tg_active_probe)
    Process.delete(:tg_deferred_fallback_logs)
    Process.delete(:tg_upstream_retry_after_ms)
    Process.delete(:tg_inflight_id)
    Process.delete(:tg_router)
    Process.delete(:tg_prompt_tokens_saved)

    with :ok <- require_model(model),
         # The alias is a chat-only destination: every non-chat surface
         # (embeddings, STT, TTS, images, decisions) refuses it BEFORE the
         # catalog is consulted, so it never resolves as `404 model_not_found`
         # nor reaches a provider.
         :ok <- reject_router_alias(model),
         :ok <- acquire_group_limits(key_id, limits) do
      try do
        case route_and_acquire(member, payload, conn.assigns.api_key_hash, limits, [],
               capability: capability
             ) do
          {:ok, route, hold} ->
            case prepare_body(conn, route, opts) do
              {:ok, conn, media_opts} ->
                inflight = register_inflight(conn, member, payload, route)
                Process.put(:tg_inflight_id, inflight.id)

                try do
                  execute_simple(
                    conn,
                    route,
                    payload,
                    member,
                    @max_attempts,
                    [],
                    adapter_fun,
                    kind,
                    [capability: capability] ++ media_opts
                  )
                after
                  settle_budget(member, hold)
                  Tokengate.Logs.Inflight.finish_request(inflight.id)
                  release_active_probe()
                  release_active_credential_limits()
                  flush_deferred_fallback_logs(conn, member)
                  Process.delete(:tg_inflight_id)
                end

              {:error, error} ->
                # The route is already picked (and its hold taken): release both
                # before answering, so a body rejected here costs nothing.
                settle_budget(member, hold)
                release_active_probe()
                release_active_credential_limits()

                log_and_render_proxy_error(conn, route, member, error,
                  latency_ms: elapsed(request_start)
                )
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

  # `"router"` is a chat alias: on a non-chat surface it names no capability at
  # all, so the answer is the same 400 a model of the wrong type gets — never a
  # 404 (the alias is a real, advertised id) and never a provider call.
  defp reject_router_alias(@router_alias), do: {:error, :model_type_mismatch}
  defp reject_router_alias(_model), do: :ok

  # Optional seam that runs AFTER the route is picked and BEFORE any upstream
  # call: it returns the request opts the adapter needs (the media body) or a
  # local error. Rejecting here means no attempt was spent and the error is
  # logged with the provider/model the route resolved.
  defp prepare_body(conn, route, opts) do
    case Keyword.get(opts, :on_route) do
      fun when is_function(fun, 2) -> fun.(conn, route)
      _ -> {:ok, conn, []}
    end
  end

  # A multipart body travels byte-for-byte, so its `model` field is the CLIENT's
  # string and the payload rewrite above never reaches the wire. When the lane's
  # upstream id differs, replace just that part — STT then maps the model exactly
  # like chat/TTS/embeddings do. A body that already names it is left untouched,
  # so the byte-for-byte passthrough survives the common case.
  defp retarget_model(opts, client_model, upstream_model) do
    with raw when is_binary(raw) <- Keyword.get(opts, :raw_body),
         true <- is_binary(client_model) and is_binary(upstream_model),
         true <- client_model != upstream_model do
      {body, content_type} =
        AudioMultipart.rewrite_model(raw, Keyword.get(opts, :content_type), upstream_model)

      Keyword.merge(opts, raw_body: body, content_type: content_type)
    else
      _ -> opts
    end
  end

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
    # A request carrying a raw body (a multipart audio upload — where the
    # payload's own fields are `MediaFile` metadata, or a body rebuilt from
    # base64) is never cached: its cache key would be built from a payload that
    # does not carry the bytes, so two different uploads would hash EQUAL and the
    # second would get the first one's answer.
    cache_key =
      if Keyword.get(route_opts, :raw_body) do
        nil
      else
        ResponseCache.cache_key(conn.assigns.api_key_hash, route.model_responded, payload)
      end

    with :miss <-
           cache_lookup(conn, cache_key, :passthrough, %{
             route: route,
             member: member,
             request_type: to_string(kind)
           }),
         {:ok, _epoch} <- claim_probe_for_attempt(route) do
      receive_timeout = receive_timeout(route.credential)

      # The media body travels in the route opts: a fallback or a same-key retry
      # resends the same bytes instead of losing them.
      adapter_opts =
        [
          receive_timeout: receive_timeout,
          forwarded_headers: extract_forwarded_headers(conn, route)
        ]
        |> Keyword.merge(Keyword.take(route_opts, [:raw_body, :content_type]))
        |> retarget_model(conn.body_params["model"], route.model_responded)

      Process.delete(:tg_upstream_retry_after_ms)

      case adapter_fun.(provider, route.credential, payload, adapter_opts) do
        {:ok, body, latency_ms, resp_headers} ->
          record_attempt_outcome(route, :success, latency_ms: latency_ms, streaming: false)
          cache_store(cache_key, body)
          finalize_simple_success(conn, route, body, latency_ms, member, kind, resp_headers)

        {:error, :auth_error, status, error_message} ->
          disable_credential_async(route.credential, "auth_error_#{status}", error_message)
          record_attempt_outcome(route, {:failure, :auth_error, error_message})

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
          record_attempt_outcome(route, {:failure, :bad_request})

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
          record_attempt_outcome(route, {:failure, :client_error})

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
          record_attempt_outcome(route, {:failure, breaker_reason(reason), error_message})

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
      {:hit, sent_conn} ->
        sent_conn

      {:error, probe_reject} when probe_reject in [:breaker_open, :probe_in_flight] ->
        if attempts_left > 1 do
          retry_simple_with_fallback(
            conn,
            route,
            payload,
            member,
            attempts_left,
            exclude,
            nil,
            adapter_fun,
            kind,
            route_opts,
            provider_retries: @max_retries_per_provider,
            reason: :probe_rejected,
            error_message: nil
          )
        else
          log_and_render_proxy_error(conn, route, member, :all_providers_down,
            error_reason: "all_providers_down"
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
    if reason != :probe_rejected do
      defer_fallback_log(conn, route, status, error_message)
    end

    case advance_fallback_route(
           conn,
           route,
           payload,
           member,
           exclude,
           provider_retries,
           reason,
           Keyword.get(route_opts, :capability, ["llm", "decision"])
         ) do
      {:ok, new_route, new_exclude, new_retries} ->
        execute_simple(
          conn,
          new_route,
          payload,
          member,
          attempts_left - 1,
          new_exclude,
          adapter_fun,
          kind,
          route_opts,
          provider_retries: new_retries
        )

      {:error, :no_available_provider} when reason in [:model_not_available, :billing_error] ->
        log_and_render_proxy_error(conn, route, member, {:upstream_error, reason, status},
          error_reason: safe_reason(reason),
          error_message: error_message
        )

      {:error, :no_available_provider} when reason in [:bad_request, :client_error] ->
        log_and_render_proxy_error(conn, route, member, {:upstream_client_error, status},
          error_reason: safe_reason(reason),
          error_message: error_message
        )

      {:error, :no_available_provider} when reason == :lane_not_servable ->
        log_and_render_proxy_error(
          conn,
          route,
          member,
          {:upstream_error, :lane_not_servable, nil},
          error_reason: "lane_not_servable",
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

    {usage, _} = simple_usage(conn.body_params, reportable, kind, resp_headers)
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

    Process.put(:tg_final_client_status, 200)

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
  #
  # `resp_headers` rides along exactly like the chat path: some upstreams
  # report the cached-prompt-token split ONLY in a header
  # (`fireworks-cached-prompt-tokens`) while the body carries the plain
  # `usage`. Without the headers the cached subset was lost and the request
  # was priced entirely at the input rate (embeddings, images, audio).
  defp simple_usage(payload, body, :embedding, resp_headers) do
    usage =
      UsageNormalizer.normalize(:openai, body, resp_headers) || estimate_embedding_usage(payload)

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
  defp simple_usage(payload, body, kind, resp_headers)
       when kind in [:stt, :tts, :image, :decision] do
    {reported_or_estimated_usage(payload, body, resp_headers), body}
  end

  defp reported_or_estimated_usage(payload, body, resp_headers) do
    reported = UsageNormalizer.normalize(:openai, body, resp_headers)

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
  #   * pool lane — a lane mounted on a credential pool (`pool_id`) never
  #     retries the same key. ANY failure that triggers the fallback excludes
  #     the member at once (`provider_retries` back to 0), because the cap of
  #     `max(1, round(n * 0.8))` members per request (Routing.Pools) only fits
  #     in the @max_attempts 9 budget when each member costs ONE attempt: with
  #     up to 4 attempts per credential (3 same-key retries + the excluding
  #     failure) the 80% cap would be unreachable for n ≥ 4. Single-key lanes
  #     keep their per-credential retries untouched — this clause is first only
  #     for pool lanes.
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
  # Lane de pool (ver la política arriba): CUALQUIER fallo que dispare el
  # fallback excluye al miembro de inmediato y reinicia los reintentos por
  # credencial. Va ANTES de todas las demás cláusulas — incluidas `:timeout` y
  # `:bad_request` — para que un miembro cueste exactamente un intento y el
  # tope del 80% del pool quepa en @max_attempts.
  defp next_candidate(
         %{model_provider: %{pool_id: pool_id}} = route,
         exclude,
         _provider_retries,
         _reason
       )
       when not is_nil(pool_id) do
    {[route.credential.id | exclude], 0}
  end

  defp next_candidate(route, exclude, _provider_retries, :timeout) do
    {[route.credential.id | exclude], 0}
  end

  defp next_candidate(route, exclude, _provider_retries, reason)
       when reason in [:rate_limited, :probe_rejected] do
    {[route.credential.id | exclude], 0}
  end

  # 524: the upstream's own edge gave up on the request (Helmcode/NaN document
  # it for oversized audio). The credential is healthy and the same key would
  # just wait out another gateway timeout, so it is excluded at once — exactly
  # like a receive timeout, but the failure never counts against the breaker
  # (`breaker_reason/1` keeps it out of @counting_reasons).
  defp next_candidate(route, exclude, _provider_retries, :gateway_timeout) do
    {[route.credential.id | exclude], 0}
  end

  # 404 (marketplace sin sellers del modelo): ver la nota de política arriba —
  # exclusión inmediata, la siguiente credencial de la lista intenta.
  defp next_candidate(route, exclude, _provider_retries, :client_error) do
    {[route.credential.id | exclude], 0}
  end

  # Scoped refusals — `403 tier_restricted` (model outside the plan) and `402`
  # (out of balance). The credential is NOT dead, so it is never deactivated;
  # but the refusal is deterministic, so this cascade excludes it at once
  # instead of resending the same body to the same key.
  defp next_candidate(route, exclude, _provider_retries, reason)
       when reason in [:model_not_available, :billing_error] do
    {[route.credential.id | exclude], 0}
  end

  # A lane whose row carries no upstream model id cannot serve ANY body: the
  # refusal is local and deterministic (no byte left the gateway), so the
  # cascade drops that lane at once instead of spending its three per-provider
  # retries on the same configuration gap.
  defp next_candidate(route, exclude, _provider_retries, :lane_not_servable) do
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
      Tokengate.Logs.Inflight.start_request(
        Map.merge(
          %{
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
          },
          inflight_router_fields(conn, route)
        )
      )

    inflight
  end

  # The router columns of the in-flight row: who is running which use case on
  # which resolved model right now. `routed_via_router: false` on a direct
  # request keeps the entry shape uniform.
  #
  # The context is read from the process state FIRST: `advance_router_route/6`
  # publishes the post-hop context there before refreshing the row, while
  # `conn.assigns[:router]` still holds the decision's original context —
  # reading the assign would keep showing the failed destination and its
  # `fallback_*` source would never be visible live.
  defp inflight_router_fields(conn, route) do
    case router_ctx(conn) do
      %{} = ctx ->
        entry = router_entry_for(ctx, route.model.id)

        %{
          routed_via_router: true,
          model_resolved: route.model.name,
          router_use_case_key: get_in(ctx.decision, [:use_case, :key]),
          router_effort_tier: entry && entry.effort_tier,
          router_decision_source: router_decision_source_for(ctx, route)
        }

      _ ->
        %{routed_via_router: false}
    end
  end

  # The live router context: the process state is authoritative (it is the one
  # the cascade mutates), the conn assign is the frozen decision-time copy.
  defp router_ctx(conn) do
    case Process.get(:tg_router) do
      %{} = ctx -> ctx
      _ -> conn.assigns[:router]
    end
  end

  defp router_decision_source_for(ctx, route) do
    source = Map.get(ctx.decision.decision_meta, :source)

    cond do
      route.model.id == ctx.decision.primary.model_id -> to_string(source || "default")
      Map.get(ctx, :last_reason) == :timeout -> "fallback_timeout"
      true -> "fallback_error"
    end
  end

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
          Process.put(:tg_acquired_credential, {route.credential, key_id})
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
        Process.delete(:tg_acquired_credential)
        release_credential_limits(route.credential, key_id)
        {:error, error}
    end
  end

  # Advances the cascade during a retry/fallback:
  #   1. If next_candidate stays on the SAME credential (e.g. 1 fast 5xx retry
  #      or 400 retry), keeps the currently held Puerta 2 slot.
  #   2. If next_candidate excludes the current credential, RELEASES its Puerta 2
  #      slot FIRST, then routes and acquires Puerta 2 for the next healthy
  #      credential (skipping saturated/rate-limited ones instead of bypassing
  #      Gate 2), resets `provider_retries` to 0 when the credential changes,
  #      and refreshes `Inflight` with the new provider/credential.
  defp advance_fallback_route(
         conn,
         route,
         payload,
         member,
         exclude,
         provider_retries,
         reason,
         capability
       ) do
    case Process.get(:tg_router) do
      %{} = ctx ->
        advance_router_route(conn, route, payload, member, ctx, reason)

      _ ->
        advance_direct_route(
          conn,
          route,
          payload,
          member,
          exclude,
          provider_retries,
          reason,
          capability
        )
    end
  end

  defp advance_direct_route(
         conn,
         route,
         payload,
         member,
         exclude,
         provider_retries,
         reason,
         capability
       ) do
    {next_exclude, next_retries} = next_candidate(route, exclude, provider_retries, reason)

    if route.credential.id in next_exclude do
      release_active_credential_limits()
      key_id = member.api_key.id
      affinity_key = conn.assigns[:affinity_key] || conn.assigns.api_key_hash

      case route_and_acquire_fallback(
             member,
             route.model.name,
             payload,
             affinity_key,
             key_id,
             next_exclude,
             capability,
             {0, nil}
           ) do
        {:ok, new_route, final_exclude} ->
          update_inflight_route(conn, member, payload, new_route)
          {:ok, new_route, final_exclude, 0}

        {:error, _} = err ->
          err
      end
    else
      # Same credential retry — keep the held Gate 2 slot.
      {:ok, route, next_exclude, next_retries}
    end
  end

  defp route_and_acquire_fallback(
         _member,
         _model_name,
         _payload,
         _affinity_key,
         _key_id,
         _exclude,
         _capability,
         {attempt, last_reject}
       )
       when attempt >= @max_route_retries do
    {:error, {:cascade_exhausted, last_reject || :provider_concurrency_exceeded}}
  end

  defp route_and_acquire_fallback(
         member,
         model_name,
         payload,
         affinity_key,
         key_id,
         exclude,
         capability,
         {attempt, last_reject}
       ) do
    request_context = %{
      "messages" => payload["messages"] || [],
      :api_key_hash => affinity_key,
      :exclude_credential_ids => exclude,
      :capability => capability
    }

    with {:ok, new_route} <- Router.route(model_name, member, request_context) do
      case acquire_credential_limits(new_route.credential, key_id) do
        :ok ->
          Process.put(:tg_acquired_credential, {new_route.credential, key_id})
          {:ok, new_route, exclude}

        {:error, reject} ->
          norm_reject =
            case reject do
              {:provider_rate_limited, _} -> :provider_rate_limited
              :provider_user_concurrency_exceeded -> :provider_concurrency_exceeded
              other -> other
            end

          route_and_acquire_fallback(
            member,
            model_name,
            payload,
            affinity_key,
            key_id,
            [new_route.credential.id | exclude],
            capability,
            {attempt + 1, norm_reject}
          )
      end
    else
      {:error, :no_available_provider} when last_reject != nil ->
        {:error, {:cascade_exhausted, last_reject}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp claim_probe_for_attempt(route) do
    case CircuitBreakerManager.claim_execution(route.credential.id, self()) do
      {:ok, epoch} ->
        Process.put(:tg_active_probe, {route.credential.id, epoch})
        {:ok, epoch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_attempt_outcome(route, outcome, opts \\ []) do
    epoch =
      case Process.delete(:tg_active_probe) do
        {cred_id, ep} when cred_id == route.credential.id -> ep
        _ -> nil
      end

    retry_after_ms = Process.delete(:tg_upstream_retry_after_ms)

    full_opts =
      opts
      |> then(fn o -> if epoch, do: Keyword.put(o, :epoch, epoch), else: o end)
      |> then(fn o ->
        if retry_after_ms != nil and
             (match?({:failure, _, _}, outcome) or match?({:failure, _}, outcome)),
           do: Keyword.put(o, :retry_after_ms, retry_after_ms),
           else: o
      end)

    Router.record_outcome(route, outcome, full_opts)
  end

  defp release_active_probe do
    case Process.delete(:tg_active_probe) do
      {cred_id, _epoch} -> CircuitBreakerManager.release_probe(cred_id, self())
      _ -> :ok
    end
  end

  defp release_active_credential_limits do
    case Process.delete(:tg_acquired_credential) do
      {credential, key_id} -> release_credential_limits(credential, key_id)
      _ -> :ok
    end
  end

  defp update_inflight_route(conn, member, payload, route) do
    if inflight_id = Process.get(:tg_inflight_id) do
      Tokengate.Logs.Inflight.start_request(
        Map.merge(
          %{
            id: inflight_id,
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
          },
          # A router hop moves `model_resolved` / `router_*` with the new
          # route: the live monitor must show the destination that is actually
          # serving, not the decision's first choice.
          inflight_router_fields(conn, route)
        )
      )
    end
  end

  # Reserves budget for the request against the subject's spend plan. Returns
  # `{:ok, hold}`, settled — or released, if the request produced no cost — in
  # the caller's `after` via `settle_budget/2`. Every provider goes through
  # this gate; there is no billing-surface exemption.
  defp reserve_budget(member, limits, _route) do
    reserve_credit_budget(member, limits)
  end

  # Credit path: hold against the subject's spend plan — its monthly limit
  # first, then the top-up that expires soonest (resolved by
  # `Credits.plan/1`). Records WHAT the request debits (limit or top-up id) so
  # the durable log can persist it.
  defp reserve_credit_budget(member, limits) do
    plan = limits.credit_plan || Tokengate.Credits.plan(member)

    result = Budgets.reserve_plan(plan, max_request_cost_usd())

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
  # subject's monthly limit. Keep it close to a realistic request cost.
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

  # Adapter seams for the chat family.
  #
  # The adapter is passed as a VALUE (instead of calling the module directly) so
  # Elixir's type checker does not narrow the result to `OpenAIAdapter`'s
  # concrete return: a dialect adapter can refuse synchronously (a body it
  # cannot translate, a missing knob) with the shapes
  # `ProviderAdapter.chat_result/0` / `stream_chat_completion/4` declare, and
  # those must reach the callers' error clauses instead of crashing the case.
  # Routing is untouched — the module is still chosen at the call site.
  defp adapter_chat_completion(adapter, provider, credential, payload, opts) do
    adapter.chat_completion(provider, credential, payload, opts)
  end

  defp adapter_stream_chat_completion(adapter, provider, credential, payload, opts) do
    adapter.stream_chat_completion(provider, credential, payload, opts)
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
  # the entry, and this one never reached it. It is still a request the gateway
  # served, so it books a row and a realtime-collector hit like any other
  # response (see `record_cache_hit/3`).
  defp cache_lookup(_conn, nil, _body_shape, _log_ctx), do: :miss

  defp cache_lookup(conn, key, body_shape, log_ctx) do
    case ResponseCache.lookup(key) do
      {:ok, body_json, _age} ->
        Process.put(:tg_final_client_status, 200)

        conn =
          conn
          |> put_resp_header("content-type", "application/json")
          |> put_resp_header("x-tokengate-cache", "hit")
          |> put_resp_header("x-tokengate-cost", Decimal.to_string(@zero_cost, :normal))
          |> send_resp(200, cached_body(body_json, body_shape))

        record_cache_hit(conn, body_shape, log_ctx)

        {:hit, conn}

      :miss ->
        :miss
    end
  end

  # Accounting for a served cache hit: the durable row is booked at $0 / 0
  # tokens (nothing was consumed upstream) and the request is counted in the
  # realtime collector, so a cache-heavy minute is not invisible in the
  # dashboard. `request_logs.cache_hit` marks the row (the header only reaches
  # the client, not the table). The budget hold is RELEASED (not settled) by
  # the caller's `after`, because `:tg_budget_actual_cost` stays unset — hence
  # no `credit_topup_id` on the row.
  defp record_cache_hit(_conn, _body_shape, nil), do: :ok

  defp record_cache_hit(conn, body_shape, %{route: route, member: member} = log_ctx) do
    usage = %{
      prompt_tokens: 0,
      completion_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0
    }

    request_type = Map.get(log_ctx, :request_type, cache_hit_request_type(body_shape))

    Collector.record_request(%{
      model_id: route.model.id,
      provider_id: route.model_provider.credential.provider_id,
      credential_name: route.credential.name,
      agent_type: conn.assigns.agent_type,
      status: 200,
      latency_ms: 0,
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd: @zero_cost,
      streaming: false
    })

    enqueue_log(route, member, conn.assigns.agent_type, usage, @zero_cost, 0, 200, false,
      think: conn.assigns[:think] || false,
      effort: conn.assigns[:effort],
      effort_applied: conn.assigns[:effort_applied],
      session_id: conn.assigns[:session_key],
      client_agent: conn.assigns.client_agent,
      request_type: request_type,
      credit_topup_id: nil,
      cache_hit: true,
      # $0 served by the gateway: no counterfactual baseline (F9).
      router_baseline: false
    )
  end

  # `:chat_usage` is the chat path; every other shape is a requested service
  # whose own `kind` the caller passes in `log_ctx`.
  defp cache_hit_request_type(:chat_usage), do: "chat"
  defp cache_hit_request_type(_), do: "embedding"

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

    conn = capture_router_payload(conn, payload)

    # El body que viaja a ESTE upstream se construye SIEMPRE desde el body
    # original del cliente: las guard rails del modelo, el dialecto de
    # reasoning que habla el upstream y los overrides del model_provider
    # (`extra_body`, `omit_body_fields`) son POR-UPSTREAM. El body ya reescrito
    # NO se hereda a los reintentos ni al fallback; heredarlo (a) manda el pin
    # del agregador (`provider`) al proveedor DIRECTO que le toca el fallback
    # —que 400ea en un campo que no documenta— y (b) apila las guard rails una
    # vez por intento. `payload` sigue siendo el del cliente para la cascada:
    # cada intento se reescribe desde cero con las reglas de SU upstream.
    conn = assign_router_effort(conn, route)

    {attempt_payload, prompt_tokens_saved} =
      payload
      |> Map.put("model", route.model_responded)
      |> inject_guard_rails(route.model)
      |> maybe_optimize(optimize_ctx(conn, route))

    # The effort value THIS attempt sends to the wire: consumed by the log
    # row if the attempt wins (fallbacks rebuild from the client payload, so
    # every attempt re-derives its own value).
    conn =
      conn
      |> assign(:effort_applied, wire_effort(attempt_payload))
      |> assign(:prompt_tokens_saved_est, prompt_tokens_saved)

    Process.put(:tg_prompt_tokens_saved, prompt_tokens_saved)

    # Gateway-local response cache (non-streaming chat only): identical
    # requests served from ETS. The key is the body THIS upstream receives, so
    # it stays stable across the retries/fallbacks of one request (they all
    # rebuild the same body for the same route) and never picks up another
    # route's overrides.
    cache_key =
      ResponseCache.cache_key(conn.assigns.api_key_hash, route.model_responded, attempt_payload)

    with :miss <-
           cache_lookup(conn, cache_key, :chat_usage, %{
             route: route,
             member: member,
             request_type: "chat"
           }),
         {:ok, _epoch} <- claim_probe_for_attempt(route) do
      receive_timeout = receive_timeout(route.credential)
      adapter = ProviderAdapter.dispatch(provider)
      Process.delete(:tg_upstream_retry_after_ms)

      case adapter_chat_completion(adapter, provider, route.credential, attempt_payload,
             receive_timeout: receive_timeout,
             forwarded_headers: extract_forwarded_headers(conn, route)
           ) do
        {:ok, body, latency_ms, resp_headers} ->
          record_attempt_outcome(route, :success, latency_ms: latency_ms, streaming: false)
          cache_store(cache_key, body)
          finalize_success(conn, route, body, latency_ms, member, resp_headers)

        {:error, :auth_error, status, error_message} ->
          disable_credential_async(route.credential, "auth_error_#{status}", error_message)
          record_attempt_outcome(route, {:failure, :auth_error, error_message})

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
          record_attempt_outcome(route, {:failure, :bad_request})

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
          record_attempt_outcome(route, {:failure, :client_error})

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
          record_attempt_outcome(route, {:failure, breaker_reason(reason), error_message})

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

        {:error, reason, status} ->
          if reason == :auth_error do
            disable_credential_async(route.credential, "auth_error_#{status}")
          end

          record_attempt_outcome(route, {:failure, breaker_reason(reason)})

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
              nil
            )
          else
            log_and_render_proxy_error(conn, route, member, {:upstream_error, reason, status},
              error_reason: safe_reason(reason)
            )
          end
      end
    else
      {:hit, sent_conn} ->
        sent_conn

      {:error, probe_reject} when probe_reject in [:breaker_open, :probe_in_flight] ->
        if attempts_left > 1 do
          retry_with_fallback(
            conn,
            route,
            payload,
            member,
            attempts_left,
            exclude,
            nil,
            @max_retries_per_provider,
            :probe_rejected,
            nil
          )
        else
          log_and_render_proxy_error(conn, route, member, :all_providers_down,
            error_reason: "all_providers_down"
          )
        end
    end
  end

  # Permanently disable a credential after an auth/billing failure (401/402/403).
  # Runs in a background Task to avoid blocking the hot path. The credential's
  # status is set to "error" so the router excludes it from the candidate pool.
  #
  # `error_at` is a `:utc_datetime` column: `DateTime.utc_now/0` carries
  # microseconds and Ecto raises on them, so the value is truncated to the
  # second. Without this the whole Task died inside `update_credential/2` and a
  # dead credential was never actually disabled (the broadcast never fired
  # either) — the disable path was silently a no-op.
  defp disable_credential_async(credential, reason, error_message \\ nil) do
    Task.start(fn ->
      Providers.update_credential(credential, %{
        status: "error",
        error_reason: reason,
        error_message: error_message,
        error_at: DateTime.utc_now() |> DateTime.truncate(:second)
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
    if reason != :probe_rejected do
      defer_fallback_log(conn, route, status, error_message)
    end

    case advance_fallback_route(
           conn,
           route,
           payload,
           member,
           exclude,
           provider_retries,
           reason,
           ["llm", "decision"]
         ) do
      {:ok, new_route, new_exclude, new_retries} ->
        execute(conn, new_route, payload, member, attempts_left - 1, new_exclude, new_retries)

      {:error, :no_available_provider} when reason in [:model_not_available, :billing_error] ->
        log_and_render_proxy_error(conn, route, member, {:upstream_error, reason, status},
          error_reason: safe_reason(reason),
          error_message: error_message
        )

      {:error, :no_available_provider} when reason in [:bad_request, :client_error] ->
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

    conn = capture_router_payload(conn, payload)

    # Mismo contrato que `execute/7`: el body por-intento se construye desde el
    # body ORIGINAL del cliente (nunca desde el del intento anterior).
    conn = assign_router_effort(conn, route)

    {attempt_payload, prompt_tokens_saved} =
      payload
      |> Map.put("model", route.model_responded)
      |> ensure_stream_options()
      |> inject_guard_rails(route.model)
      |> maybe_optimize(optimize_ctx(conn, route))

    # Same contract as `execute/7`: the applied effort of THIS attempt, for
    # the log row if the attempt wins.
    conn =
      conn
      |> assign(:effort_applied, wire_effort(attempt_payload))
      |> assign(:prompt_tokens_saved_est, prompt_tokens_saved)

    Process.put(:tg_prompt_tokens_saved, prompt_tokens_saved)

    # Measured just before the upstream call: TTFT is the time from this
    # point to the provider's first chunk.
    request_start = System.monotonic_time(:millisecond)
    receive_timeout = receive_timeout(route.credential)

    case claim_probe_for_attempt(route) do
      {:error, probe_reject} when probe_reject in [:breaker_open, :probe_in_flight] ->
        if attempts_left > 1 do
          retry_stream_with_fallback(
            conn,
            route,
            payload,
            member,
            attempts_left,
            exclude,
            @max_retries_per_provider,
            :probe_rejected,
            nil,
            nil
          )
        else
          log_and_render_proxy_error(conn, route, member, :all_providers_down,
            error_reason: "all_providers_down"
          )
        end

      {:ok, _epoch} ->
        adapter = ProviderAdapter.dispatch(provider)
        Process.delete(:tg_upstream_retry_after_ms)

        case adapter_stream_chat_completion(
               adapter,
               provider,
               route.credential,
               attempt_payload,
               receive_timeout: receive_timeout,
               forwarded_headers: extract_forwarded_headers(conn, route)
             ) do
          {:ok, pid} ->
            ref = Process.monitor(pid)

            case await_first_chunk(pid, ref) do
              {:ok, first_chunk, resp_headers} ->
                ttft_ms = System.monotonic_time(:millisecond) - request_start
                record_attempt_outcome(route, :success, latency_ms: ttft_ms, streaming: true)

                conn =
                  conn
                  |> put_resp_content_type("text/event-stream")
                  |> put_resp_header("cache-control", "no-cache")
                  |> send_chunked(200)

                stream_loop(conn, pid, ref, first_chunk, route, member, attempt_payload, %{
                  usage: nil,
                  completion: [],
                  prompt_estimate:
                    TokenEstimator.estimate_messages(attempt_payload["messages"] || []),
                  ttft_ms: ttft_ms,
                  latency_start: System.monotonic_time(:millisecond),
                  resp_headers: resp_headers
                })

              {:error, reason, status, error_message} ->
                Process.exit(pid, :kill)
                Process.demonitor(ref, [:flush])

                if reason == :auth_error do
                  disable_credential_async(
                    route.credential,
                    "auth_error_stream",
                    error_message
                  )
                end

                record_attempt_outcome(route, {:failure, breaker_reason(reason), error_message})

                cond do
                  reason == :bad_request and attempts_left > 1 ->
                    defer_fallback_log(conn, route, status, error_message)

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

                  reason == :client_error and attempts_left > 1 ->
                    defer_fallback_log(conn, route, status, error_message)

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
                    defer_fallback_log(conn, route, status, error_message)

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
                    log_and_render_proxy_error(
                      conn,
                      route,
                      member,
                      {:upstream_error, reason, status},
                      error_reason: safe_reason(reason),
                      error_message: error_message
                    )
                end
            end

          {:error, reason, status, error_message} ->
            handle_adapter_start_error(
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

          {:error, reason, status} ->
            handle_adapter_start_error(
              conn,
              route,
              payload,
              member,
              attempts_left,
              exclude,
              provider_retries,
              reason,
              status,
              nil
            )
        end
    end
  end

  defp handle_adapter_start_error(
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
    if reason == :auth_error do
      disable_credential_async(route.credential, "auth_error_stream", error_message)
    end

    record_attempt_outcome(route, {:failure, breaker_reason(reason), error_message})

    if attempts_left > 1 do
      defer_fallback_log(conn, route, status, error_message)

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
    else
      log_and_render_proxy_error(conn, route, member, {:upstream_error, reason, status},
        error_reason: safe_reason(reason),
        error_message: error_message
      )
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
    case advance_fallback_route(
           conn,
           route,
           payload,
           member,
           exclude,
           provider_retries,
           reason,
           ["llm", "decision"]
         ) do
      {:ok, new_route, new_exclude, new_retries} ->
        execute_stream(
          conn,
          new_route,
          payload,
          member,
          attempts_left - 1,
          new_exclude,
          new_retries
        )

      {:error, :no_available_provider} when reason in [:model_not_available, :billing_error] ->
        log_and_render_proxy_error(conn, route, member, {:upstream_error, reason, status},
          error_reason: safe_reason(reason),
          error_message: error_message
        )

      {:error, :no_available_provider} when reason in [:bad_request, :client_error] ->
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

    payload =
      payload
      |> Map.put("messages", PromptOptimizer.stable_prefix(messages))
      |> Map.update!("messages", &PromptOptimizer.lazy_cleanup/1)
      |> Map.update!("messages", &PromptOptimizer.strip_reasoning/1)

    {payload, saved} =
      PromptOptimizer.apply_router_policy(payload, Map.get(route_ctx, :prompt_policy),
        pinned: Map.get(route_ctx, :router_pinned) == true
      )

    payload =
      payload
      |> drop_strict_fields(provider_key(route_ctx))
      |> normalize_reasoning(route_ctx)
      # Operator overrides run LAST so they can strip/replace anything the
      # gateway or the client put in the body (a per-row `omit_body_fields`
      # can pull a client field back out, and `extra_body` can add/replace).
      |> apply_request_overrides(route_ctx)

    {payload, saved}
  end

  defp maybe_optimize(payload, _model_model), do: {payload, nil}

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
  defp optimize_ctx(conn, route) do
    %{
      model_type: route.model && route.model.model_type,
      model_provider: route.model_provider,
      # Operator effort policy of the logical model (nil/nil = no-op). A router
      # decision overrides it per destination: the use-case binding, not the
      # shared model row, decides the effort the request goes out with.
      effort_default: route.model && route.model.effort_default,
      effort_override:
        conn.assigns[:router_effort_override] || (route.model && route.model.effort_override),
      # Use-case prompt policy — `nil` for a direct request (no extra passes).
      prompt_policy: conn.assigns[:router_prompt_policy],
      # An ACTIVE session pin means this conversation's upstream prefix is
      # cached: `stale_tool_trim` must not rewrite history unless the saving
      # clears its threshold.
      router_pinned: conn.assigns[:router_pinned] == true,
      extra_body: model_provider_setting(route, :extra_body),
      omit_body_fields: model_provider_setting(route, :omit_body_fields),
      omit_headers: model_provider_setting(route, :omit_headers)
    }
  end

  # Publishes THIS attempt's router effort override from the decision's chain:
  # `optimize_ctx/2` then simply prefers the assign over the model row.
  defp assign_router_effort(conn, route) do
    case conn.assigns[:router_effort_overrides] do
      %{} -> assign(conn, :router_effort_override, router_effort_override(conn, route))
      _ -> conn
    end
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
    deadline = System.monotonic_time(:millisecond) + timeout

    receive do
      {:sse_headers, headers} ->
        case Tokengate.Proxy.ProviderAdapter.parse_retry_after_ms(headers) do
          nil -> :ok
          ms -> Process.put(:tg_upstream_retry_after_ms, ms)
        end

        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        case await_first_chunk_after_headers(pid, ref, remaining) do
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

  # Waits for the first data chunk after headers have been received, sharing the
  # single monotonic deadline from await_first_chunk/2.
  defp await_first_chunk_after_headers(pid, ref, remaining_ms) do
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
      remaining_ms -> {:error, :timeout, nil, nil}
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

          {:sse_error, reason} ->
            # Mid-stream failure: record against breaker so an upstream that
            # emits 1 chunk and drops cannot keep resetting failures to 0.
            Process.demonitor(ref, [:flush])
            Router.record_outcome(route, {:failure, breaker_reason(stream_error_reason(reason))})
            finish_stream(conn, route, member, acc, 502, "stream_error")

          {:DOWN, ^ref, :process, ^pid, reason} ->
            if reason != :normal do
              Router.record_outcome(
                route,
                {:failure, breaker_reason(stream_error_reason(reason))}
              )
            end

            finish_stream(conn, route, member, acc, 502, "stream_error")
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

            finish_stream(conn, route, member, acc, 504, "stream_timeout")
        end

      {:client_gone, conn, acc} ->
        # El cliente cortó la conexión a media respuesta. El proveedor YA cobró
        # los tokens emitidos hasta aquí, así que el request se cierra como
        # cualquier otro: matar el upstream (antes de seguir gastando), soltar
        # el monitor y pasar por `finish_stream` para que el costo real se
        # escriba y el `settle` del caller libere sólo el remanente del hold.
        # Sin esto el log no existía, el hold completo quedaba liberado (costo
        # real perdido) y no había ni una línea de diagnóstico.
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])

        Logger.info(
          "proxy stream: client disconnected mid-stream " <>
            "model_id=#{inspect(route.model.id)} credential_id=#{inspect(route.credential.id)}"
        )

        finish_stream(conn, route, member, acc, 499, "client_gone")
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
  # (same contract as the non-streaming response). The updated acc travels back
  # on BOTH outcomes: a closed client must still book the usage captured for
  # this very chunk (that is the cost the provider already charged).
  defp forward_stream_chunk(conn, chunk, route, acc) do
    {chunk, acc} = maybe_capture_usage(chunk, route, acc)

    case Plug.Conn.chunk(conn, "data: #{chunk}\n\n") do
      {:ok, conn} -> {:ok, conn, acc}
      {:error, _closed} -> {:client_gone, conn, acc}
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

  defp finish_stream(conn, route, member, acc, status \\ 200, error_reason \\ nil) do
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
    Process.put(:tg_final_client_status, 200)
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
      status: status,
      latency_ms: latency_ms,
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      cost_usd: cost,
      streaming: true
    })

    enqueue_log(route, member, conn.assigns.agent_type, usage, cost, latency_ms, status, true,
      ttft_ms: acc.ttft_ms,
      think: conn.assigns[:think] || false,
      effort: conn.assigns[:effort],
      effort_applied: conn.assigns[:effort_applied],
      session_id: conn.assigns[:session_key],
      client_agent: conn.assigns.client_agent,
      # `nil` on a clean stream; "client_gone" / "stream_error" /
      # "stream_timeout" when the stream was cut. The provider charged what it
      # emitted — the row books that real cost under the closure reason.
      error_reason: error_reason
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
  # Manual pricing has two shapes: token units read input/output plus the
  # optional cache-read/cache-write rates; other units use `unit_cost` against
  # the call's quantities (per image/second/minute/character/request), so media
  # services are priceable too.
  #
  # Used by finalize_simple_success and finalize_success (non-streaming).
  defp cost_with_fallback(route, provider_reported, usage, quantities) do
    mp = route.model_provider

    CostCalculator.provider_cost(provider_reported,
      manual_pricing: %{
        input_cost_per_million: mp.input_cost_per_million,
        output_cost_per_million: mp.output_cost_per_million,
        cache_cost_per_million: mp.cache_cost_per_million,
        cache_write_cost_per_million: mp.cache_write_cost_per_million
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

    Process.put(:tg_final_client_status, 200)

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

  # The router columns of a durable row. `routed_via_router: false` for a
  # direct request keeps the column honest without adding keys nobody reads.
  #
  # `baseline` is `false` for the rows that must NOT carry a counterfactual
  # (`$0` ResponseCache hits, error rows): pricing "what the baseline model
  # would have cost" for a request that served nothing skews model selection.
  defp router_log_attrs(route, member, usage, baseline) do
    case Process.get(:tg_router) do
      %{} = ctx ->
        entry = router_entry_for(ctx, route.model.id)
        meta = ctx.decision.decision_meta
        baseline_cost = if baseline, do: router_baseline_cost(member, usage), else: nil

        %{
          "routed_via_router" => true,
          "model_resolved" => route.model.name,
          # The configuration VERSION that decided: the audit trail the version
          # comparison reads back (`nil` for rows written before versioning).
          "router_config_id" => Map.get(ctx, :config_id),
          "router_use_case_id" => ctx.decision.use_case.id,
          "router_use_case_key" => ctx.decision.use_case.key,
          "router_use_case_model_id" => entry && entry.use_case_model_id,
          "router_effort_tier" => entry && entry.effort_tier,
          "router_decision_source" => router_decision_source_for(ctx, route),
          "router_decision_ms" => Map.get(meta, :latency_ms),
          "router_decision_cost_usd" => router_decision_cost_string(ctx),
          "router_baseline_model_id" => baseline_cost && baseline_cost.model_id,
          "router_baseline_cost_usd" =>
            baseline_cost && Decimal.to_string(baseline_cost.cost, :normal),
          "router_direct_access" => Router.direct_access?(route.model.id, member),
          "prompt_tokens_saved_est" => Process.get(:tg_prompt_tokens_saved)
        }

      _ ->
        %{"routed_via_router" => false}
    end
  end

  defp router_model_requested(default) do
    if Process.get(:tg_router), do: @router_alias, else: default
  end

  defp router_decision_cost_string(%{decision_lane_cost: %{cost: %Decimal{} = cost}}),
    do: Decimal.to_string(cost, :normal)

  defp router_decision_cost_string(_ctx), do: nil

  # The FROZEN counterfactual: the request's real usage priced with the
  # baseline model's own primary visible lane (`groups.router_baseline_model_id`
  # -> `router_configs.baseline_model_id`). `nil` when there is no baseline
  # model, no visible lane or no tariff — a saving is never invented.
  #
  # The rates are the lane's WHOLE tariff: `cache_read` splits the prompt,
  # `cache_write` prices the creation tokens, and a non-token unit is priced
  # with the lane's `unit_cost` against the chat's own quantities (`per_request`
  # is 1 per call), exactly like `cost_with_fallback/4` prices the served
  # request. Leaving any of them out undervalued the baseline and inflated the
  # reported saving.
  defp router_baseline_cost(member, usage) do
    model_id =
      Accounts.router_baseline_model_id(member) || Map.get(router_config(), :baseline_model_id)

    case model_id && Router.primary_tariff(model_id, member) do
      %{} = tariff ->
        cost =
          CostCalculator.provider_cost(nil,
            manual_pricing: %{
              input_cost_per_million: tariff.input_cost_per_million,
              output_cost_per_million: tariff.output_cost_per_million,
              cache_cost_per_million: tariff.cache_cost_per_million,
              cache_write_cost_per_million: tariff.cache_write_cost_per_million
            },
            usage: usage,
            pricing_unit: tariff.pricing_unit || "per_1m_tokens",
            unit_cost: tariff.unit_cost,
            quantities: ServiceUsage.quantities("llm", %{}, %{})
          )

        if Decimal.compare(cost, @zero_cost) == :gt, do: %{model_id: model_id, cost: cost}

      _ ->
        nil
    end
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

    # The id and the partition timestamp are fixed HERE, once: the Shadow
    # evaluator is dispatched with `(request_log_id, request_inserted_at)` and
    # writes its row before this log's Oban job may even run, so both sides
    # must name the same pair (and the same day partition).
    log_id = Keyword.get(extra, :id) || Ecto.UUID.generate()

    inserted_at =
      Keyword.get_lazy(extra, :inserted_at, fn ->
        DateTime.utc_now() |> DateTime.truncate(:second)
      end)

    attrs =
      %{
        "id" => log_id,
        "group_member_id" => subject.group_member_id,
        "user_id" => member.user_id,
        "service_id" => subject.service_id,
        "subject_type" => subject.subject_type,
        "provider_id" => route.model_provider.credential.provider_id,
        "model_provider_id" => route.model_provider.id,
        "model_id" => route.model.id,
        # The client's own string: `"router"` when the alias was requested, so a
        # routed request is never disguised as a direct one.
        "model_requested" =>
          router_model_requested(Keyword.get(extra, :model_requested, route.model.name)),
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
        # `credit_topup_id: nil` is passed by cache hits: their hold is RELEASED
        # (nothing was charged), so the reservation id would name a debit that
        # never happened.
        "credit_topup_id" =>
          Keyword.get(extra, :credit_topup_id, Process.get(:tg_credit_topup_id)),
        "latency_ms" => latency_ms,
        "ttft_ms" => Keyword.get(extra, :ttft_ms),
        "streaming" => streaming,
        # Durable cache-hit marker: `true` only when the response came from the
        # gateway-local cache (both the chat and the passthrough hit paths pass
        # it; every other enqueue leaves it false).
        "cache_hit" => Keyword.get(extra, :cache_hit, false),
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
        "inserted_at" => DateTime.to_iso8601(inserted_at)
      }
      |> Map.merge(
        router_log_attrs(route, member, usage, Keyword.get(extra, :router_baseline, true))
      )

    result =
      attrs
      |> WriteWorker.new()
      |> insert_log_job(%{
        model_id: route.model.id,
        provider_id: route.model_provider.credential.provider_id,
        status: status,
        error_reason: Keyword.get(extra, :error_reason)
      })

    maybe_evaluate_shadow(route, log_id, inserted_at, usage, cost, status, extra, member)

    result
  end

  # Shadow evaluation of a SERVED chat request (S4). Dispatched after the log
  # job — the response already left — and only when a version is actually
  # `shadow_enabled`; `ShadowEvaluator.evaluate_async/1` returns immediately
  # and spawns nothing otherwise.
  #
  # Skipped for: non-router requests, failures (no served destination to
  # compare), gateway-local cache hits (nothing reached an upstream, so every
  # token count is zero) and non-chat request types (the router only serves
  # chat).
  defp maybe_evaluate_shadow(route, log_id, inserted_at, usage, cost, status, extra, member) do
    ctx = Process.get(:tg_router)

    with %{} <- ctx,
         true <- is_integer(status) and status < 400,
         false <- Keyword.get(extra, :cache_hit, false) == true,
         "chat" <- Keyword.get(extra, :request_type, "chat"),
         [_ | _] <- SmartRouter.shadow_configs() do
      ShadowEvaluator.evaluate_async(%{
        request_log_id: log_id,
        request_inserted_at: inserted_at,
        # The client's own body, captured before any rewrite/optimisation.
        payload: Process.get(:tg_router_raw_payload) || %{},
        # The SAME context the Default decided with (`subject_id`, `user_id`,
        # `session_id`, …): the sampling key and the rules the shadow applies
        # must describe the same caller.
        context: Map.get(ctx, :context) || %{},
        # The decision the Default ACTUALLY served: when the cascade landed on
        # a fallback, `primary` names the destination it chose, not the model
        # that answered — the comparison must name the model that really
        # served this request.
        default_decision: effective_default_decision(ctx, route),
        usage: usage,
        default_served_cost_usd: cost,
        prompt_tokens_saved_est: Process.get(:tg_prompt_tokens_saved),
        group_member: member
      })

      :ok
    else
      _ -> :ok
    end
  end

  # `decision.primary` is the destination the decision picked; `route.model` is
  # the one that actually answered (the same when nothing fell back). A
  # fallback rewrites the Default side to the serving model and its tier, so
  # `default_model_id` / `default_model_name` / `default_effort_tier` on the
  # evaluation describe reality instead of the abandoned candidate.
  defp effective_default_decision(ctx, route) do
    decision = ctx.decision
    primary = Map.get(decision, :primary) || %{}

    if Map.get(primary, :model_id) == route.model.id do
      decision
    else
      entry = router_entry_for(ctx, route.model.id)

      effective_primary =
        primary
        |> Map.put(:model_id, route.model.id)
        |> Map.put(:model_name, route.model.name)
        |> Map.put(:effort_tier, (entry && entry.effort_tier) || Map.get(primary, :effort_tier))

      Map.put(decision, :primary, effective_primary)
    end
  end

  # `Oban.insert/1`'s failure used to be discarded: on a saturated pool or a
  # downed DB the job — and with it the `request_logs` row, the webhook fan-out
  # and the dashboard feed — vanished without a trace. `WriteWorker.enqueue/2`
  # keeps the response path silent but persists the row through a direct
  # insert when the enqueue fails, so the accounting record is never lost
  # (the row carries the same cost/subject; the budget was already settled, so
  # no phantom cost appears).
  defp insert_log_job(job, context), do: WriteWorker.enqueue(job, context)

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

  # Resolves the model id by name via ETS cache for gate-error logs.
  defp model_id_for_name(nil), do: nil

  defp model_id_for_name(name) when is_binary(name) do
    Tokengate.Providers.get_model_id_by_name(name)
  end

  defp enqueue_error_log(conn, route, member, opts) do
    subject = log_subject(member)

    %{
      # A failed attempt books nothing and is never shadowed, but the id is
      # still fixed here so every durable row of one request is born with a
      # known identity (the same contract as `enqueue_log/9`).
      "id" => Keyword.get(opts, :id) || Ecto.UUID.generate(),
      "group_member_id" => subject.group_member_id,
      "user_id" => member.user_id,
      "service_id" => subject.service_id,
      "subject_type" => subject.subject_type,
      "provider_id" => route.model_provider.credential.provider_id,
      "model_provider_id" => route.model_provider.id,
      "model_id" => route.model.id,
      # A failed routed attempt is still a ROUTER request: the alias the client
      # asked for stays in `model_requested`, the resolved model in `model_id`.
      "model_requested" => router_model_requested(route.model.name),
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
    |> Map.merge(router_log_attrs(route, member, error_usage(), false))
    # A failed attempt books nothing, and in particular it must NOT re-book the
    # classifier: one router request that exhausts N attempts would otherwise
    # repeat the SAME decision cost on N rows and every SUM over the column
    # would multiply it. The `router_decision` row (or the served row) already
    # carries the decision cost exactly once.
    |> Map.put("router_decision_cost_usd", nil)
    |> WriteWorker.new()
    |> insert_log_job(%{
      model_id: route.model.id,
      provider_id: route.model_provider.credential.provider_id,
      status: Keyword.get(opts, :client_status),
      error_reason: Keyword.get(opts, :error_reason)
    })
  end

  # An error row books nothing: no tokens were billed and the counterfactual
  # baseline would price a request that never happened.
  defp error_usage do
    %{prompt_tokens: 0, completion_tokens: 0, cache_read_tokens: 0, cache_creation_tokens: 0}
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
    |> insert_log_job(%{
      model_id: nil,
      provider_id: nil,
      status: Keyword.get(opts, :client_status),
      error_reason: Keyword.get(opts, :error_reason)
    })
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
  # Buffers failed provider attempts in memory during the cascade and enqueues
  # their Oban jobs AFTER the final response has left (inside the caller's
  # `after` block), avoiding synchronous Postgres INSERT latency mid-failover.
  defp defer_fallback_log(conn, route, status, error_message) do
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

    entry = %{
      route: route,
      status: status,
      error_reason: error_reason,
      error_message: error_message,
      streaming: conn.body_params["stream"] == true
    }

    existing = Process.get(:tg_deferred_fallback_logs, [])
    Process.put(:tg_deferred_fallback_logs, [entry | existing])
  end

  defp flush_deferred_fallback_logs(conn, member) do
    Process.delete(:tg_final_client_status)

    Process.delete(:tg_deferred_fallback_logs)
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.each(fn entry ->
      enqueue_error_log(conn, entry.route, member,
        client_status: 200,
        provider_status: entry.status,
        error_reason: entry.error_reason,
        error_message: entry.error_message,
        latency_ms: 0,
        streaming: entry.streaming
      )
    end)
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
  # A lane with no upstream model id never reached a provider: it is a local
  # refusal, so it must not count against the credential's breaker (that would
  # suspend a healthy key for a configuration gap). Same family as a 400 —
  # non-counting — while the cascade still excludes the lane.
  defp breaker_reason(:lane_not_servable), do: :bad_request
  # Scoped refusals and a provider edge timeout are NOT symptoms of credential
  # health: they pass through as themselves, which the breaker ignores (it only
  # counts @counting_reasons). Without these clauses the catch-all below would
  # count them as :server_error and burn a healthy provider's breaker.
  defp breaker_reason(:model_not_available), do: :model_not_available
  defp breaker_reason(:billing_error), do: :billing_error
  defp breaker_reason(:gateway_timeout), do: :gateway_timeout
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

    Process.put(:tg_final_client_status, status)
    send_resp(conn, status, Jason.encode!(body))
  end

  defp error_details({:invalid_request, msg}),
    do: {400, "invalid_request_error", "invalid_request", msg}

  # The transcription surface could not recover audio from the body: a local
  # rejection (no upstream call), named so the client knows what to send and the
  # log row says `missing_audio` instead of a generic invalid request.
  defp error_details({:missing_audio, msg}),
    do: {400, "invalid_request_error", "missing_audio", msg}

  # The provider's dialect cannot serve the `response_format` the client asked
  # for; the message names the supported alternatives.
  defp error_details({:unsupported_response_format, msg}),
    do: {400, "invalid_request_error", "unsupported_response_format", msg}

  # The speech surface requires a `voice`; without one the upstream would answer
  # 400/422 after the request had already been routed and held (F15).
  defp error_details({:missing_voice, msg}),
    do: {400, "invalid_request_error", "missing_voice", msg}

  # An image parameter the wire's schema cannot describe (`n` not a positive
  # integer, `size` neither "auto" nor "WIDTHxHEIGHT").
  defp error_details({:invalid_image_parameter, msg}),
    do: {400, "invalid_request_error", "invalid_image_parameter", msg}

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

  defp error_details({:budget_exceeded, %{layer: :subject}}),
    do: {402, "billing_error", "budget_exceeded", "Monthly spend limit exceeded"}

  # «Sin crédito»: no hay límite mensual (ni propio ni del perfil de límites), no está
  # marcado ilimitado y no hay top-ups vigentes. Copy propio — NO comparte el
  # mensaje del límite agotado.
  defp error_details({:budget_exceeded, %{layer: :no_credit}}),
    do:
      {402, "billing_error", "no_credit",
       "No spending path: no monthly limit, not marked unlimited and no active top-ups"}

  defp error_details({:budget_exceeded, _}),
    do: {402, "billing_error", "budget_exceeded", "Budget exceeded"}

  defp error_details(:model_not_found),
    do: {404, "invalid_request_error", "model_not_found", "Model not found or not accessible"}

  # ── SmartRouter alias ──────────────────────────────────────────────────
  # The kill switch and the subject's opt-in are distinct refusals: an operator
  # turned the router off vs this key's group/service never enabled it.
  defp error_details(:router_disabled),
    do:
      {503, "service_unavailable", "router_disabled",
       "The smart router is disabled on this gateway"}

  defp error_details(:router_access_disabled),
    do:
      {403, "permission_error", "router_access_disabled",
       "The smart router is not enabled for this account"}

  # The engine found no servable destination: no viable use case, or every model
  # of the chain lost its lanes. Nothing was served — a 503 with its own code,
  # never a silent 404 that looks like a typo in the model name.
  defp error_details(:router_no_candidates),
    do:
      {503, "service_unavailable", "router_no_candidates",
       "No router destination can serve this request"}

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

  # A lane without an upstream model id never left the gateway: the client's
  # body is fine, the row is not. It gets the gateway's OWN code (never the
  # `model: null` 400 an upstream would answer) and the same 503 family as
  # "no provider can serve this model" — the request cannot be retried into
  # success until an operator fixes the lane.
  defp error_details({:upstream_error, :lane_not_servable, _status}),
    do:
      {503, "service_unavailable", "lane_not_servable",
       "The model's lane has no upstream model id configured"}

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
