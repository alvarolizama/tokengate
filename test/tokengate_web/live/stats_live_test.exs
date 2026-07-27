defmodule TokengateWeb.StatsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Logs, Providers}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "stats-#{u}@example.com",
        name: "Stats #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp team_with_log(opts) do
    u = unique()

    {:ok, team} = Accounts.create_team(%{name: "Stats Team #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "stats-owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} =
      Accounts.create_team_member(%{user_id: owner.id, team_id: team.id, team_role: "user"})

    {:ok, provider} =
      Providers.create_provider(%{name: "Prov #{u}", base_url: "http://localhost:1"})

    {:ok, ma} =
      Providers.create_model_alias(%{
        name: "model-#{u}",
        display_name: "Model #{u}",
        market_input_price_per_1m: "1.00",
        market_output_price_per_1m: "2.00",
        context_window: 128_000
      })

    if cost = Map.get(opts, :cost) do
      {:ok, _log} =
        Logs.log_request(%{
          team_member_id: member.id,
          provider_id: provider.id,
          model_alias_id: ma.id,
          model_requested: "model-#{u}",
          model_responded: "model-#{u}",
          agent_type: "api",
          status_code: 200,
          prompt_tokens: 100,
          completion_tokens: 50,
          cost_usd: cost,
          provider_cost_usd: cost,
          savings_usd: "0.001",
          estimated_cost_usd: "0.01",
          latency_ms: 42,
          streaming: false
        })
    end

    %{team: team, owner: owner, member: member, model_alias: ma, provider: provider}
  end

  ## Auth -------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/stats")
  end

  ## Index view -------------------------------------------------------------

  test "admin sees stats index with KPIs and nav tabs", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/stats")

    assert html =~ "Estadísticas"
    assert has_element?(view, "#stats-nav")
    assert has_element?(view, "#nav-stats")
    assert has_element?(view, "#nav-models")
    assert has_element?(view, "#nav-teams")
    assert has_element?(view, "#period-selector")
    assert has_element?(view, "#period-7d")
    assert has_element?(view, "#period-30d")
    assert has_element?(view, "#period-90d")
    refute has_element?(view, "#period-today")
  end

  test "admin sees KPI cards and top tables on index", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats")

    assert has_element?(view, "#kpi-requests")
    assert has_element?(view, "#kpi-cost-real")
    assert has_element?(view, "#kpi-cost-estimated")
    assert has_element?(view, "#kpi-savings")
    assert has_element?(view, "#kpi-tokens")
    assert has_element?(view, "#kpi-tps")
  end

  test "admin sees provider ranking on index", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{provider: provider} = team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats")

    assert has_element?(view, "#provider-ranking")
    assert has_element?(view, "#provider-ranking-row-#{provider.id}")
  end

  test "regular user does NOT see provider ranking on index", %{conn: conn} do
    %{owner: owner} = team_with_log(%{cost: "0.005"})

    conn = login(conn, owner, owner.password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats")

    refute has_element?(view, "#provider-ranking")
  end

  test "admin sees usage patterns section on index", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats")

    assert has_element?(view, "#usage-patterns")
    assert has_element?(view, "#hour-distribution")
    assert has_element?(view, "#busiest-hours")
    assert has_element?(view, "#busiest-minutes")
    assert has_element?(view, "#peak-concurrency")
  end

  test "regular user sees usage patterns but NOT peak concurrency", %{conn: conn} do
    %{owner: owner} = team_with_log(%{cost: "0.005"})

    conn = login(conn, owner, owner.password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats")

    assert has_element?(view, "#usage-patterns")
    refute has_element?(view, "#peak-concurrency")
  end

  ## Models view ------------------------------------------------------------

  test "admin sees models table with all models", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats/models")

    assert has_element?(view, "#csv-models")
    assert has_element?(view, "table")
  end

  test "selecting a model shows drill-down with provider breakdown", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{model_alias: ma} = team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats/models?model_id=#{ma.id}")

    assert has_element?(view, "#model-kpi-requests")
    assert has_element?(view, "#model-kpi-mercado")
    assert has_element?(view, "#model-kpi-real")
    assert has_element?(view, "#model-kpi-ahorro")
    # Provider breakdown
    assert has_element?(view, "#clear-model-filter")
  end

  ## Teams view -------------------------------------------------------------

  test "admin sees teams table with all teams", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats/teams")

    assert has_element?(view, "#csv-teams")
    assert has_element?(view, "table")
  end

  test "selecting a team shows drill-down with members and models", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{team: team} = team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats/teams?team_id=#{team.id}")

    assert has_element?(view, "#team-kpi-requests")
    assert has_element?(view, "#team-kpi-mercado")
    assert has_element?(view, "#team-kpi-real")
    assert has_element?(view, "#team-kpi-ahorro")
    assert has_element?(view, "#clear-team-filter")
  end

  ## Period switching --------------------------------------------------------

  test "switching period patches the URL", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats")

    view |> element("#period-30d") |> render_click()

    path = assert_patch(view)
    assert URI.decode(path) =~ "period=30d"
  end

  ## User scope --------------------------------------------------------------

  test "user sees only their own consumption on stats", %{conn: conn} do
    %{owner: owner, member: _member} = team_with_log(%{cost: "0.005"})
    # Another team's log that must not leak
    team_with_log(%{cost: "99.99"})

    password = owner.password
    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats")

    assert has_element?(view, "#kpi-requests")
    # User scope: KPI cost should show 0.005 (their own), not 99.99
    cost_html = view |> element("#kpi-cost-real") |> render()
    assert cost_html =~ "0.005"
    refute cost_html =~ "99.99"
  end

  ## CSV export --------------------------------------------------------------

  test "CSV export returns downloadable file for models", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    conn = get(conn, "/dashboard/stats/export?type=models&period=7d")

    assert conn.status == 200

    assert ["attachment; filename=\"estadisticas_modelos_" <> _] =
             get_resp_header(conn, "content-disposition")

    assert ["text/csv; charset=utf-8"] = get_resp_header(conn, "content-type")
  end

  test "CSV export returns downloadable file for teams", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    conn = get(conn, "/dashboard/stats/export?type=teams&period=7d")

    assert conn.status == 200

    assert ["attachment; filename=\"estadisticas_equipos_" <> _] =
             get_resp_header(conn, "content-disposition")
  end

  test "unauthenticated CSV export redirects to login", %{conn: conn} do
    conn = get(conn, "/dashboard/stats/export?type=models&period=7d")
    assert redirected_to(conn, 302) =~ "/login"
  end
end
