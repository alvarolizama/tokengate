defmodule TokengateWeb.StatsExportController do
  @moduledoc """
  CSV export endpoint for stats data.

  Accepts query params:
    * `type`   — `models`, `groups`, `providers`, `errors`, or `logs` (required)
    * `period` — `today`, `week`, `month`, `7d`, `30d`, `90d` (default: `7d`)
    * `model_id` — filter by model (for models type only)
    * `group_id`  — filter by group (for groups type only)

  Unknown types fall through to the models CSV — see `build_csv/5`.

  Returns a CSV file download with `Content-Disposition: attachment`.
  """

  use TokengateWeb, :controller
  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Periods

  def export(conn, params) do
    user = conn.assigns[:current_user]
    timezone = (user && user.timezone) || "Etc/UTC"

    period = parse_period(params["period"])
    %{from: from, to: to} = Periods.period_bounds(period, timezone)
    opts = [from: from, to: to]

    type = params["type"] || "models"

    case build_csv(user, type, params, opts, timezone) do
      {:ok, {filename, csv_content}} ->
        conn
        |> put_resp_content_type("text/csv", "utf-8")
        |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
        |> send_resp(200, csv_content)

      {:error, :forbidden} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(403, Jason.encode!(%{"error" => "no autorizado"}))
    end
  end

  defp build_csv(user, "groups", params, opts, timezone) do
    group_id = params["group_id"]

    if group_id && not group_export_allowed?(user, group_id) do
      {:error, :forbidden}
    else
      {:ok, build_groups_csv(user, group_id, timezone, opts)}
    end
  end

  # La tabla de proveedores es la única sección admin-only del hub (la ruta vive
  # en la live_session :admin) y su ranking NO admite scoping por miembro —
  # `Rollup.provider_ranking/2` agrega por proveedor sin filtrar por
  # `member_ids`. Un manager exportaría, entonces, el tráfico de la
  # organización entera; el mismo criterio que el drill-down de grupos: si no
  # eres admin, no baja.
  defp build_csv(user, "providers", _params, opts, timezone) do
    if admin?(user) do
      {:ok, build_providers_csv(opts, timezone)}
    else
      {:error, :forbidden}
    end
  end

  defp build_csv(user, "errors", _params, opts, timezone) do
    {:ok, build_errors_csv(user, opts, timezone)}
  end

  defp build_csv(user, "logs", _params, opts, timezone) do
    {:ok, build_logs_csv(user, opts, timezone)}
  end

  defp build_csv(user, _type, params, opts, timezone) do
    {:ok, build_models_csv(user, params["model_id"], timezone, opts)}
  end

  # A group drill-down exposes every member's email and consumption, so only
  # admins may export it.
  defp group_export_allowed?(%{global_role: "admin"}, _group_id), do: true
  defp group_export_allowed?(_, _), do: false

  defp admin?(%{global_role: "admin"}), do: true
  defp admin?(_), do: false

  ## Providers CSV ---------------------------------------------------------

  # Mismo desglose que la tabla de proveedores: una fila por proveedor con su
  # tier/score y su información básica del período. Sale del MISMO agregado que
  # pinta la tabla (`Rollup.provider_ranking/2`), así el CSV y la pantalla no
  # pueden decir cosas distintas — igual que el detalle de un proveedor.
  defp build_providers_csv(opts, timezone) do
    rows = Rollup.provider_ranking(nil, opts)

    header = ~w(proveedor tier score requests fallos latencia_ms p95_ms ttft_ms)

    csv =
      [header | Enum.map(rows, &row_to_csv_provider/1)]
      |> Enum.map(&Enum.join(&1, ","))
      |> Enum.join("\n")

    {"estadisticas_proveedores_#{Periods.local_today(timezone)}.csv", csv}
  end

  defp row_to_csv_provider(row) do
    [
      csv_escape(row.provider_name),
      csv_escape(Map.get(row, :tier, "—")),
      csv_score(Map.get(row, :score)),
      row.request_count,
      csv_percent(Map.get(row, :error_rate)),
      csv_ms(Map.get(row, :avg_latency_ms)),
      csv_ms(Map.get(row, :p95_latency_ms)),
      csv_ms(Map.get(row, :avg_ttft_ms))
    ]
  end

  # Menos de 10 requests no tiene tier ni score (misma regla que la tabla):
  # se exporta vacío, no un cero que se leería como "pésimo".
  defp csv_score(nil), do: ""
  defp csv_score(score), do: to_string(score)

  defp csv_percent(nil), do: ""
  defp csv_percent(rate), do: Float.to_string(Float.round(rate * 100, 1))

  defp csv_ms(nil), do: ""
  defp csv_ms(ms), do: to_string(round(ms))

  ## Models CSV -----------------------------------------------------------

  defp build_models_csv(user, model_id, timezone, opts) do
    # Scoping: non-admin users only export consumption of their own scope
    # (managed groups for managers, own memberships for regular users).
    opts = Keyword.put(opts, :member_ids, Accounts.scope_member_ids(user))

    rows =
      if model_id do
        # Drill-down: per-provider breakdown for this model
        Rollup.breakdown_by_provider_for_model(model_id, opts)
      else
        # Full table: all models
        Rollup.breakdown_by_model(nil, opts)
      end

    header =
      if model_id do
        ~w(proveedor_modelo requests costo tokens_in tokens_out tps)
      else
        ~w(modelo requests costo tokens_in tokens_out tps)
      end

    csv =
      [header | Enum.map(rows, &row_to_csv/1)]
      |> Enum.map(&Enum.join(&1, ","))
      |> Enum.join("\n")

    suffix = if model_id, do: "_modelo", else: ""
    {"estadisticas_models#{suffix}_#{Periods.local_today(timezone)}.csv", csv}
  end

  ## Groups CSV ------------------------------------------------------------

  defp build_groups_csv(user, group_id, timezone, opts) do
    rows =
      if group_id do
        # Drill-down: members of this group
        Rollup.breakdown_by_member(group_id, opts)
      else
        # Full table: all groups the user can see
        load_group_breakdown(user, opts)
      end

    header =
      if group_id do
        ~w(usuario grupo requests costo tokens_in tokens_out tps)
      else
        ~w(grupo requests costo tokens_in tokens_out tps)
      end

    csv =
      [header | Enum.map(rows, &row_to_csv_group/1)]
      |> Enum.map(&Enum.join(&1, ","))
      |> Enum.join("\n")

    suffix = if group_id, do: "_grupo", else: ""
    {"estadisticas_grupos#{suffix}_#{Periods.local_today(timezone)}.csv", csv}
  end

  ## Errors CSV -----------------------------------------------------------

  defp build_errors_csv(user, opts, timezone) do
    filters =
      opts
      |> Map.new()
      |> Map.put(:status_class, "errors")
      |> Map.put(:limit, 50_000)
      |> Map.put(:group_member_ids, Accounts.scope_member_ids(user))

    rows = Logs.list_logs_for_export(filters)

    header =
      ~w(fecha estado modelo proveedor usuario grupo api_key error_reason prov_status latencia_ms costo_usd)

    csv =
      [header | Enum.map(rows, &row_to_csv_error/1)]
      |> Enum.map(&Enum.join(&1, ","))
      |> Enum.join("\n")

    {"errores_#{Periods.local_today(timezone)}.csv", csv}
  end

  ## Logs CSV (full export) -----------------------------------------------

  defp build_logs_csv(user, opts, timezone) do
    filters =
      opts
      |> Map.new()
      |> Map.put(:limit, 50_000)
      |> Map.put(:group_member_ids, Accounts.scope_member_ids(user))

    rows = Logs.list_logs_for_export(filters)

    header =
      ~w(fecha estado modelo usuario grupo agente api_key proveedor prov_key prov_status error_reason error_message streaming think effort tokens_in tokens_out cache_read cache_creation latencia_ms ttft_ms costo_usd)

    csv =
      [header | Enum.map(rows, &row_to_csv_log/1)]
      |> Enum.map(&Enum.join(&1, ","))
      |> Enum.join("\n")

    {"logs_#{Periods.local_today(timezone)}.csv", csv}
  end

  defp row_to_csv_log(log) do
    [
      csv_escape(format_datetime_csv(log.inserted_at)),
      log.status_code,
      csv_escape(model_display_csv(log.model_requested, log.model_responded)),
      csv_escape(log.group_member && log.group_member.user && log.group_member.user.email),
      csv_escape(log.group_member && log.group_member.group && log.group_member.group.name),
      csv_escape(log.client_agent),
      csv_escape(log.api_key_prefix),
      csv_escape(log.provider && log.provider.name),
      csv_escape(log.provider_key_prefix),
      log.provider_status_code,
      csv_escape(log.error_reason),
      csv_escape(log.error_message),
      if(log.streaming, do: "true", else: "false"),
      if(log.think, do: "true", else: "false"),
      csv_escape(log.effort),
      log.prompt_tokens,
      log.completion_tokens,
      log.cache_read_tokens,
      log.cache_creation_tokens,
      log.latency_ms,
      log.ttft_ms,
      decimal_to_csv(log.provider_cost_usd)
    ]
  end

  defp model_display_csv(requested, nil), do: requested || ""
  defp model_display_csv(requested, responded) when requested == responded, do: requested
  defp model_display_csv(requested, responded), do: "#{requested} → #{responded}"

  defp row_to_csv_error(log) do
    [
      csv_escape(format_datetime_csv(log.inserted_at)),
      log.status_code,
      csv_escape(log.model_requested),
      csv_escape(log.provider && log.provider.name),
      csv_escape(log.group_member && log.group_member.user && log.group_member.user.email),
      csv_escape(log.group_member && log.group_member.group && log.group_member.group.name),
      csv_escape(log.api_key_prefix),
      csv_escape(log.error_reason),
      log.provider_status_code,
      log.latency_ms,
      decimal_to_csv(log.provider_cost_usd)
    ]
  end

  defp format_datetime_csv(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  ## Row serialization ----------------------------------------------------

  defp row_to_csv(row) do
    [
      csv_escape(row_label(row)),
      row.request_count,
      decimal_to_csv(Map.get(row, :cost_usd)),
      Map.get(row, :prompt_tokens, 0),
      Map.get(row, :completion_tokens, 0),
      tps_to_csv(Map.get(row, :avg_tps))
    ]
  end

  # Drill-down rows carry provider_name + provider_model ("OpenAI · gpt-4o");
  # full-table rows carry model_name.
  defp row_label(%{provider_name: name, provider_model: model})
       when is_binary(name) and is_binary(model),
       do: "#{name} · #{model}"

  defp row_label(row),
    do: Map.get(row, :provider_name) || Map.get(row, :model_name) || "—"

  defp row_to_csv_group(row) do
    # When group_id is set, rows are members (have user_email).
    # When group_id is nil, rows are groups (have group_name).
    has_email = Map.has_key?(row, :user_email)

    if has_email do
      [
        csv_escape(row.user_email),
        csv_escape(Map.get(row, :group_name, "")),
        row.request_count,
        decimal_to_csv(Map.get(row, :cost_usd)),
        Map.get(row, :prompt_tokens, 0),
        Map.get(row, :completion_tokens, 0),
        tps_to_csv(Map.get(row, :avg_tps))
      ]
    else
      [
        csv_escape(Map.get(row, :group_name, "—")),
        row.request_count,
        decimal_to_csv(Map.get(row, :cost_usd)),
        Map.get(row, :prompt_tokens, 0),
        Map.get(row, :completion_tokens, 0),
        tps_to_csv(Map.get(row, :avg_tps))
      ]
    end
  end

  defp csv_escape(nil), do: ""

  # CSV formula injection guard: values starting with = + - @ \t or \r are
  # interpreted as formulas by Excel/Sheets when the file is opened. Fields
  # like client_agent come from attacker-controlled request headers, so we
  # prefix them with a single quote to force text rendering.
  @csv_formula_starters ["=", "+", "-", "@", "\t", "\r"]

  defp csv_escape(s) when is_binary(s) do
    s =
      if String.starts_with?(s, @csv_formula_starters) do
        "'" <> s
      else
        s
      end

    if String.contains?(s, [",", "\"", "\n"]) do
      "\"" <> String.replace(s, "\"", "\"\"") <> "\""
    else
      s
    end
  end

  defp decimal_to_csv(nil), do: "0"
  defp decimal_to_csv(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_to_csv(n), do: to_string(n)

  defp tps_to_csv(nil), do: ""
  defp tps_to_csv(n) when is_float(n), do: Float.to_string(Float.round(n, 1))
  defp tps_to_csv(n) when is_integer(n), do: Integer.to_string(n)

  ## Scoping helpers (mirror StatsLive) ----------------------------------

  defp load_group_breakdown(%{global_role: "admin"}, opts) do
    Rollup.breakdown_by_group(opts)
  end

  defp load_group_breakdown(_, _), do: []

  defp parse_period(nil), do: "7d"
  defp parse_period(period) when period in ~w(today week month 7d 30d 90d), do: period
  defp parse_period(_), do: "7d"
end
