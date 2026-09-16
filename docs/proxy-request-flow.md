# Flujo de una petición en el proxy de TokenGate

Referencia de código: `main` @ `61e6610`.
Todo lo que aparece aquí sale del código; los números de línea son del estado actual del repo.

| Fuente | Qué define |
| --- | --- |
| `lib/tokengate_web/router.ex:34,162` | pipeline `:proxy_api` y scope `/v1` |
| `lib/tokengate_web/plugs/api_auth.ex:26` | auth por bearer + assigns de la request |
| `lib/tokengate_web/controllers/proxy_controller.ex` | pipeline completo, cascada, matriz de fallback |
| `lib/tokengate/routing/router.ex:99` | resolución de modelo → credencial |
| `lib/tokengate/routing/priority.ex:34` | orden por salud+prioridad y sticky |
| `lib/tokengate/routing/circuit_breaker.ex` | breaker por credencial |
| `lib/tokengate/limits/manager.ex:140` | las dos puertas de throttling |

> **No hay motor de reglas.** La tabla `routing_rules` fue eliminada
> (`priv/repo/migrations/20260726222126_remove_routing_rules.exs`). El comportamiento
> es determinista y vive en código: accesos, scope, salud, prioridad y breaker.

---

## 1. Recorrido punto a punto

```mermaid
flowchart TD
    A["Cliente<br/>POST /v1/chat/completions"] --> B["pipeline :proxy_api<br/>accepts json + ApiAuth"]

    B --> C{"Bearer token<br/>válido y activo?"}
    C -->|"sin token"| C1["401 missing_api_key"]
    C -->|"inválido"| C2["401 invalid_api_key"]
    C -->|"membresía inactiva"| C3["403 membership_inactive"]
    C -->|"sí"| D["assigns: current_group_member,<br/>api_key_hash, agent_type,<br/>client_agent, effective_limits"]

    D --> P1["Reasoning.parse → think / effort"]
    P1 --> P2["SessionId.derive → session_key<br/>x-session-id | prompt_cache_key | hash del arranque"]
    P2 --> P3["affinity_key = session_key || api_key_hash"]
    P3 --> P4["idempotency_key = UUID()<br/>mismo para todos los intentos"]
    P4 --> P5{"model presente<br/>y es string?"}
    P5 -->|"no"| E400["400 invalid_request"]

    P5 -->|"sí"| G1["Puerta 1 — grupo/miembro<br/>Limits.acquire(api_key_id):<br/>RPM ventana deslizante 2 buckets + concurrencia"]
    G1 --> G2{"pasa?"}
    G2 -->|"rate_limited"| E429["429 rate_limited<br/>Retry-After"]
    G2 -->|"concurrency_exceeded"| E429b["429 concurrency_exceeded"]
    G2 -->|"sí"| ROUTE["route_and_acquire<br/>(cascada, ver diagrama 2 y 3)"]

    ROUTE --> R1{"Router.route<br/>resolvió candidato?"}
    R1 -->|"model_not_found"| E404["404 model_not_found"]
    R1 -->|"model_type_mismatch"| E400b["400 model_type_mismatch"]
    R1 -->|"no_providers_configured"| E503a["503 no_providers"]
    R1 -->|"no_available_provider"| E503b["503 no_available_provider"]
    R1 -->|"cascade_exhausted"| E429c["429 provider_concurrency_exceeded<br/>o 503 cascade_exhausted"]

    R1 -->|"ok"| G3["Puerta 2 — proveedor<br/>global: max_rpm + max_concurrent<br/>por usuario: max_concurrent_per_user"]
    G3 --> G4{"pasa?"}
    G4 -->|"saturada / rate limited"| BACK["excluir credencial<br/>(sleep acotado a 2s si 429)<br/>reintentar cascada"]
    BACK --> ROUTE
    G4 -->|"sí"| BUD["reserve_credit_budget<br/>hold de max_request_cost_usd = 1 USD<br/>+ kill-switch global diario"]
    BUD --> BUD2{"hold concedido?"}
    BUD2 -->|"no"| E402["402 budget_exceeded<br/>global | subject | credit"]
    BUD2 -->|"sí"| INF["register_inflight<br/>visible como Pending en /logs"]

    INF --> K{"endpoint y stream?"}
    K -->|"chat + stream true"| EXS["execute_stream<br/>SSE, fallback antes del primer chunk"]
    K -->|"chat + stream false"| EXN["execute<br/>JSON, cache de respuesta local"]
    K -->|"embeddings"| EXE["execute_simple<br/>passthrough, adapter por dialecto"]

    EXS --> MAT["Matriz de fallback por intento<br/>(diagrama 3)"]
    EXN --> MAT
    EXE --> MAT

    MAT -->|"éxito upstream"| FIN["finalize: usage normalizado,<br/>costo, Collector.record_request,<br/>enqueue_log vía Oban,<br/>x-tokengate-cost, cache_store"]
    MAT -->|"intentos agotados o error no recuperable"| ERRF["log_and_render_*_error"]

    FIN --> SETTLE["after: settle_budget<br/>Inflight.finish_request<br/>release_credential_limits<br/>Limits.release"]
    ERRF --> SETTLE

    SETTLE --> RESP["Respuesta al cliente"]
```

