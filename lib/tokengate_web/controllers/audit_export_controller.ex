defmodule TokengateWeb.AuditExportController do
  @moduledoc """
  CSV export for the audit log viewer (`/operations/audit/export`).

  Admin-only (the route runs behind the `:admin_auth` pipeline). Accepts the
  same filters as the viewer: `actor_email`, `entity_type`, `action`,
  `target_label`, `ip`, `from`, `to`.
  """

  use TokengateWeb, :controller

  alias Tokengate.Auditing

  @max_rows 1000

  def export(conn, params) do
    logs = Auditing.list_audit_logs(Map.merge(parse_filters(params), %{limit: @max_rows}))

    conn
    |> put_resp_content_type("text/csv", "utf-8")
    |> put_resp_header("content-disposition", "attachment; filename=\"auditoria.csv\"")
    |> send_resp(200, build_csv(logs))
  end

  defp parse_filters(params) do
    params
    |> Map.take(~w(actor_email entity_type action target_label ip))
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
    |> put_from(params["from"])
    |> put_to(params["to"])
  end

  defp put_from(filters, value) do
    with v when v not in [nil, ""] <- value,
         {:ok, date} <- Date.from_iso8601(v) do
      Map.put(filters, :from, DateTime.new!(date, ~T[00:00:00], "Etc/UTC"))
    else
      _ -> filters
    end
  end

  defp put_to(filters, value) do
    with v when v not in [nil, ""] <- value,
         {:ok, date} <- Date.from_iso8601(v) do
      Map.put(filters, :to, DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC"))
    else
      _ -> filters
    end
  end

  defp build_csv(logs) do
    header = [
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

    rows =
      Enum.map(logs, fn log ->
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
      end)

    [header | rows]
    |> Enum.map(&Enum.map_join(&1, ",", fn field -> escape(field) end))
    |> Enum.join("\n")
  end

  defp to_iso(nil), do: nil
  defp to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp encode_changes(changes) when changes in [nil, %{}], do: nil
  defp encode_changes(changes), do: Jason.encode!(changes)

  defp escape(nil), do: ""

  defp escape(value) do
    value = to_string(value)

    if String.contains?(value, [",", "\"", "\n"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end
end
