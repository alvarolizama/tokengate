defmodule TokengateWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates proxy API requests via `Authorization: Bearer <api_key>`.

  On success assigns:

    * `:current_team_member` — the TeamMember (team, user, api_key preloaded)
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

  def init(opts), do: opts

  def call(conn, _opts) do
    with [token] <- bearer_token(conn),
         {:ok, team_member} <- fetch_member(token),
         :ok <- active_membership(team_member) do
      conn
      |> assign(:current_team_member, team_member)
      |> assign(:api_key_hash, Accounts.hash_api_key(token))
      |> assign(:agent_type, agent_type(conn))
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

  defp fetch_member(token) when is_binary(token) do
    case Accounts.get_team_member_by_api_key(token) do
      {:ok, %Accounts.TeamMember{} = member} -> {:ok, member}
      _ -> :invalid_key
    end
  end

  defp active_membership(%{status: "active"}), do: :ok
  defp active_membership(_), do: :inactive

  defp agent_type(conn) do
    case get_req_header(conn, "x-agent-type") do
      [type | _] when byte_size(type) > 0 -> type
      _ -> "unknown"
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