---

## 2. Resolución de modelo → credencial

```mermaid
flowchart TD
    A["Router.route(model_name, member, ctx)"] --> B["Providers.list_accessible_models(member)<br/>grants de grupo + extras del miembro"]
    B --> C{"alias encontrado?"}
    C -->|"no"| C1["{:error, :model_not_found}"]
    C -->|"sí"| D{"model_type == capability?<br/>llm | embedding"}
    D -->|"no"| D1["{:error, :model_type_mismatch}"]

    D -->|"sí"| E{"¿miembro de servicio?"}
    E -->|"sí"| F1["list_model_providers_for_service<br/>global + exclusivas del servicio"]
    E -->|"no, con grupo"| F2["list_model_providers_for_member<br/>cache ETS 60s por model_id + group_id"]
    E -->|"otro"| F3["list_model_providers(model_id)"]

    F1 --> G{"candidatos == []?"}
    F2 --> G
    F3 --> G
    G -->|"sí"| G1["{:error, :no_providers_configured}"]

    G -->|"no"| H["Filtros duros por candidato"]
    H --> H1["credential != nil"]
    H1 --> H2["credential.status == active"]
    H2 --> H3["credential.id ∉ set de deshabilitadas (cache 60s)"]
    H3 --> H4["credential.id ∉ exclude_credential_ids"]
    H4 --> H5["visible_to_member?<br/>global / grupo pasan, exclusiva solo a su dueño"]
    H5 --> I{"candidatos == []?"}
    I -->|"sí"| I1["{:error, :no_available_provider}"]
    I -->|"no"| J["inject_exclusive_priority<br/>exclusivas pasan a priority = -1"]

    J --> K["Priority.select(candidates, %{api_key_hash, model_id, available? = breaker.allow?})"]
    K --> L["sort estable por {health, priority}<br/>0 sano, 1 degradado (lento)<br/>priority ASC NULLS LAST<br/>el billing surface NO rankea"]
    L --> M{"sticky hit para<br/>(api_key_hash, model_id)?"}
    M -->|"no"| N["elegir el primer candidato con available? = true"]
    M -->|"sí, y no degradado"| N1["devolver la pegada<br/>preserva prompt cache"]
    M -->|"sí, pero degradada"| N2["soltar el stick<br/>y elegir por salud+prioridad"]
    N --> O["sticky_put con TTL<br/>model_provider.sticky_ttl_ms o 3 min"]
    N2 --> O
    O --> P["route: %{model, model_provider,<br/>credential, model_responded}"]
    N1 --> P
    N -->|"ningún candidato con available? = true"| Q1["{:error, :no_available_provider}"]
    N2 -->|"ningún candidato con available? = true"| Q1
    Q1 --> Q2["la cascada del controlador lo trata<br/>como cascada agotada / all_providers_down"]
```

**Salud blanda** (`Routing.CredentialHealth`): un éxito más lento que
`ROUTING_SLOW_THRESHOLD_MS` (30s) marca la credencial como degradada durante
`ROUTING_SLOW_PENALTY_MS` (120s). No sale de rotación: se hunde al fondo de su tier.

