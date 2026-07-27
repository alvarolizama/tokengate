defmodule TokengateWeb.StatsExportController do
  @moduledoc """
  CSV export endpoint for stats data.

  Accepts query params:
    * `type`   — `models` or `teams` (required)
    * `period` — `7d`, `30d`, `90d` (default: `7d`)
    * `model_id` — filter by model (for models type only)
    * `team_id`  — filter by team (for teams type only)

  Returns a CSV file download with `Content-Disposition: attachment`.
  """

  use TokengateWeb, :controller

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Metrics.Rollup

  @periods %{"7d" => 168, "30d" => 720, "90d" => 2160}

  def export(conn, params) do
    user = conn.assigns[:current_user]

    period = parse_period(params["period"])
    hours = Map.fetch!(@periods, period)

    from =
      DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)

    opts = [from: from]

    type = params["type"] || "models"

    case build_csv(user, type, params, opts) do
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

  defp build_csv(user, "teams", params, opts) do
    team_id = params["team_id"]

    if team_id && not team_export_allowed?(user, team_id) do
      {:error, :forbidden}
    else
      {:ok, build_teams_csv(user, team_id, opts)}
    end
  end

  defp build_csv(user, _type, params, opts) do
    {:ok, build_models_csv(user, params["model_id"], opts)}
  end

  # A team drill-down exposes every member's email and consumption, so only
  # admins and managers of that team may export it.
  defp team_export_allowed?(%{global_role: "admin"}, _team_id), do: true

  defp team_export_allowed?(%{global_role: "user"} = user, team_id) do
    user.id
    |> Accounts.list_team_members_for_user()
    |> Enum.any?(fn tm -> tm.team_id == team_id and tm.team_role == "manager" end)
  end

  defp team_export_allowed?(_, _), do: false

  ## Models CSV -----------------------------------------------------------

  defp build_models_csv(user, model_id, opts) do
    scope = scope_for(user)

    rows =
      if model_id do
        # Drill-down: per-provider breakdown for this model
        Rollup.breakdown_by_provider_for_model(model_id, opts)
      else
        # Full table: all models
        Rollup.breakdown_by_model(scope[:team_id], opts)
      end

    header =
      if model_id do
        ~w(proveedor requests costo_real costo_mercado costo_estimado ahorro tokens_in tokens_out tps)
      else
        ~w(modelo requests costo_real costo_mercado costo_estimado ahorro tokens_in tokens_out tps)
      end

    csv =
      [header | Enum.map(rows, &row_to_csv/1)]
      |> Enum.map(&Enum.join(&1, ","))
      |> Enum.join("\n")

    suffix = if model_id, do: "_modelo", else: ""
    {"estadisticas_modelos#{suffix}_#{Date.utc_today()}.csv", csv}
  end

  ## Teams CSV ------------------------------------------------------------

  defp build_teams_csv(user, team_id, opts) do
    rows =
      if team_id do
        # Drill-down: members of this team
        Rollup.breakdown_by_member(team_id, opts)
      else
        # Full table: all teams the user can see
        load_team_breakdown(user, opts)
      end

    header =
      if team_id do
        ~w(usuario equipo requests costo_real costo_mercado costo_estimado ahorro tokens_in tokens_out tps)
      else
        ~w(equipo requests costo_real costo_mercado costo_estimado ahorro tokens_in tokens_out tps)
      end

    csv =
      [header | Enum.map(rows, &row_to_csv_team/1)]
      |> Enum.map(&Enum.join(&1, ","))
      |> Enum.join("\n")

    suffix = if team_id, do: "_equipo", else: ""
    {"estadisticas_equipos#{suffix}_#{Date.utc_today()}.csv", csv}
  end

  ## Row serialization ----------------------------------------------------

  defp row_to_csv(row) do
    [
      csv_escape(Map.get(row, :provider_name) || Map.get(row, :model_name) || "—"),
      row.request_count,
      decimal_to_csv(Map.get(row, :provider_cost_usd)),
      decimal_to_csv(Map.get(row, :estimated_cost_usd)),
      decimal_to_csv(Map.get(row, :cost_usd)),
      decimal_to_csv(Map.get(row, :savings_usd)),
      Map.get(row, :prompt_tokens, 0),
      Map.get(row, :completion_tokens, 0),
      tps_to_csv(Map.get(row, :avg_tps))
    ]
  end

  defp row_to_csv_team(row) do
    # When team_id is set, rows are members (have user_email).
    # When team_id is nil, rows are teams (have team_name).
    has_email = Map.has_key?(row, :user_email)

    if has_email do
      [
        csv_escape(row.user_email),
        csv_escape(Map.get(row, :team_name, "")),
        row.request_count,
        decimal_to_csv(Map.get(row, :provider_cost_usd)),
        decimal_to_csv(Map.get(row, :estimated_cost_usd)),
        decimal_to_csv(Map.get(row, :cost_usd)),
        decimal_to_csv(Map.get(row, :savings_usd)),
        Map.get(row, :prompt_tokens, 0),
        Map.get(row, :completion_tokens, 0),
        tps_to_csv(Map.get(row, :avg_tps))
      ]
    else
      [
        csv_escape(Map.get(row, :team_name, "—")),
        row.request_count,
        decimal_to_csv(Map.get(row, :provider_cost_usd)),
        decimal_to_csv(Map.get(row, :estimated_cost_usd)),
        decimal_to_csv(Map.get(row, :cost_usd)),
        decimal_to_csv(Map.get(row, :savings_usd)),
        Map.get(row, :prompt_tokens, 0),
        Map.get(row, :completion_tokens, 0),
        tps_to_csv(Map.get(row, :avg_tps))
      ]
    end
  end

  defp csv_escape(nil), do: ""

  defp csv_escape(s) when is_binary(s) do
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

  defp scope_for(%{global_role: "admin"}) do
    %{team_id: nil, manager_team_ids: nil, member_ids: nil}
  end

  defp scope_for(%{global_role: "user"} = user) do
    memberships = Accounts.list_team_members_for_user(user.id)

    manager_team_ids =
      memberships
      |> Enum.filter(&(&1.team_role == "manager"))
      |> Enum.map(& &1.team_id)
      |> Enum.uniq()

    if manager_team_ids != [] do
      %{team_id: nil, manager_team_ids: manager_team_ids, member_ids: nil}
    else
      %{team_id: nil, manager_team_ids: nil, member_ids: Enum.map(memberships, & &1.id)}
    end
  end

  defp scope_for(_), do: %{team_id: nil, manager_team_ids: nil, member_ids: nil}

  defp load_team_breakdown(%{global_role: "admin"}, opts) do
    Rollup.breakdown_by_team(opts)
  end

  defp load_team_breakdown(%{global_role: "user"} = user, opts) do
    memberships = Accounts.list_team_members_for_user(user.id)

    manager_team_ids =
      memberships
      |> Enum.filter(&(&1.team_role == "manager"))
      |> Enum.map(& &1.team_id)
      |> Enum.uniq()

    if manager_team_ids != [] do
      Rollup.breakdown_by_team(opts)
      |> Enum.filter(fn row -> row.team_id in manager_team_ids end)
    else
      []
    end
  end

  defp load_team_breakdown(_, _), do: []

  defp parse_period(nil), do: "7d"
  defp parse_period(period) when period in ~w(7d 30d 90d), do: period
  defp parse_period(_), do: "7d"

  # Suppress unused warnings for aliases used only in pattern matches
  _ = &Logs.cost_summary/1
end
