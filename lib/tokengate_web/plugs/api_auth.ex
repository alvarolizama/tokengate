defmodule TokengateWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates proxy API requests via `Authorization: Bearer ***

  On success assigns:

    * `:current_group_member` — the GroupMember (group, user, api_key preloaded)
      OR a virtual GroupMember struct when the key belongs to a Service.
    * `:api_key_hash` — sha256 hex of the presented token (sticky routing key)
    * `:agent_type` — from the `X-Agent-Type` header (default `"unknown"`)

  Agent identification headers (OpenRouter-style): `X-Agent-Type`,
  `X-Title`, `HTTP-Referer`. Only the agent type is enforced; the rest are
  informational and available in `conn.req_headers`.

  Responds 401 (OpenAI-style error JSON) when the key is missing/invalid,
  403 when the membership is not active, 429 when the source IP blew through
  the invalid-key budget.

  ## Rate limit por IP (auditoría medio)

  `ProxyPreAuth` ya corta los tokens con formato inválido antes de leer el
  body, pero un token **bien formado y falso** (`tg-…` inventado) llega hasta
  aquí y paga dos queries a Postgres por intento: `resolve_auth_by_api_key/1`
  no cachea los fallos a propósito (un hit negativo cacheado dejaría fuera una
  key recién creada). Sin tope, un solo cliente puede martillar el pool con
  basura y arrastrar al proxy legítimo.

  El cubo es el ETS de `LoginRateLimit.TableKeeper` (la tabla ya existe y se
  barre sola), con llave `{:api_auth_ip, ip}` — separada de los cubos de login
  para no mezclar ventanas. Sólo se cuenta el intento FALLIDO: una key válida
  nunca toca este cubo (cero overhead y cero riesgo de bloquear al cliente
  bueno).
  """
  import Plug.Conn

  require Logger

  alias Tokengate.Accounts
  alias Tokengate.Accounts.GroupMember
  alias Tokengate.Repo
  alias TokengateWeb.Plugs.LoginRateLimit

  # Ventana de 60s y 30 tokens inválidos por IP: un cliente con una key mal
  # copiada reintenta un puñado de veces; 30/min deja aire para eso y para un
  # NAT corporativo con varios usuarios, sin permitir un scan sostenido.
  @invalid_window_ms 60_000
  @invalid_max_per_ip 30

  def init(opts), do: opts

  def call(conn, _opts) do
    with [token] <- bearer_token(conn),
         {:ok, entry} <- fetch_auth_entry(conn, token),
         :ok <- active_membership(entry.member) do
      conn
      |> assign(:current_group_member, entry.member)
      |> assign(:subject_type, entry.subject_type)
      |> assign(:effective_limits, entry.limits)
      |> assign(:api_key_hash, Accounts.hash_api_key(token))
      |> assign(:agent_type, agent_type(conn))
      |> assign(:client_agent, client_agent(conn))
    else
      :no_token -> reject(conn, 401, "missing_api_key", "Missing bearer token")
      :invalid_key -> reject(conn, 401, "invalid_api_key", "Invalid API key")
      {:rate_limited, retry_after_s} -> too_many_attempts(conn, retry_after_s)
      :inactive -> reject(conn, 403, "membership_inactive", "Group membership is not active")
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 -> [token]
      _ -> :no_token
    end
  end

  # Resolved through the ETS auth cache (`Accounts.resolve_auth_by_api_key/1`):
  # hits skip Postgres entirely; misses run the two lookup queries once and
  # populate the cache. Invalid keys are never cached — the failure path is
  # therefore the one that needs the IP budget.
  defp fetch_auth_entry(conn, token) do
    case Accounts.resolve_auth_by_api_key(token) do
      %{member: %GroupMember{}} = entry -> {:ok, entry}
      :error -> invalid_key_gate(conn)
    end
  end

  # Reusa el cubo ETS del login (`LoginRateLimit.TableKeeper`, tabla pública,
  # ventana propia): sólo se llega aquí cuando la key NO resolvió, así que una
  # key válida nunca consume presupuesto ni paga una lectura ETS extra.
  defp invalid_key_gate(conn) do
    case LoginRateLimit.TableKeeper.hit(
           api_auth_bucket(conn),
           invalid_window_ms(),
           invalid_max_per_ip()
         ) do
      {:allow, _count} ->
        :invalid_key

      {:deny, retry_after_s} ->
        Logger.warning(
          "api_auth_rate_limited ip=#{inspect(remote_ip(conn))} retry_after=#{retry_after_s}s"
        )

        {:rate_limited, retry_after_s}
    end
  end

  defp api_auth_bucket(conn), do: {:api_auth_ip, remote_ip(conn)}

  defp remote_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp invalid_window_ms,
    do: Application.get_env(:tokengate, :api_auth_invalid_window_ms, @invalid_window_ms)

  defp invalid_max_per_ip,
    do: Application.get_env(:tokengate, :api_auth_invalid_max_per_ip, @invalid_max_per_ip)

  defp too_many_attempts(conn, retry_after_s) do
    body = %{
      "error" => %{
        "message" => "Too many invalid API key attempts. Retry later.",
        "type" => "rate_limit_error",
        "code" => "rate_limited"
      }
    }

    conn
    |> put_resp_header("retry-after", to_string(retry_after_s))
    |> put_resp_content_type("application/json")
    |> send_resp(429, Jason.encode!(body))
    |> halt()
  end

  @doc """
  Converts a Service into a virtual GroupMember struct.
  This allows the proxy controller to handle services without changes.
  The virtual member no longer carries a group: a service owns its monthly
  spend limit, its top-ups and its model catalog directly, so routing
  providers/model access for services is resolved without group scope.
  """
  def service_to_virtual_member(service) do
    service = Repo.preload(service, [:api_key])

    %GroupMember{
      # Use service_id as a pseudo group_member_id for budget tracking
      id: service.id,
      group_id: nil,
      user_id: nil,
      status: "active",
      service_name: service.name,
      # Preloaded associations (virtual)
      group: nil,
      user: nil,
      api_key: service.api_key
    }
  end

  defp active_membership(%{status: "active"}), do: :ok
  defp active_membership(_), do: :inactive

  defp agent_type(conn) do
    case get_req_header(conn, "x-agent-type") do
      [type | _] when byte_size(type) > 0 -> String.slice(type, 0, 255)
      _ -> "unknown"
    end
  end

  @doc """
  Resolves the best human-readable client identity from request headers.

  Priority: `X-Title` → `User-Agent` → `X-Agent-Type` → `"unknown"`.
  The result is truncated to 255 chars for storage.
  """
  def client_agent(conn) do
    with :error <- first_header(conn, "x-title"),
         :error <- first_header(conn, "user-agent"),
         :error <- first_header(conn, "x-agent-type") do
      "unknown"
    end
  end

  defp first_header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] when byte_size(value) > 0 -> String.slice(value, 0, 255)
      _ -> :error
    end
  end

  defp reject(conn, status, code, message) do
    body = %{
      "error" => %{
        "message" => message,
        "type" => "authentication_error",
        "code" => code
      }
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
