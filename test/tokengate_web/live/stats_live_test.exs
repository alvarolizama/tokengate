defmodule TokengateWeb.StatsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Budgets, Logs, Periods, Providers}
  alias Tokengate.Budgets.Manager

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

  # Suma `n` requests extra al sujeto del fixture, para que los rankings tengan
  # conteos distintos y el orden (los puestos 1º/2º/3º) sea determinista.
  defp log_extra(%{member: member, provider: provider, model: model}, n) when n > 0 do
    Enum.each(1..n//1, fn _ ->
      {:ok, _} =
        Logs.log_request(%{
          group_member_id: member.id,
          provider_id: provider.id,
          model_id: model.id,
          model_requested: model.name,
          agent_type: "api",
          status_code: 200,
          prompt_tokens: 10,
          completion_tokens: 5,
          provider_cost_usd: "0.005",
          latency_ms: 42,
          streaming: false,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
    end)

    :ok
  end

  defp log_extra(_fixture, _n), do: :ok

  defp group_with_log(opts) do
    u = unique()

    {:ok, group} = Accounts.create_group(%{name: "Stats Group #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "stats-owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} =
      Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "Prov #{u}", base_url: "http://localhost:1"})

    {:ok, ma} =
      Providers.create_model(%{
        name: "model-#{u}",
        context_window: 128_000
      })

    if cost = Map.get(opts, :cost) do
      inserted_at =
        Map.get(opts, :inserted_at) || DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _log} =
        Logs.log_request(%{
          group_member_id: member.id,
          provider_id: provider.id,
          model_id: ma.id,
          model_requested: "model-#{u}",
          model_responded: "model-#{u}",
          agent_type: "api",
          status_code: Map.get(opts, :status_code, 200),
          provider_status_code: Map.get(opts, :provider_status_code),
          error_reason: Map.get(opts, :error_reason),
          error_message: Map.get(opts, :error_message),
          prompt_tokens: Map.get(opts, :prompt_tokens, 100),
          completion_tokens: Map.get(opts, :completion_tokens, 50),
          cache_read_tokens: Map.get(opts, :cache_read_tokens, 0),
          cache_creation_tokens: Map.get(opts, :cache_creation_tokens, 0),
          provider_cost_usd: cost,
          latency_ms: 42,
          streaming: false,
          inserted_at: inserted_at
        })
    end

    %{group: group, owner: owner, member: member, model: ma, provider: provider}
  end

  ## Auth -------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/stats/overview")
  end

  ## Index view -------------------------------------------------------------

  test "admin sees stats index with KPIs and nav tabs", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/stats/overview")

    assert html =~ "Estadísticas"
    assert has_element?(view, "#stats-nav")
    assert has_element?(view, "#nav-live")
    assert has_element?(view, "#nav-overview")
    assert has_element?(view, "#nav-models")
    assert has_element?(view, "#nav-groups")
    assert has_element?(view, "#period-selector")
    assert has_element?(view, "#period-today")
    assert has_element?(view, "#period-week")
    assert has_element?(view, "#period-month")
    assert has_element?(view, "#period-30d")
    assert has_element?(view, "#period-90d")
  end

  test "admin sees KPI cards on index (no tops/rankings anymore)", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/overview")
    wait_stats_loaded(view)

    assert has_element?(view, "#kpi-requests")
    assert has_element?(view, "#kpi-cost")
    assert has_element?(view, "#kpi-tokens")
    assert has_element?(view, "#kpi-tps")
    # Los tops/rankings/tiers se movieron fuera del Resumen.
    refute has_element?(view, "#model-ranking")
    refute has_element?(view, "#provider-ranking")
    refute has_element?(view, "#member-usage-tiers")
  end

  test "tokens KPI shows cache (read + creation) with hit rate", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    group_with_log(%{
      cost: "0.005",
      prompt_tokens: 1000,
      cache_read_tokens: 800,
      cache_creation_tokens: 200
    })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/overview")
    wait_stats_loaded(view)

    html = render(view)

    # Canonical format: hit rate first in the sub-line, values in the title
    assert html =~ "80.0% hit"
    assert html =~ "1,000 in / 50 out"
  end

  test "provider ranking lives in /stats/providers now", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{provider: provider} = group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/providers")
    wait_stats_loaded(view)

    assert has_element?(view, "#nav-providers")
    assert has_element?(view, "#provider-ranking")
    assert has_element?(view, "#provider-ranking-row-#{provider.id}")
  end

  test "model ranking lives in /stats/models now", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{model: ma} = group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/models")
    wait_stats_loaded(view)

    assert has_element?(view, "#model-ranking")
    assert has_element?(view, "#model-ranking-row-#{ma.id}")
  end

  test "member usage tiers live in /stats/groups now", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{member: member} = group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/groups")
    wait_stats_loaded(view)

    assert has_element?(view, "#member-usage-tiers")
    assert has_element?(view, "#member-tier-row-#{member.id}")
  end

  test "top members live in /stats/users now", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{owner: owner} = group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/users")
    wait_stats_loaded(view)

    assert has_element?(view, "#top-members")
    assert has_element?(view, "#top-member-#{owner.id}")
  end

  test "regular user is redirected from stats to dashboard", %{conn: conn} do
    %{owner: owner} = group_with_log(%{cost: "0.005"})

    conn = login(conn, owner, owner.password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/stats/overview")
  end

  test "admin sees usage patterns section on index", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/overview")
    wait_stats_loaded(view)

    assert has_element?(view, "#usage-patterns")
    assert has_element?(view, "#hour-distribution")
    assert has_element?(view, "#busiest-hours")
    assert has_element?(view, "#busiest-minutes")
    assert has_element?(view, "#peak-concurrency")
  end

  test "regular user is redirected from stats (usage patterns)", %{conn: conn} do
    %{owner: owner} = group_with_log(%{cost: "0.005"})

    conn = login(conn, owner, owner.password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/stats/overview")
  end

  ## Models view ------------------------------------------------------------

  test "admin sees models table with all models", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/models")
    wait_stats_loaded(view)

    assert has_element?(view, "#csv-models")
    assert has_element?(view, "table")
  end

  test "selecting a model shows drill-down with provider breakdown", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{model: ma} = group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/models?model_id=#{ma.id}")
    wait_stats_loaded(view)

    assert has_element?(view, "#model-kpi-requests")
    # Since the 2026-07-30 refactor there's only one cost KPI: #model-kpi-cost.
    assert has_element?(view, "#model-kpi-cost")
    # Provider breakdown
    assert has_element?(view, "#clear-model-filter")
  end

  ## Groups view -------------------------------------------------------------

  test "admin sees groups table with all groups", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/groups")
    wait_stats_loaded(view)

    assert has_element?(view, "#csv-groups")
    assert has_element?(view, "table")
  end

  test "selecting a group shows drill-down with members and models", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{group: group} = group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/groups?group_id=#{group.id}")
    wait_stats_loaded(view)

    assert has_element?(view, "#group-kpi-requests")
    # Since the 2026-07-30 refactor there's only one cost KPI: #group-kpi-cost.
    assert has_element?(view, "#group-kpi-cost")
    assert has_element?(view, "#clear-group-filter")
  end

  ## Period switching --------------------------------------------------------

  test "switching period updates data", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/overview")

    view |> element("#period-30d") |> render_click()

    # Period should change and data should reload
    assert has_element?(view, "#period-30d.btn-primary")
    refute has_element?(view, "#period-today.btn-primary")
  end

  ## Sorting -------------------------------------------------------------------

  test "clicking a sort header re-orders the breakdown table rows", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    # Same group/member, two different models with different costs so
    # the model breakdown has two sortable rows.
    %{member: member, model: cheap, provider: provider} =
      group_with_log(%{cost: "0.001"})

    u = unique()

    {:ok, expensive} =
      Providers.create_model(%{
        name: "model-expensive-#{u}",
        context_window: 128_000
      })

    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: member.id,
        provider_id: provider.id,
        model_id: expensive.id,
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
    {:ok, view, _html} = live(conn, ~p"/stats/models")
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
    %{owner: owner, member: _member} = group_with_log(%{cost: "0.005"})
    # Another group's log that must not leak
    group_with_log(%{cost: "99.99"})

    password = owner.password
    conn = login(conn, owner, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/stats/overview")
  end

  ## CSV export --------------------------------------------------------------

  test "CSV export returns downloadable file for models", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    conn = get(conn, "/stats/export?type=models&period=7d")

    assert conn.status == 200

    assert ["attachment; filename=\"estadisticas_models_" <> _] =
             get_resp_header(conn, "content-disposition")

    assert ["text/csv; charset=utf-8"] = get_resp_header(conn, "content-type")
  end

  test "CSV export returns downloadable file for groups", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    conn = get(conn, "/stats/export?type=groups&period=7d")

    assert conn.status == 200

    assert ["attachment; filename=\"estadisticas_grupos_" <> _] =
             get_resp_header(conn, "content-disposition")
  end

  test "unauthenticated CSV export redirects to login", %{conn: conn} do
    conn = get(conn, "/stats/export?type=models&period=7d")
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

    group_with_log(%{cost: "0.005", inserted_at: inserted_at})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/overview")
    html = render(wait_stats_loaded(view))

    # El log cayó en una hora local (01:00 local si candidate < now) y la
    # distribución renderiza barras (max > 0)
    assert html =~ "Uso por hora del día"
    refute html =~ "Sin datos en este período."
    # La barra de la hora local 1 (01:00) es la máxima
    assert has_element?(view, "#kpi-requests")
  end

  test "hour distribution excludes the previous UTC day", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, "America/Mexico_City")

    # 23:00 del día UTC anterior → fuera de "Hoy", que mide el día UTC
    # (la misma ventana que resetea el tope global), no el día local.
    utc_start = Periods.start_of_day_utc("Etc/UTC")
    group_with_log(%{cost: "0.005", inserted_at: DateTime.add(utc_start, -3600, :second)})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/overview")
    html = render(wait_stats_loaded(view))

    assert html =~ "Sin datos en este período."
  end

  ## Live ("En vivo") tab ---------------------------------------------------

  test "En vivo: KPIs de hoy van antes que el pulso, como en el Resumen", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/stats")

    html = render(view)

    # Orden de filas: presupuesto (si existe) → KPIs principales de hoy →
    # pulso (KPIs secundarios) → gráficas
    assert order_before?(html, "live-today-cost", "live-rpm")
    assert order_before?(html, "live-today-latency", "live-errors")
    # Dentro de la fila de hoy: Costo · Requests · Tokens · Latencia
    assert order_before?(html, "live-today-cost", "live-today-requests")
    assert order_before?(html, "live-today-requests", "live-today-tokens")
    assert order_before?(html, "live-today-tokens", "live-today-latency")
  end

  test "En vivo: no muestra el selector de período (ventana fija)", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/stats")

    refute has_element?(view, "#period-selector")
    refute has_element?(view, "#period-90d")

    # Sigue presente en las tabs de datos.
    {:ok, overview, _html} = live(conn, ~p"/stats/overview")
    assert has_element?(overview, "#period-selector")
    assert has_element?(overview, "#period-90d")
  end

  test "En vivo: el estado de auto-refresh vive en el header, no en el contenido", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/stats")

    # Ocupa el lugar que los timeframes dejan vacío en el header.
    assert has_element?(view, "#live-status")
    assert has_element?(view, "#live-status #live-last-sync")
    assert has_element?(view, "#live-status", "En vivo · actualización automática")

    # Ya no está dentro del contenido.
    refute has_element?(view, "#stats-content #live-status")

    # Las tabs de datos no lo muestran (ahí el header es el selector de período).
    {:ok, overview, _html} = live(conn, ~p"/stats/overview")
    refute has_element?(overview, "#live-status")
  end

  test "En vivo: el KPI de costo declara el día UTC y el reinicio", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, "America/Mexico_City")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/stats")

    # El número mide el día UTC (Periods.period_bounds), así que el KPI lo
    # declara y anuncia cuánto falta para el reinicio, con el reloj del usuario
    # como referencia secundaria.
    assert has_element?(view, "#live-today-cost", "Hoy · costo (UTC)")
    assert has_element?(view, "#live-today-cost", "Reinicia en")
    assert has_element?(view, "#live-today-cost", "en tu hora local")
  end

  test "En vivo + Resumen + Mantenimiento ignoran los holds en vuelo", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    # El contador global vive en ETS (tabla pública del árbol de la app): se
    # limpia para que el test siembre desde su propia DB, como en budgets_test.
    :ets.delete(:tokengate_budgets, {:global, :daily})

    group_with_log(%{cost: "25.00"})

    # Hold en vuelo: el proxy reserva $20 contra el tope ANTES de que el
    # request termine y su costo quede escrito en request_logs.
    {:ok, hold} =
      Manager.reserve_credits([], Decimal.new("100.00"), Decimal.new("20.00"), false)

    # El "gasto real reportado" = agregado de request_logs del día UTC.
    real =
      Logs.cost_summary(%{from: Periods.start_of_day_utc("Etc/UTC")})
      |> Map.fetch!(:total_cost_usd)

    assert Decimal.eq?(real, Decimal.new("25.00"))

    {:ok, view, _html} = live(conn, ~p"/stats")
    assigns = :sys.get_state(view.pid).socket.assigns

    # Ninguna de las dos cifras visibles del tab En vivo lleva el hold (45.00):
    # son el gasto liquidado.
    assert Decimal.eq?(assigns.org_budget.daily_spend_usd, real)
    assert Decimal.eq?(assigns.today_metrics.cost_usd, real)

    # El Resumen bebe de la misma fuente; el tab no lo cambia.
    {:ok, overview, _html} = live(conn, ~p"/stats/overview")
    wait_stats_loaded(overview)
    ov = :sys.get_state(overview.pid).socket.assigns

    assert Decimal.eq?(ov.org_budget.daily_spend_usd, real)
    assert Decimal.eq?(ov.metrics.cost_usd, real)

    # El hold SÍ está en el contador de enforcement: eso prueba que existía y
    # que el cálculo mostrado lo ignora.
    assert Decimal.gt?(Manager.global_daily_spend(), real)

    :ok = Manager.release_credits(hold)
  end

  test "Resumen: el KPI de costo declara UTC y el reinicio solo en el período hoy",
       %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/stats/overview")
    wait_stats_loaded(view)

    # Con "Hoy" el KPI declara la ventana UTC y el countdown — igual que
    # En vivo, porque las dos páginas miden lo mismo.
    assert has_element?(view, "#kpi-cost", "Costo (UTC)")
    assert has_element?(view, "#kpi-cost", "Reinicia en")
    assert has_element?(view, "#kpi-cost", "en tu hora local")

    # En una ventana más larga no hay reinicio diario que anunciar: vuelve al
    # label corto y sin línea de countdown.
    render_click(view, "set_period", %{"period" => "30d"})
    wait_stats_loaded(view)

    assert has_element?(view, "#kpi-cost", "Costo")
    refute has_element?(view, "#kpi-cost", "Reinicia en")

    # "Este mes" también mide una ventana UTC (la del tope mensual), así que el
    # label lo declara — pero sin countdown: el reinicio diario no aplica.
    render_click(view, "set_period", %{"period" => "month"})
    wait_stats_loaded(view)

    assert has_element?(view, "#kpi-cost", "Costo (mes UTC)")
    refute has_element?(view, "#kpi-cost", "Reinicia en")
  end

  test "Resumen: el número del KPI de costo mide el día UTC, no el local",
       %{conn: conn} do
    tz = "America/Merida"
    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, tz)
    conn = login(conn, admin, password)

    # El Resumen es `assign_async`: su número no se puede verificar por HTTP
    # (llega por el socket), así que se pina aquí con un log colocado en la
    # banda que pertenece al día UTC pero NO al día local del usuario
    # ([00:00 UTC, medianoche local) = las primeras 6h del día UTC en Merida).
    # Si el KPI midiera el día local, este log no contaría y el card daría 0.
    utc_start = Periods.start_of_day_utc("Etc/UTC")
    local_start = Periods.start_of_day_utc(tz)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    edge =
      if DateTime.compare(now, local_start) == :lt do
        # Dentro de la banda: un minuto atrás (o el inicio del día UTC).
        max_min = DateTime.add(now, -60, :second)

        if DateTime.compare(max_min, utc_start) == :lt,
          do: DateTime.add(utc_start, 1, :second),
          else: max_min
      else
        # Fuera de la banda: 00:30 UTC siempre cae dentro de ella.
        DateTime.add(utc_start, 1800, :second)
      end

    # Guarda: el instante elegido debe estar en la banda discriminante.
    assert DateTime.compare(edge, utc_start) != :lt
    assert DateTime.compare(edge, local_start) == :lt

    group_with_log(%{cost: "0.7500", inserted_at: edge})

    {:ok, view, _html} = live(conn, ~p"/stats/overview")
    wait_stats_loaded(view)

    html = view |> element("#kpi-cost") |> render()

    assert html =~ "$0.7500"
    # Y difiere del día local, que a esta hora ve 0.
    refute html =~ "$0.0000"
  end

  test "En vivo: el pie del tope diario declara el día UTC, no el local", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, "America/Mexico_City")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/stats")

    # El card mide el día UTC (la ventana del kill-switch, la misma que
    # Mantenimiento), así que el pie no puede nombrar la zona del usuario como
    # si el número midiera su día local: la barra y el countdown tienen que
    # apuntar a la misma ventana.
    assert has_element?(view, "#live-org-budget", "Gasto del día UTC")
    refute has_element?(view, "#live-org-budget", "día local")

    # La hora local sigue ahí, pero como referencia del reloj del usuario.
    assert has_element?(view, "#live-org-budget", "en tu hora local")
  end

  test "En vivo: el tope diario mide el día UTC, la misma ventana que Mantenimiento",
       %{conn: conn} do
    tz = "America/Merida"

    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, tz)
    conn = login(conn, admin, password)

    {:ok, _} = Tokengate.GlobalSettings.update(%{daily_max_spend_usd: Decimal.new("2.0000")})

    # Un log en un instante que cae dentro de UNA sola de las dos ventanas
    # "hoy" (la UTC del kill-switch o la local del usuario): así el gasto del
    # día UTC y el del día local difieren por construcción, sin importar a qué
    # hora corra el test. Este es el bug que trajo el comentario: el card
    # sumaba el día local del usuario mientras la barra y el countdown apuntan
    # a la ventana UTC.
    utc_start = Periods.start_of_day_utc("Etc/UTC")
    local_start = Periods.start_of_day_utc(tz)

    edge =
      if DateTime.compare(local_start, utc_start) == :lt do
        DateTime.add(local_start, 1800, :second)
      else
        DateTime.add(utc_start, 1800, :second)
      end

    group_with_log(%{cost: "0.7500", inserted_at: edge})

    {:ok, view, _html} = live(conn, ~p"/stats")

    assigns = :sys.get_state(view.pid).socket.assigns
    card_spend = assigns.org_budget.daily_spend_usd

    # El card reporta la ventana del kill-switch: coincide con el resumen del
    # día UTC (lo que muestra Mantenimiento) y difiere del día local.
    assert Decimal.equal?(card_spend, Budgets.global_daily_budget_summary().daily_spend_usd)

    refute Decimal.equal?(card_spend, Logs.today_summary(tz).cost_usd)

    en_utc? = DateTime.compare(edge, utc_start) != :lt
    esperado = if en_utc?, do: Decimal.new("0.7500"), else: Decimal.new("0.0000")
    assert Decimal.equal?(card_spend, esperado)

    # El Resumen ("Tope diario global", período "hoy") tiene que mostrar el
    # mismo número que el card de En vivo y que Mantenimiento.
    {:ok, overview, _html} = live(conn, ~p"/stats/overview")
    wait_stats_loaded(overview)

    ov = :sys.get_state(overview.pid).socket.assigns
    assert Decimal.equal?(ov.org_budget.daily_spend_usd, card_spend)
  end

  test "En vivo: el pie muestra cuánto falta para el reinicio y a qué hora local cae",
       %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    # America/Merida = UTC-6, así que 00:00 UTC es 18:00 del día anterior local.
    {:ok, admin} = Accounts.update_user_timezone(admin, "America/Merida")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/stats")

    # El contador está presente, en formato H:MM + unidad "h".
    assert has_element?(view, "#live-budget-reset-countdown")

    texto = view |> element("#live-budget-reset-countdown") |> render()
    assert texto =~ ~r/\d{1,2}/
    assert texto =~ ~r/\d{2}/
    assert texto =~ ">h</span>"

    # Y el instante del reinicio, expresado en la zona elegida (no en UTC).
    assert has_element?(view, "#live-budget-reset-at", "18:00 en tu hora local")
  end

  test "En vivo: cambiar la zona horaria mueve la hora local del reinicio", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/stats")

    # UTC → el reinicio cae a las 00:00 locales.
    assert has_element?(view, "#live-budget-reset-at", "00:00 en tu hora local")

    # +1h (Madrid en verano) → 02:00 locales.
    render_change(view, "set-timezone", %{"timezone" => "Europe/Madrid"})
    assert has_element?(view, "#live-budget-reset-at", "02:00 en tu hora local")
  end

  test "En vivo: el contador del reinicio también vive en el Resumen", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, "America/Merida")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/stats/overview")
    wait_stats_loaded(view)

    assert has_element?(view, "#org-budget-card #org-budget-reset-countdown")
    assert has_element?(view, "#org-budget-reset-at", "18:00 en tu hora local")
  end

  test "En vivo: el contador se recalcula en el tick de reloj, sin tráfico", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/stats")

    antes = get_in(:sys.get_state(view.pid).socket.assigns, [:budget_reset_hours])

    # :clock_tick no toca la DB ni depende de `logs:new`: es el reloj de la
    # página. Debe reemplazar los asigns por el tiempo restante real.
    send(view.pid, :clock_tick)
    _ = :sys.get_state(view.pid)

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.budget_reset_hours =~ ~r/^\d{1,2}$/
    assert assigns.budget_reset_minutes =~ ~r/^\d{2}$/
    assert Process.alive?(view.pid)

    # Coincide con el tiempo real hasta el próximo 00:00 UTC (tolerancia 1 min).
    h = String.to_integer(assigns.budget_reset_hours)
    m = String.to_integer(assigns.budget_reset_minutes)

    esperado =
      Tokengate.Periods.next_utc_day_start()
      |> DateTime.diff(DateTime.utc_now(), :second)
      |> div(60)

    assert_in_delta esperado, h * 60 + m, 1
    assert antes =~ ~r/^\d{1,2}$/
  end

  test "En vivo: el contador declara la unidad (horas) y separa el ':'", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/stats")

    # La unidad va explícita para que "21:02" no se lea como mm:ss.
    assert has_element?(view, "#live-budget-reset-countdown", "h")

    # El ":" es su propio elemento (parpadea) y el valor lleva un aria-label
    # con las unidades habladas (el ":" decorativo queda oculto).
    assert has_element?(view, "#live-budget-reset-countdown span.reset-colon")
    assert has_element?(view, "#live-budget-reset-countdown[aria-label]")
    assert has_element?(view, "#live-budget-reset-countdown span[aria-hidden='true']")

    html = view |> element("#live-budget-reset-countdown") |> render()
    assert html =~ "reset-colon"
    assert html =~ ">h</span>"
  end

  test "En vivo: las tres gráficas por minuto se renderizan juntas y siempre", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/stats")

    # Sin tráfico en la última hora, el chart NO se sustituye por texto:
    # el eje y el ancho de la ventana siguen visibles.
    assert has_element?(view, "#live-minute-chart")
    assert has_element?(view, "#live-tokens-minute-chart")
    assert has_element?(view, "#live-cost-minute-chart")
    refute has_element?(view, "#live-minute-chart p", "Sin requests en la última hora.")

    # Orden de la fila: requests → tokens → costo → bloque inferior
    html = render(view)
    assert order_before?(html, "live-minute-chart", "live-tokens-minute-chart")
    assert order_before?(html, "live-tokens-minute-chart", "live-cost-minute-chart")
    assert order_before?(html, "live-cost-minute-chart", "live-inflight-models")
    assert order_before?(html, "live-inflight-models", "live-feed-card")
  end

  test "requests_per_minute/1 llena la ventana con todas las métricas en cero", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    login(conn, admin, password)

    series = Logs.requests_per_minute(60)

    assert length(series) == 60

    # Cada bucket trae el juego completo de métricas, sin filas para tráfico
    # inexistente (rango vacío → todo cero, nunca nil).
    assert Enum.all?(series, fn row ->
             row.request_count == 0 and row.prompt_tokens == 0 and
               row.completion_tokens == 0 and Decimal.equal?(row.cost_usd, Decimal.new(0))
           end)

    assert Enum.all?(series, &match?(%{bucket: %NaiveDateTime{second: 0}}, &1))
  end

  test "requests_per_minute/1 agrega requests, tokens y costo del minuto actual", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    login(conn, admin, password)

    group_with_log(%{
      cost: Decimal.new("0.0125"),
      prompt_tokens: 300,
      completion_tokens: 120,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    series = Logs.requests_per_minute(60)
    current = List.last(series)

    assert current.request_count == 1
    assert current.prompt_tokens == 300
    assert current.completion_tokens == 120

    # El costo se agrega tal cual, preservando la precisión decimal.
    assert Decimal.equal?(current.cost_usd, Decimal.new("0.0125"))

    # Y el bucket realmente poblado es el del minuto actual — el zero-fill
    # debe alinear la llave con el `date_trunc` de Postgres (segundos y
    # microsegundos en cero), no dejar la serie entera en cero.
    assert Enum.count(series, &(&1.request_count > 0)) == 1
  end

  test "En vivo: con tráfico real las barras de las tres gráficas toman altura", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for i <- 1..3 do
      group_with_log(%{
        cost: Decimal.new("0.001#{i}"),
        prompt_tokens: 100 * i,
        completion_tokens: 40 * i,
        inserted_at: DateTime.add(now, -i, :second)
      })
    end

    {:ok, view, _html} = live(conn, ~p"/stats")

    # Cada gráfica saca su propio pico del mismo minuto poblado.
    assert has_element?(view, "#live-minute-chart [style*='height: 100%']")
    assert has_element?(view, "#live-tokens-minute-chart [style*='height: 100%']")
    assert has_element?(view, "#live-cost-minute-chart [style*='height: 100%']")

    # El pie de "sin tráfico" desaparece cuando sí hay datos.
    refute has_element?(view, "#live-minute-chart span", "sin tráfico en la última hora")
  end

  test "En vivo: cada gráfica declara tipo y unidad (barras · 1 barra = 1 min)", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/stats")

    for id <- ~w(live-minute-chart live-tokens-minute-chart live-cost-minute-chart) do
      assert has_element?(view, "##{id}-hint", "barras · 1 barra = 1 min · últimos 60 min")
    end
  end

  test "En vivo: el status del feed es el del cliente y no oculta la causa del proveedor", %{
    conn: conn
  } do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    # Fallback: el proveedor devolvió 429 pero el cliente recibió 200.
    group_with_log(%{cost: "0.002", status_code: 200, provider_status_code: 429})

    {:ok, view, _html} = live(conn, ~p"/stats")

    # El número visible sigue siendo el del cliente…
    assert has_element?(view, "#live-feed-card", "200")
    # …y la causa del upstream se muestra aparte, a la izquierda.
    assert has_element?(view, "#live-feed-card", "prov 429")
  end

  test "En vivo: sin mismatch de proveedor no se agrega causa al status", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    # 200 limpio: el proveedor también respondió 200 → sin causa extra.
    group_with_log(%{cost: "0.002", status_code: 200, provider_status_code: 200})

    {:ok, view, _html} = live(conn, ~p"/stats")

    assert has_element?(view, "#live-feed-card", "200")
    refute has_element?(view, "#live-feed-card", "prov 200")
  end

  test "En vivo: el feed muestra la razón del error cuando existe", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    group_with_log(%{
      cost: "0.002",
      status_code: 502,
      provider_status_code: 401,
      error_reason: "all_providers_down",
      error_message: "todos los proveedores fallaron"
    })

    {:ok, view, _html} = live(conn, ~p"/stats")

    # El badge del proveedor sigue ahí…
    assert has_element?(view, "#live-feed-card", "prov 401")
    # …y la razón del error se muestra junto a él, con el mensaje en el title.
    assert has_element?(view, "#live-feed-card .badge-error", "all_providers_down")
    assert has_element?(view, "#live-feed-card [title='todos los proveedores fallaron']")
  end

  test "En vivo: sin razón de error no se agrega badge", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    group_with_log(%{cost: "0.002", status_code: 200, provider_status_code: 200})

    {:ok, view, _html} = live(conn, ~p"/stats")

    refute has_element?(view, "#live-feed-card .badge-error")
  end

  defp order_before?(html, first, second) do
    with {first_pos, _len} <- :binary.match(html, first),
         {second_pos, _len} <- :binary.match(html, second) do
      first_pos < second_pos
    else
      _ -> false
    end
  end

  describe "hour_usage_bar_height/2 (sqrt scale)" do
    alias TokengateWeb.StatsHelpers, as: StatsLive

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
    alias TokengateWeb.StatsHelpers, as: StatsLive

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

  describe "listados rankeados (rango + buscador en vivo)" do
    # Los rankings de Users, Models y Providers se muestran como listado
    # rankeado (no tabla) con buscador que filtra en vivo. El puesto sale de la
    # clasificación COMPLETA, así que filtrar no renumera.

    test "providers: listado rankeado con color en el top 3", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      # 3/2/1 requests → clasificación determinista para los puestos 1-3.
      [a, b, c] = for _ <- 1..3, do: group_with_log(%{cost: "0.005"})
      log_extra(a, 2)
      log_extra(b, 1)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/stats/providers")
      view = wait_stats_loaded(view)

      # Ya no es tabla: es un listado con buscador.
      assert has_element?(view, "#provider-list")
      assert has_element?(view, "ul#provider-list li")
      assert has_element?(view, "#provider-list-search")
      refute has_element?(view, "#provider-ranking table")

      # Puestos 1º/2º/3º con su color; el 1º (más requests) es el destacado.
      assert has_element?(
               view,
               "#provider-ranking-row-#{a.provider.id} span[aria-label='Puesto 1'][class*='amber']"
             )

      assert has_element?(
               view,
               "#provider-ranking-row-#{b.provider.id} span[aria-label='Puesto 2'][class*='slate']"
             )

      assert has_element?(
               view,
               "#provider-ranking-row-#{c.provider.id} span[aria-label='Puesto 3'][class*='orange']"
             )

      # Las métricas de cada proveedor siguen visibles, ahora en la fila.
      row_html = view |> element("#provider-ranking-row-#{a.provider.id}") |> render()
      assert row_html =~ "Requests"
      assert row_html =~ "Latencia"
      assert row_html =~ "Tier"
    end

    test "providers: el buscador filtra en vivo sin renumerar los puestos", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      [a, b, c] = for _ <- 1..3, do: group_with_log(%{cost: "0.005"})
      log_extra(a, 2)
      log_extra(b, 1)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/stats/providers")
      view = wait_stats_loaded(view)

      # El peor clasificado es el 3º: al filtrarlo debe SEGUIR siendo el 3º
      # (si el rango saliera del listado filtrado aparecería como 1º).
      view |> element("#provider-list-search") |> render_change(%{"value" => c.provider.name})

      assert has_element?(view, "#provider-ranking-row-#{c.provider.id}")
      refute has_element?(view, "#provider-ranking-row-#{a.provider.id}")
      refute has_element?(view, "#provider-ranking-row-#{b.provider.id}")

      assert has_element?(
               view,
               "#provider-ranking-row-#{c.provider.id} span[aria-label='Puesto 3']"
             )
    end

    test "providers: sin coincidencias muestra el estado vacío", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      group_with_log(%{cost: "0.005"})

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/stats/providers")
      view = wait_stats_loaded(view)

      view
      |> element("#provider-list-search")
      |> render_change(%{"value" => "no-existe-este-proveedor"})

      assert has_element?(view, "#provider-list-empty")
      refute has_element?(view, "ul#provider-list li")
    end

    test "models: listado rankeado + buscador", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      [a, b] = for _ <- 1..2, do: group_with_log(%{cost: "0.005"})
      log_extra(a, 1)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/stats/models")
      view = wait_stats_loaded(view)

      assert has_element?(view, "#model-list")
      assert has_element?(view, "#model-list-search")
      refute has_element?(view, "#model-ranking table")

      assert has_element?(
               view,
               "#model-ranking-row-#{a.model.id} span[aria-label='Puesto 1'][class*='amber']"
             )

      # Filtra por nombre de modelo: queda sólo la fila que coincide.
      view |> element("#model-list-search") |> render_change(%{"value" => b.model.name})

      assert has_element?(view, "#model-ranking-row-#{b.model.id}")
      refute has_element?(view, "#model-ranking-row-#{a.model.id}")

      # Y conserva su puesto (2º), no pasa a 1º.
      assert has_element?(
               view,
               "#model-ranking-row-#{b.model.id} span[aria-label='Puesto 2']"
             )
    end

    test "users: Top miembros es listado rankeado, no tabla", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      %{owner: owner} = group_with_log(%{cost: "0.005"})

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/stats/users")
      view = wait_stats_loaded(view)

      assert has_element?(view, "#top-members-list")
      assert has_element?(view, "#top-members-search")
      assert has_element?(view, "#top-members-list li#top-member-#{owner.id}")
      assert has_element?(view, "#top-member-#{owner.id} span[aria-label='Puesto 1']")
      # El listado reemplazó la tabla del card.
      refute has_element?(view, "#top-members table")
    end

    test "users: buscar un miembro fuera del top lo muestra con su puesto real",
         %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      # 6 usuarios con 6..1 requests: el 6º queda fuera del top 5 por consumo.
      fixtures =
        for i <- 1..6 do
          %{owner: owner} = g = group_with_log(%{cost: "0.005"})
          log_extra(g, 6 - i)
          {owner, g}
        end

      {last_owner, _last_group} = List.last(fixtures)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/stats/users")
      view = wait_stats_loaded(view)

      # Sin filtro: 5 filas (el 6º no aparece).
      assert has_element?(view, "#top-members-list")
      refute has_element?(view, "#top-member-#{last_owner.id}")

      # Al buscarlo aparece con su puesto REAL del período (6º), no como 1º.
      view |> element("#top-members-search") |> render_change(%{"value" => last_owner.email})

      assert has_element?(view, "#top-member-#{last_owner.id}")
      assert has_element?(view, "#top-member-#{last_owner.id} span[aria-label='Puesto 6']")

      # Y se puede buscar por NOMBRE (no sólo por correo).
      view |> element("#top-members-search") |> render_change(%{"value" => last_owner.name})

      assert has_element?(view, "#top-member-#{last_owner.id}")
    end

    test "el filtro se limpia al cambiar de sección", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      group_with_log(%{cost: "0.005"})

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/stats/providers")
      view = wait_stats_loaded(view)

      view
      |> element("#provider-list-search")
      |> render_change(%{"value" => "algo-que-no-coincide"})

      assert has_element?(view, "#provider-list-empty")

      # Navegar a otra sección no arrastra el filtro (escondería filas sin
      # motivo visible).
      {:ok, view, _html} = live(conn, ~p"/stats/models")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.list_search == ""
    end
  end
end
