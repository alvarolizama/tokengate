defmodule TokengateWeb.AuditExportController do
  @moduledoc """
  CSV export for the audit log viewer (`/operations/audit/export`).

  Admin-only (the route runs behind the `:admin_auth` pipeline). Accepts the
  same filters as the viewer: `actor_email`, `entity_type`, `action`,
  `target_label`, `ip`, `from`, `to`.
  """

  use TokengateWeb, :controller

  alias Tokengate.Auditing
  alias Tokengate.Repo
  alias TokengateWeb.TimezoneHelper

  @header [
    "inserted_at",
    "actor_email",
    "actor_role",
    "acting_as_email",
    "action",
    "entity_type",
    "entity_id",
    "target_label",
    "origin",
    "ip",
    "user_agent",
    "changes"
  ]

  def export(conn, params) do
    user = conn.assigns[:current_user]
    timezone = (user && user.timezone) || "Etc/UTC"
    query = Auditing.audit_logs_query(parse_filters(params, timezone))

    conn =
      conn
      |> put_resp_content_type("text/csv", "utf-8")
      |> put_resp_header("content-disposition", "attachment; filename=\"auditoria.csv\"")
      |> send_chunked(200)

    header_line = Enum.map_join(@header, ",", &escape/1) <> "\n"

    {:ok, conn} =
      case chunk(conn, header_line) do
        {:ok, conn} ->
          Repo.transaction(
            fn ->
              query
              |> Repo.stream(max_rows: 500)
              |> Stream.map(&row_line/1)
              |> Stream.chunk_every(200)
              |> Enum.reduce_while(conn, fn lines, acc_conn ->
                case chunk(acc_conn, Enum.join(lines, "\n") <> "\n") do
                  {:ok, next_conn} -> {:cont, next_conn}
                  {:error, _reason} -> {:halt, acc_conn}
                end
              end)
            end,
            timeout: :infinity
          )

        {:error, _reason} ->
          {:ok, conn}
      end

    conn
  end

  defp parse_filters(params, timezone) do
    params
    |> Map.take(~w(actor_email entity_type action target_label ip q))
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
    |> put_from(params["from"], timezone)
    |> put_to(params["to"], timezone)
  end

  defp put_from(filters, value, timezone) do
    with v when v not in [nil, ""] <- value,
         %DateTime{} = dt <- TimezoneHelper.parse_local_date(v, timezone, :start_of_day) do
      Map.put(filters, :from, dt)
    else
      _ -> filters
    end
  end

  defp put_to(filters, value, timezone) do
    with v when v not in [nil, ""] <- value,
         {:ok, date} <- Date.from_iso8601(v),
         %DateTime{} = dt <-
           TimezoneHelper.local_time_to_utc(Date.add(date, 1), ~T[00:00:00], timezone) do
      Map.put(filters, :to, dt)
    else
      _ -> filters
    end
  end

  defp row_line(log) do
    [
      to_iso(log.inserted_at),
      log.actor_email,
      log.actor_role,
      log.acting_as_email,
      log.action,
      log.entity_type,
      log.entity_id,
      log.target_label,
      log.origin,
      log.ip,
      log.user_agent,
      encode_changes(log.changes)
    ]
    |> Enum.map_join(",", &escape/1)
  end

  defp to_iso(nil), do: nil
  defp to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp encode_changes(changes) when changes in [nil, %{}], do: nil
  defp encode_changes(changes), do: Jason.encode!(changes)

  # El escape vive en `TokengateWeb.CSV` (una sola implementación compartida con
  # el export de stats). Antes esta copia solo citaba comas y comillas: los
  # campos que manda el cliente (`user_agent`, `origin`, `target_label`) podían
  # empezar con `=` y el spreadsheet los evaluaba al abrir el archivo.
  defp escape(value), do: TokengateWeb.CSV.escape(value)
end
