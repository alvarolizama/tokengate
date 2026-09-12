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
  403 when the membership is not active.
  """
  import Plug.Conn
  alias Tokengate.Accounts
  alias Tokengate.Accounts.GroupMember
  alias Tokengate.Repo

  def init(opts), do: opts

  def call(conn, _opts) do
    with [token] <- bearer_token(conn),
         {:ok, entry} <- fetch_auth_entry(token),
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
  # populate the cache. Invalid keys are never cached.
  defp fetch_auth_entry(token) do
    case Accounts.resolve_auth_by_api_key(token) do
      %{member: %GroupMember{}} = entry -> {:ok, entry}
      :error -> :invalid_key
    end
  end

  @doc """
  Converts a Service into a virtual GroupMember struct.
  This allows the proxy controller to handle services without changes.
  The virtual member carries the service's real group, so routing,
  provider exclusives and the (model_id, group_id) cache apply to
  services exactly like to user members.
  """
  def service_to_virtual_member(service) do
    service = Repo.preload(service, [:api_key, :group])

    %GroupMember{
      # Use service_id as a pseudo group_member_id for budget tracking
      id: service.id,
      group_id: service.group_id,
      user_id: nil,
      extra_monthly_budget_usd: nil,
      extra_concurrency: nil,
      extra_rpm: nil,
      status: "active",
      service_name: service.name,
      # Preloaded associations (virtual)
      group: service.group,
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