---

## 3. Matriz de fallback, intento por intento

`@max_attempts = 9`, `@max_retries_per_provider = 3`, `@max_route_retries = 20`.

```mermaid
flowchart TD
    A["Intento upstream con el adapter del dialecto"] --> B["¿resultado?"]

    B -->|":ok"| S1["Router.record_outcome(:success, latency_ms)<br/>breaker → record_success<br/>CredentialHealth → rápido sana / lento degrada"]
    S1 --> S2["finalize: costo, headers, log, cache"]

    B -->|":auth_error 401/402/403"| A1["disable_credential_async<br/>status = error + alerta PubSub"]
    A1 --> A2["breaker: NO cuenta"]
    A2 --> A3["excluir credencial de inmediato<br/>sin retry en el mismo proveedor"]
    A3 --> NEXT

    B -->|":timeout o first_token_timeout"| T1["breaker: SÍ cuenta"]
    T1 --> T2["excluir de inmediato<br/>un proveedor colgado no revive en ms"]
    T2 --> NEXT

    B -->|":bad_request 400"| B1["breaker: NO cuenta<br/>no es señal de salud de la credencial"]
    B1 --> B2["excluir de inmediato<br/>el mismo body da el mismo 400"]
    B2 --> NEXT

    B -->|":client_error 4xx distinto de 400"| C1["breaker: NO cuenta"]
    C1 --> C2["SIN fallback: se devuelve el 4xx upstream<br/>culpa del payload, idéntico en todo proveedor"]

    B -->|"5xx / 429 / connection_error"| F1["breaker: SÍ cuenta"]
    F1 --> F2{"provider_retries < 3?"}
    F2 -->|"sí"| F3["retry en el MISMO proveedor<br/>provider_retries + 1"]
    F2 -->|"no"| F4["excluir credencial, provider_retries = 0"]
    F3 --> A
    F4 --> NEXT

    NEXT{"attempts_left > 1?"}
    NEXT -->|"no"| E1["render del último error<br/>upstream_error / client_error / all_providers_down"]
    NEXT -->|"sí"| RR["Router.route con exclude_credential_ids"]
    RR -->|"ok"| A
    RR -->|"no_available_provider y fue 400"| E2["se propaga el 4xx real<br/>no un 503 enmascarado"]
    RR -->|"no_available_provider"| E3["503 all_providers_down"]
    RR -->|"otro error"| E4["render del error"]
```

Reglas transversales del camino de fallback:

- **Timeout de recepción**: `provider.receive_timeout_ms` o `PROXY_RECEIVE_TIMEOUT_MS`
  (120s) — los límites viven en el proveedor y cada API key los hereda.
- **Streaming**: idéntica matriz, pero aplicada **antes** del primer chunk. El 200 no se
  compromete hasta que llega contenido real; `stream_options.include_usage` se fuerza como
  única mutación de payload sancionada.
- **Fallo mid-stream**: sin fallback. El 200 ya está emitido, se cierra el stream y se
  registra lo consumido (`proxy_controller.ex:1540`).
- **Backoff de rate limit en la cascada**: `min(retry_ms, 2_000)` para que un proveedor con
  ventana larga no estanque la request.
- **Cache de respuesta local** (solo chat no-streaming y embeddings): peticiones idénticas
  se sirven de ETS con `x-tokengate-cache: hit` y costo $0.

---

## 4. Circuit breaker por credencial

```mermaid
stateDiagram-v2
    [*] --> closed

    closed: closed (pasan las peticiones)
    open: open (se rechaza allow?)
    half_open: half_open (una sola sonda)

    closed --> closed: éxito → contador de fallos a 0
    closed --> open: 5 fallos consecutivos
    open --> half_open: cooldown cumplido
    open --> open: fallo tardío refresca cooldown
    half_open --> closed: la sonda responde bien
    half_open --> open: la sonda falla (cooldown nuevo)

    note right of open
        Cooldown 60 s por defecto.
        Si el trip fue por rate_limited: 10 s.
        Mientras está open, allow? devuelve false
        y el router lo descarta como candidato.
    end note

    note left of closed
        Cuentan: server_error, timeout, rate_limited.
        NUNCA cuentan: auth_error (se desactiva
        la credencial en DB), bad_request y
        client_error (son culpa del payload).
    end note
```

