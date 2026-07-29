# Plan: Concurrency fallback — saltar a la siguiente credential en lugar de bloquear

## Contexto

Actualmente, cuando una credential llega a su `max_concurrent` (concurrencia de 3), la 4ta petición se bloquea con `429 provider_concurrency_exceeded` — **incluso si hay otras credentials del mismo modelo con capacidad disponible**. 

El objetivo: en lugar de bloquear, intentar la siguiente credential por prioridad. Solo bloquear si **ninguna** credential del modelo tiene capacidad.

## Flujo actual (rastreado)

```
proxy_controller.ex:75  route_and_check → Router.route (elige credential por prioridad)
proxy_controller.ex:78  acquire_credential_limits → Limits.acquire
                          └→ manager.ex:89 acquire_concurrency
                          └→ si new_value > limit → {:error, :concurrency_exceeded}
proxy_controller.ex:93  {:error, error} → log_and_render_proxy_error → 429
```

El problema: `acquire_credential_limits` se ejecuta **después** de que el router ya eligió una sola credential. Si esa credential está saturada, no hay retry — se devuelve 429 directo.

## Flujo deseado

```
Router.route (elige credential por prioridad)
  → acquire_credential_limits
    → si pasa → ejecutar
    → si concurrency_exceeded → re-routear EXCLUYENDO esa credential
      → si hay otra credential disponible → acquire + ejecutar
      → si no hay más → 429 (como antes)
```

## Cambios

### 1. `proxy_controller.ex` — loop de route + acquire con fallback por concurrencia

**Archivo**: `lib/tokengate_web/controllers/proxy_controller.ex`

Cambiar el bloque de líneas 75-98 (el `case route_and_check` + `acquire_credential_limits`) por un loop que:

1. Routea obteniendo una credential
2. Intenta `acquire_credential_limits`
3. Si falla con `:concurrency_exceeded` o `:provider_concurrency_exceeded`:
   - Excluye esa credential del pool
   - Re-routea (igual que `retry_with_fallback` pero por concurrencia, no por error)
4. Si no hay más credentials → devuelve el 429 original

**Implementación concreta**: extraer un `route_and_acquire/5` que hace el loop con `exclude_credential_ids`:

```elixir
defp route_and_acquire(member, payload, api_key_hash, limits, exclude \\ []) do
  request_context = %{
    "messages" => payload["messages"] || [],
    :api_key_hash => api_key_hash,
    :exclude_credential_ids => exclude
  }

  with {:ok, route} <- Router.route(payload["model"], member, request_context),
       :ok <- check_budget(member, limits, route, payload) do
    case acquire_credential_limits(route.credential) do
      :ok ->
        {:ok, route}

      {:error, :concurrency_exceeded} ->
        # Team concurrency — no fallback, es el límite del usuario
        {:error, :concurrency_exceeded}

      {:error, :provider_concurrency_exceeded} ->
        # Credential saturada — intentar la siguiente
        route_and_acquire(member, payload, api_key_hash, limits, [route.credential.id | exclude])
    end
  end
end
```

El caller (líneas 72-110) cambia de:
```elixir
case route_and_check(member, payload, ...) do
  {:ok, route} -> case acquire_credential_limits(route.credential) do ...
  {:error, error} -> ...
end
```
a:
```elixir
case route_and_acquire(member, payload, conn.assigns.api_key_hash, limits) do
  {:ok, route} -> register_inflight + execute/execute_stream
  {:error, error} -> log_and_render_gate_error
end
```

**Notas**:
- El budget check se corre por cada credential intentada — correcto, cada credential puede tener pricing distinto.
- El team concurrency limit (`:concurrency_exceeded`) **NO** hace fallback — es el límite del usuario, no del proveedor.
- Solo `:provider_concurrency_exceeded` hace fallback.
- El loop termina cuando `Router.route` devuelve `:no_available_provider` → se traduce a `:provider_concurrency_exceeded` para el 429.

### 2. Manejo del caso "no hay más credentials"

Cuando el loop excluye todas las credentials y `Router.route` devuelve `{:error, :no_available_provider}`, hay que traducirlo a `:provider_concurrency_exceeded` para que el usuario vea el mismo 429 de siempre:

```elixir
{:error, :no_available_provider} ->
  {:error, :provider_concurrency_exceeded}
```

### 3. Tests

**Archivo**: `test/tokengate_web/controllers/proxy_controller_test.exs`

- **Test 1**: "concurrency fallback: saturated credential falls back to second credential"
  - Credential A con `max_concurrent: 1`, credential B con `priority: 2`
  - Saturar credential A (adquirir el único slot)
  - Mandar petición → debe caer en credential B y devolver 200

- **Test 2**: "429 provider_concurrency_exceeded when all credentials are saturated"
  - Una sola credential con `max_concurrent: 1`, saturada
  - Mandar petición → 429 `provider_concurrency_exceeded`

- **Test 3** (modificar existente línea 321): "429 when team concurrency limit is exceeded"
  - Este ya existe y sigue funcionando igual — el team limit no hace fallback.

## Lo que NO cambia

- `Limits.Manager` — intacto, no se toca el ETS ni el acquire/release atómico
- `Router` — intacto, ya soporta `:exclude_credential_ids`
- `CircuitBreaker` — intacto, la concurrencia no es un error de breaker
- `Priority` — intacto, ya ordena por prioridad
- Team limits (`acquire_team_limits`) — siguen corriendo antes, sin fallback
- `execute/6` y `execute_stream/6` — intactos, el retry por error del proveedor ya funciona igual

## Riesgos

1. **Budget re-check por credential**: cada credential puede tener pricing distinto, así que el budget check se corre en cada intento. Si esto es costoso, se podría cachear el cheapest credential del pool, pero por ahora no lo es (es una query ETS + aritmética simple).

2. **Loop infinito**: el loop está acotado por el número de credentials del modelo. `Router.route` excluye las que ya intentamos, así que cuando se acaban devuelve `:no_available_provider`. No hay riesgo de loop infinito.

3. **Logging**: cada intento de credential debe registrarse como un log entry separado (o agruparse). Por simplicidad, solo se loguea el intento final (éxito o error), como ahora. Los intentos intermedios de concurrencia no generan log — son transparentes para el usuario.

4. **Sticky routing**: el sticky tracker ya maneja esto bien — si la credential sticky está saturada, el fallback la excluye y el router pega a la siguiente. El sticky se "re-sticka" a la nueva credential.
