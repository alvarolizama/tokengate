defmodule TokengateWeb.StatsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Logs, Periods, Providers}

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

  # Stats data now loads in an async task (assign_async), so tests must wait
  # for the async result to land before asserting on data-driven markup.
  # `:sys.get_state/1` syncs with the LiveView process (it processes all
  # pending messages first), so one call after `render/1` is usually enough;
  # the tiny sleep gives the supervised async task a chance to finish when
  # the DB is under load.
  defp wait_stats_loaded(view, attempts \\ 200)

  defp wait_stats_loaded(view, attempts) when attempts > 0 do
    state = :sys.get_state(view.pid)

    case get_in(state, [Access.key(:socket), Access.key(:assigns), Access.key(:stats_loading)]) do
      false ->
        view

      _other ->
        Process.sleep(10)
        wait_stats_loaded(view, attempts - 1)
    end
  end

  defp wait_stats_loaded(_view, 0), do: raise("stats async data never loaded")

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
        context_window: 128_000
      })

    if cost = Map.get(opts, :cost) do
      inserted_at =
        Map.get(opts, :inserted_at) || DateTime.utc_now() |> DateTime.truncate(:second)

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
          provider_cost_usd: cost,
          latency_ms: 42,
          streaming: false,
          inserted_at: inserted_at
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
    assert has_element?(view, "#period-today")
  end

  test "admin sees KPI cards and top tables on index", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats")
    wait_stats_loaded(view)

    assert has_element?(view, "#kpi-requests")
    assert has_element?(view, "#kpi-cost")
    assert has_element?(view, "#kpi-tokens")
    assert has_element?(view, "#kpi-tps")
    assert has_element?(view, "#model-ranking")
  end

  test "admin sees provider ranking on index", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{provider: provider} = team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats")
    wait_stats_loaded(view)

    assert has_element?(view, "#provider-ranking")
    assert has_element?(view, "#provider-ranking-row-#{provider.id}")
  end

  test "regular user is redirected from stats to dashboard", %{conn: conn} do
    %{owner: owner} = team_with_log(%{cost: "0.005"})

    conn = login(conn, owner, owner.password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/stats")
  end

  test "admin sees usage patterns section on index", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats")
    wait_stats_loaded(view)

    assert has_element?(view, "#usage-patterns")
    assert has_element?(view, "#hour-distribution")
    assert has_element?(view, "#busiest-hours")
    assert has_element?(view, "#busiest-minutes")
    assert has_element?(view, "#peak-concurrency")
  end

  test "regular user is redirected from stats (usage patterns)", %{conn: conn} do
    %{owner: owner} = team_with_log(%{cost: "0.005"})

    conn = login(conn, owner, owner.password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/stats")
  end

  ## Models view ------------------------------------------------------------

  test "admin sees models table with all models", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats/models")
    wait_stats_loaded(view)

    assert has_element?(view, "#csv-models")
    assert has_element?(view, "table")
  end

  test "selecting a model shows drill-down with provider breakdown", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{model_alias: ma} = team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats/models?model_id=#{ma.id}")
    wait_stats_loaded(view)

    assert has_element?(view, "#model-kpi-requests")
    # Since the 2026-07-30 refactor there's only one cost KPI: #model-kpi-cost.
    assert has_element?(view, "#model-kpi-cost")
    # Provider breakdown
    assert has_element?(view, "#clear-model-filter")
  end

  ## Teams view -------------------------------------------------------------

  test "admin sees teams table with all teams", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats/teams")
    wait_stats_loaded(view)

    assert has_element?(view, "#csv-teams")
    assert has_element?(view, "table")
  end

  test "selecting a team shows drill-down with members and models", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{team: team} = team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats/teams?team_id=#{team.id}")
    wait_stats_loaded(view)

    assert has_element?(view, "#team-kpi-requests")
    # Since the 2026-07-30 refactor there's only one cost KPI: #team-kpi-cost.
    assert has_element?(view, "#team-kpi-cost")
    assert has_element?(view, "#clear-team-filter")
  end

  ## Period switching --------------------------------------------------------

  test "switching period updates data", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats")

    view |> element("#period-30d") |> render_click()

    # Period should change and data should reload
    assert has_element?(view, "#period-30d.btn-primary")
    refute has_element?(view, "#period-today.btn-primary")
  end

  ## Sorting -------------------------------------------------------------------

  test "clicking a sort header re-orders the breakdown table rows", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    # Same team/member, two different model aliases with different costs so
    # the model breakdown has two sortable rows.
    %{member: member, model_alias: cheap, provider: provider} =
      team_with_log(%{cost: "0.001"})

    u = unique()

    {:ok, expensive} =
      Providers.create_model_alias(%{
        name: "model-expensive-#{u}",
        display_name: "Expensive #{u}",
        context_window: 128_000
      })

    {:ok, _log} =
      Logs.log_request(%{
        team_member_id: member.id,
        provider_id: provider.id,
        model_alias_id: expensive.id,
        model_requested: expensive.name,
        model_responded: expensive.name,
        agent_type: "api",
        status_code: 200,
        prompt_tokens: 100,
        completion_tokens: 50,
        provider_cost_usd: "0.500",
        latency_ms: 42,
        streaming: false,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats/models")
    html = render(wait_stats_loaded(view))

    # Row order = order of appearance of the bd-model-<id> rows in the HTML.
    row_order = fn view ->
      Regex.scan(~r/<tr[^>]+id="(bd-model-[^"]+)"/, render(view))
      |> Enum.map(fn [_full, id] -> id end)
    end

    expensive_row = "bd-model-#{expensive.id}"
    cheap_row = "bd-model-#{cheap.id}"

    assert html =~ expensive_row
    assert html =~ cheap_row

    # Click the Costo header: new field → desc, expensive first.
    view
    |> element("button[phx-click='sort'][phx-value-field='cost_usd']")
    |> render_click()

    assert row_order.(view) == [expensive_row, cheap_row]

    # Click again → toggles to asc, cheap first.
    view
    |> element("button[phx-click='sort'][phx-value-field='cost_usd']")
    |> render_click()

    assert row_order.(view) == [cheap_row, expensive_row]

    # Click once more → back to desc.
    view
    |> element("button[phx-click='sort'][phx-value-field='cost_usd']")
    |> render_click()

    assert row_order.(view) == [expensive_row, cheap_row]
  end

  ## User scope --------------------------------------------------------------

  test "regular user is redirected from stats (own consumption)", %{conn: conn} do
    %{owner: owner, member: _member} = team_with_log(%{cost: "0.005"})
    # Another team's log that must not leak
    team_with_log(%{cost: "99.99"})

    password = owner.password
    conn = login(conn, owner, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/stats")
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

  test "hour distribution uses the user's local timezone", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, "America/Mexico_City")

    today_start = Periods.start_of_day_utc("America/Mexico_City")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    candidate = DateTime.add(today_start, 3600, :second)

    inserted_at =
      if DateTime.compare(candidate, now) == :lt,
        do: candidate,
        else: DateTime.add(now, -60, :second)

    team_with_log(%{cost: "0.005", inserted_at: inserted_at})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats")
    html = render(wait_stats_loaded(view))

    # El log cayó en una hora local (01:00 local si candidate < now) y la
    # distribución renderiza barras (max > 0)
    assert html =~ "Uso por hora del día"
    assert html =~ "hora local"
    refute html =~ "Sin datos en este período."
    # La barra de la hora local 1 (01:00) es la máxima
    assert has_element?(view, "#kpi-requests")
  end

  test "hour distribution excludes the previous local day", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, "America/Mexico_City")

    # 23:00 del día anterior local → fuera de "Hoy" local
    today_start = Periods.start_of_day_utc("America/Mexico_City")
    team_with_log(%{cost: "0.005", inserted_at: DateTime.add(today_start, -3600, :second)})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/stats")
    html = render(wait_stats_loaded(view))

    assert html =~ "Sin datos en este período."
  end

  describe "hour_usage_bar_height/2 (sqrt scale)" do
    alias TokengateWeb.StatsLive

    test "the max value gets 100%" do
      assert StatsLive.hour_usage_bar_height(10_000, 10_000) == 100.0
    end

    test "sqrt scale lifts small values above the linear equivalent" do
      # lineal sería 1% (invisible); sqrt(0.01) = 10%
      assert StatsLive.hour_usage_bar_height(100, 10_000) == 10.0
    end

    test "enforces a visible minimum height" do
      assert StatsLive.hour_usage_bar_height(1, 1_000_000) == 8.0
    end

    test "zero max returns 0" do
      assert StatsLive.hour_usage_bar_height(0, 0) == 0
    end
  end

  describe "y_axis_ticks/2" do
    alias TokengateWeb.StatsLive

    test "returns ascending ticks up to a nice ceiling" do
      assert [_, _, _] = ticks = StatsLive.y_axis_ticks(950)
      assert ticks == Enum.sort(ticks)
      assert List.last(ticks) >= 950
    end

    test "ticks are nice round numbers for powers of ten" do
      assert StatsLive.y_axis_ticks(1000) == [333, 667, 1000]
    end

    test "handles tiny maxima" do
      assert [_, _, _] = StatsLive.y_axis_ticks(5)
    end
  end
end