---

## 5. Streaming: fallback antes del primer token

```mermaid
sequenceDiagram
    autonumber
    participant C as Cliente
    participant G as TokenGate
    participant P1 as Credencial A
    participant P2 as Credencial B

    C->>G: POST /v1/chat/completions (stream true)
    G->>G: puertas, routing, hold de crédito, inflight
    G->>P1: adapter.stream_chat_completion
    Note over G,P1: nada se envía al cliente todavía
    P1--xG: timeout de primer token (30 s)
    G->>G: breaker cuenta timeout, credencial A excluida
    G->>G: Router.route con exclude = [A]
    G->>P2: adapter.stream_chat_completion (mismo idempotency-key)
    P2-->>G: primer chunk
    G->>G: record_outcome(:success, ttft)
    G-->>C: 200 text/event-stream + cache-control no-cache
    loop cada chunk
        P2-->>G: chunk SSE
        G-->>C: data: chunk
    end
    P2-->>G: chunk final con usage
    G->>G: inyecta costo, captura usage
    G->>G: finish_stream: data: [DONE], Collector, log, Process.put(costo)
    G-->>C: data: [DONE]
    Note over G: after → settle_budget,<br/>release de la puerta 1 y 2
```

Si el fallo ocurre **después** del primer chunk, no hay segundo proveedor: se cierra el
stream y se factura lo recibido.

---

## 6. Códigos de salida

| Situación | HTTP | `code` |
| --- | --- | --- |
| Sin token / token inválido | 401 | `missing_api_key`, `invalid_api_key` |
| Membresía inactiva | 403 | `membership_inactive` |
| Body inválido, `model` ausente, tipo equivocado | 400 | `invalid_request`, `model_type_mismatch` |
| RPM o concurrencia de miembro | 429 | `rate_limited`, `concurrency_exceeded` |
| Credencial saturada / rate limited | 429 | `provider_concurrency_exceeded`, `provider_rate_limited` |
| Cascada agotada por saturación | 429 | `provider_concurrency_exceeded` |
| Cascada agotada por otra causa | 503 | `cascade_exhausted` |
| Kill-switch global, presupuesto o crédito | 402 | `budget_exceeded` |
| Modelo inexistente o sin grant | 404 | `model_not_found` |
| Modelo sin credenciales / sin candidatas | 503 | `no_providers`, `no_available_provider` |
| Todos los proveedores fallaron | 503 | `all_providers_down` |
| 4xx del payload rechazado por el proveedor | el status real | `upstream_client_error` |
| Error del proveedor (5xx/timeout) | status mapeado | `server_error`, `timeout`, `rate_limited` |

En 429 solo se emite `Retry-After` (segundos, redondeado hacia arriba) para
`rate_limited` y `provider_rate_limited`; los códigos de saturación
(`concurrency_exceeded`, `provider_concurrency_exceeded`) y `cascade_exhausted` **no** lo
llevan (`proxy_controller.ex:2066`). En éxito se emite `X-Tokengate-Cost` y, en aciertos
de caché local, `X-Tokengate-Cache: hit`. El objeto `usage` de la respuesta gana
`cost_usd` (costo real del proveedor).

> **Documentación desactualizada en el código**: el `@moduledoc` de
> `ProxyController` (líneas 5-13) afirma que el `usage` gana también
> `estimated_cost_usd` y que se emite `X-Tokengate-Savings`. Ninguna de las dos existe
> en el código actual: solo se inyecta `cost_usd` (`proxy_controller.ex:1771`) y solo se
> emiten `x-tokengate-cost` y `x-tokengate-cache`. El `README.md` también menciona cosas
> que ya no están: la "FIFO queue" (hoy hay fallback inmediato, `proxy_controller.ex:678`)
> y el "daily spending cap per credential" (hoy no existe; solo el cap global diario).
