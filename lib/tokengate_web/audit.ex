defmodule TokengateWeb.Audit do
  @moduledoc """
  Web-facing helper to record audit entries with request context.

  Resolves the actor, impersonator, peer IP and user-agent from the
  LiveView socket or the `Plug.Conn`, so call sites only name the action:

      audit(socket, "model.create", "model", model.id, %{"name" => model.name})

  The actor is always taken from the socket/conn assign `:current_user`
  (the impersonated user during an impersonation session); the admin behind
  it comes from `:impersonator`.
  """

  alias Tokengate.Auditing

  @doc """
  Records an audit entry from a LiveView socket.

  The **actor is the responsible human**: the admin (`socket.assigns.impersonator`)
  when the session is impersonating, otherwise the signed-in user. The
  impersonated user (if any) is stored as "acting as". IP and user-agent come
  from the socket's connect info (configured in `TokengateWeb.Endpoint`).
  """
  def audit(socket, action, entity_type, entity_id, changes \\ %{}) do
    {actor, acting_as} =
      resolve_actor(socket.assigns[:impersonator], socket.assigns[:current_user])

    Auditing.log(
      actor,
      action,
      entity_type,
      entity_id,
      changes,
      socket_ctx(socket, changes, acting_as)
    )
  end

  @doc """
  Records an audit entry from a `Plug.Conn` with an explicit actor.

  Used by controllers (e.g. `SessionController`) where the actor is not
  necessarily `conn.assigns.current_user` (an admin acting on someone else).
  When an impersonation session is active, the impersonator is the actor and
  the current user becomes "acting as".
  """
  def audit_conn(conn, actor, action, entity_type, entity_id, changes \\ %{}) do
    {actor, acting_as} =
      case conn.assigns[:impersonator] do
        nil -> {actor || conn.assigns[:current_user], nil}
        admin -> {admin, conn.assigns[:current_user]}
      end

    Auditing.log(
      actor,
      action,
      entity_type,
      entity_id,
      changes,
      conn_ctx(conn, changes, acting_as)
    )
  end

  # ---------------------------------------------------------------------------

  # No impersonation: the actor is the signed-in (or explicitly passed) user.
  # Impersonation: the admin is the responsible actor; the impersonated user
  # is what they were "acting as".
  defp resolve_actor(nil, actor), do: {actor, nil}
  defp resolve_actor(admin, acting_as), do: {admin, acting_as}

  defp socket_ctx(socket, changes, acting_as) do
    %{
      acting_as: acting_as,
      origin: "web",
      ip: socket |> connect_info(:peer_data) |> peer_ip(),
      user_agent: connect_info(socket, :user_agent),
      target_label: label(changes)
    }
  end

  defp conn_ctx(conn, changes, acting_as) do
    %{
      acting_as: acting_as,
      origin: "web",
      ip: forwarded_ip(conn),
      user_agent: first_header(conn, "user-agent"),
      target_label: label(changes)
    }
  end

  # `get_connect_info/2` is only valid on a connected socket; on a
  # disconnected mount (or when the key isn't configured) it raises/returns
  # nil — an audit entry is never worth crashing a render.
  defp connect_info(socket, key) do
    Phoenix.LiveView.get_connect_info(socket, key)
  rescue
    _ -> nil
  end

  defp peer_ip(%{address: address}) when is_tuple(address),
    do: address |> :inet.ntoa() |> to_string()

  defp peer_ip(_), do: nil

  defp forwarded_ip(conn) do
    case first_header(conn, "x-forwarded-for") do
      nil ->
        case conn.remote_ip do
          nil -> nil
          ip -> ip |> :inet.ntoa() |> to_string()
        end

      forwarded ->
        forwarded |> String.split(",") |> List.first() |> String.trim()
    end
  end

  defp first_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  # Derives a human label for the target entity from common change keys.
  defp label(changes) when is_map(changes) do
    changes["email"] || changes["name"] || changes["label"] ||
      changes[:email] || changes[:name] || changes[:label]
  end

  defp label(_), do: nil
end
