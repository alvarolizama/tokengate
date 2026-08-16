defmodule TokengateWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates proxy API requests via `Authorization: Bearer ***

  On success assigns:

    * `:current_team_member` — the TeamMember (team, user, api_key preloaded)
      OR a virtual TeamMember struct when the key belongs to a Service.
    * `:api_key_hash` — sha256 hex of the presented token (sticky routing key)
    * `:agent_type` — from the `X-Agent-Type` header (default `"unknown"`)

  Agent identification headers (OpenRouter-style): `X-Agent-Type`,
  `X-Title`, `HTTP-Referer`. Only the agent type is enforced; the rest are
  informational and available in `conn.req_headers`.

  Responds 401 (OpenAI-style error JSON) when the key is missing/invalid,
  403 when the membership is not active.
  """
  import Plug.Conn

  alias Tokengate.Accounts
  alias Tokengate.Accounts.TeamMember
  alias Tokengate.Repo

  def init(opts), do: opts

  def call(conn, _opts) do
    with [token] <- bearer_token(conn),
         {:ok, entry} <- fetch_auth_entry(token),
         :ok <- active_membership(entry.member) do
      conn
      |> assign(:current_team_member, entry.member)
      |> assign(:effective_limits, entry.limits)
      |> assign(:api_key_hash, Accounts.hash_api_key(token))
      |> assign(:agent_type, agent_type(conn))
      |> assign(:client_agent, client_agent(conn))
    else
      :no_token -> reject(conn, 401, "missing_api_key", "Missing bearer token")
      :invalid_key -> reject(conn, 401, "invalid_api_key", "Invalid API key")
      :inactive -> reject(conn, 403, "membership_inactive", "Team membership is not active")
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
  # populate the cache. Invalid keys are never cached.
  defp fetch_auth_entry(token) do
    case Accounts.resolve_auth_by_api_key(token) do
      %{member: %TeamMember{}} = entry -> {:ok, entry}
      :error -> :invalid_key
    end
  end

  @doc """
  Converts a Service into a virtual TeamMember struct.
  This allows the proxy controller to handle services without changes.
  """
  def service_to_virtual_member(service) do
    service = Repo.preload(service, [:api_key])

    %TeamMember{
      # Use service_id as a pseudo team_member_id for budget tracking
      id: service.id,
      team_id: nil,
      user_id: nil,
      team_role: "user",
      extra_monthly_budget_usd: nil,
      extra_concurrency: nil,
      extra_rpm: nil,
      status: "active",
      # Preloaded associations (virtual)
      team: nil,
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
