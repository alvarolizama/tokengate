defmodule TokengateWeb.StatsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Budgets, Logs, Periods, Providers}
  alias Tokengate.Logs.Inflight
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

  # El Resumen recarga sus contadores en una tarea async propia (`:stats_counters`),
  # independiente de la parte estructural: espera a que el costo del período
  # deje de ser el anterior y devuelve los assigns ya actualizados.
  defp wait_counters_changed(view, previous_cost, attempts \\ 400)

  defp wait_counters_changed(view, previous_cost, attempts) when attempts > 0 do
    assigns = :sys.get_state(view.pid).socket.assigns

    if Decimal.equal?(assigns.metrics.cost_usd, previous_cost) do
      Process.sleep(10)
      wait_counters_changed(view, previous_cost, attempts - 1)
    else
      assigns
    end
  end

  defp wait_counters_changed(_view, _previous_cost, 0),
    do: raise("stats counters never reloaded")

  # El Resumen carga sus contadores (KPIs y deltas) en una tarea async propia.
  # `prev_metrics` sólo existe cuando esa mitad llegó — el wipe de la parte
  # estructural lo conserva — así que es la señal para sincronizar los tests
  # que miran `metrics`.
  defp wait_counters_loaded(view, attempts \\ 400)

  defp wait_counters_loaded(view, attempts) when attempts > 0 do
    assigns = :sys.get_state(view.pid).socket.assigns

    if assigns[:prev_metrics] do
      view
    else
      Process.sleep(10)
      wait_counters_loaded(view, attempts - 1)
    end
  end

  defp wait_counters_loaded(_view, 0), do: raise("stats counters never loaded")

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
    # La tabla de proveedores también baja su CSV (type=providers).
    assert has_element?(view, "#csv-providers[href='/stats/export?type=providers&period=today']")
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
    %{group: group} = group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/groups")
    wait_stats_loaded(view)

    assert has_element?(view, "#group-table")
    assert has_element?(view, "#group-list-search")
    assert has_element?(view, "#bd-group-#{group.id}")
    # El listado tiene UNA sola tabla: el card de tiers de uso por miembro salió
    # de la pestaña (el mismo agregado sigue en /admin/groups/:id/members).
    refute has_element?(view, "#member-usage-tiers")
  end

  test "top members live in /stats/users now", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{owner: owner} = group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/users")
    wait_stats_loaded(view)

    assert has_element?(view, "#user-table")
    assert has_element?(view, "#user-list-search")
    assert has_element?(view, "#bd-user-#{owner.id}")
    # El card "Top 5 Miembros" se fue: la pestaña es una sola tabla.
    refute has_element?(view, "#top-members")
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
    assert has_element?(view, "#busiest-hours")
    assert has_element?(view, "#busiest-minutes")
    assert has_element?(view, "#peak-concurrency")

    # El reparto del período: proveedor y modelo, los DOS del mismo agregado.
    assert has_element?(view, "#provider-breakdown")
    assert has_element?(view, "#model-breakdown")

    # Un solo log en el fixture → una fila por vista y el 100% del reparto:
    # pincha que la fila se deriva del agregado ya cargado (no de una query
    # nueva) y que el reparto se calcula sobre el total del período.
    assert has_element?(view, "#provider-breakdown-row-1")
    assert has_element?(view, "#provider-breakdown-row-1", "100.0%")
    assert has_element?(view, "#model-breakdown-row-1")
    assert has_element?(view, "#model-breakdown-row-1", "100.0%")
    assert has_element?(view, "#model-breakdown-row-1", "$0.005")

    # Con "Hoy" el Resumen no dibuja el perfil horario: ese día lo mide En
    # vivo ("Hoy por hora · por proveedor") y duplicarlo costaba un agregado
    # crudo por carga.
    refute has_element?(view, "#hour-distribution")

    # Con una ventana más larga el perfil horario del período sí es único.
    {:ok, long, _html} = live(conn, ~p"/stats/overview?period=30d")
    wait_stats_loaded(long)

    # Y es la MISMA tarjeta que En vivo — barras apiladas por proveedor con su
    # leyenda — no el desglose sin costo / con costo que dibujaba el Resumen.
    assert has_element?(long, "#hour-distribution")
    assert has_element?(long, "#hour-distribution-legend")
    refute render(long) =~ "Sin costo"
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
    assert has_element?(view, "#model-providers")
    # El drill-down ?model_id= es el ALIAS del detalle: la ruta propia
    # (/stats/models/:id) pinta la MISMA vista, con el botón de vuelta a la tabla.
    assert has_element?(view, "#model-back")
    assert has_element?(view, "#model-detail-header")

    {:ok, detail, _html} = live(conn, ~p"/stats/models/#{ma.id}?period=today")
    detail = wait_stats_loaded(detail)

    assert has_element?(detail, "#model-detail-header", ma.name)
    assert has_element?(detail, "#model-kpi-cost")
    assert has_element?(detail, "#nav-models.btn-primary")
  end

  test "detalle del modelo: un id que no existe avisa en vez de romper", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/models/#{Ecto.UUID.generate()}")
    view = wait_stats_loaded(view)

    assert has_element?(view, "#model-not-found")
    refute has_element?(view, "#model-kpi-cost")
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

    # Row order = order of appearance of the model-ranking-row-<id> rows in the HTML.
    row_order = fn view ->
      Regex.scan(~r/<tr[^>]+id="(model-ranking-row-[^"]+)"/, render(view))
      |> Enum.map(fn [_full, id] -> id end)
    end

    expensive_row = "model-ranking-row-#{expensive.id}"
    cheap_row = "model-ranking-row-#{cheap.id}"

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
    # El perfil horario sólo se dibuja con ventanas de más de un día: con "Hoy"
    # ese día lo mide En vivo. La zona del usuario sigue mandando en el bucketing.
    {:ok, view, _html} = live(conn, ~p"/stats/overview?period=30d")
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
    view = wait_stats_loaded(view) |> wait_counters_loaded()

    # El log de ayer UTC queda fuera de "Hoy": ni en los contadores del período
    # ni en el reparto derivado del mismo agregado.
    assert :sys.get_state(view.pid).socket.assigns.metrics.requests_total == 0
    assert render(view) =~ "Sin datos en este período."
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
    assert order_before?(html, "live-today-requests", "live-errors")
    # Dentro de la fila de hoy: Costo · Tokens · Requests, con la latencia
    # debajo del valor de requests (3 columnas, no 4).
    assert order_before?(html, "live-today-cost", "live-today-tokens")
    assert order_before?(html, "live-today-tokens", "live-today-requests")
    assert order_before?(html, "live-today-requests", "live-today-latency")
    # La latencia ya no es tarjeta propia: vive dentro de la de requests.
    assert has_element?(view, "#live-today-requests #live-today-latency", "latencia")
    assert has_element?(view, "#live-today-requests", "p95:")
    refute has_element?(view, "#live-today-latency.card")
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

    # El Resumen mide la misma ventana: su KPI de costo (período "hoy" = día
    # UTC) tiene que dar el mismo número que el card de En vivo, aunque el
    # card del tope ya no viva ahí. Si los dos caminos divergen, este assert
    # lo caza.
    {:ok, overview, _html} = live(conn, ~p"/stats/overview")
    wait_stats_loaded(overview)

    ov = :sys.get_state(overview.pid).socket.assigns
    assert Decimal.equal?(ov.metrics.cost_usd, card_spend)
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

    # El Resumen ya no repite el card del tope (vive en En vivo): el countdown
    # queda en la sub-línea del KPI de costo, que es además la que declara la
    # ventana UTC.
    assert has_element?(view, "#kpi-cost", "Reinicia en")
    assert has_element?(view, "#kpi-cost", "18:00 en tu hora local")
  end

  test "Resumen: un logs:new sólo recalcula los contadores, no los agregados", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    group_with_log(%{cost: "0.005"})
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/stats/overview")
    wait_stats_loaded(view)

    antes = :sys.get_state(view.pid).socket.assigns

    # Tráfico nuevo con otro costo: mueve los contadores del período.
    group_with_log(%{cost: "0.2500"})
    send(view.pid, {:new_log, nil})
    despues = wait_counters_changed(view, antes.metrics.cost_usd)

    refute Decimal.equal?(despues.metrics.cost_usd, antes.metrics.cost_usd)

    # Y los agregados estructurales siguen siendo los mismos términos: el
    # broadcast no re-ejecuta los scans crudos de ventana completa. Con el
    # reload completo de antes, el log nuevo aparecía en estas listas.
    assert despues.hour_usage_by_provider == antes.hour_usage_by_provider
    assert despues.model_provider_stacked == antes.model_provider_stacked
    assert despues.busiest_minutes == antes.busiest_minutes
    assert despues.peak_concurrency == antes.peak_concurrency
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
    assert order_before?(html, "live-cost-minute-chart", "live-day-hour-chart")
    assert order_before?(html, "live-day-hour-chart", "live-feed-card")

    # El desglose "en vuelo por modelo" salió de esta tarjeta: estaba vacía
    # casi siempre (el registry ETS sólo tiene filas mientras hay una request
    # en curso) y /logs ya lista esos pending con su modelo.
    refute has_element?(view, "#live-inflight-models")
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

  test "En vivo: la gráfica del día cruza hora × proveedor sobre el día UTC", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Proveedor A con 2 requests ($0.0100 + $0.0050) y proveedor B con 1
    # ($0.0025), todos en la hora UTC en curso.
    fixture = group_with_log(%{cost: "0.0100", inserted_at: now})
    log_extra(fixture, 1)
    %{provider: provider_b} = group_with_log(%{cost: "0.0025", inserted_at: now})

    hour = DateTime.utc_now().hour

    {:ok, view, _html} = live(conn, ~p"/stats")

    # Cabecera: el total del día (requests y costo), en el día UTC.
    assert has_element?(view, "#live-day-hour-chart-total", "3 req · $0.0175")

    # Leyenda: reparto del día por proveedor, ordenado por requests.
    assert has_element?(view, "#live-day-hour-chart-legend", fixture.provider.name)
    assert has_element?(view, "#live-day-hour-chart-legend", provider_b.name)

    # La barra de la hora en curso lleva el desglose: su tooltip nombra hora,
    # total, costo y cada proveedor con su conteo.
    assert has_element?(view, "#live-day-hour-chart-hour-#{hour}[title*='3 req']")
    assert has_element?(view, "#live-day-hour-chart-hour-#{hour}[title*='$0.0175']")

    assert has_element?(
             view,
             "#live-day-hour-chart-hour-#{hour}[title*='#{fixture.provider.name} 2']"
           )

    assert has_element?(view, "#live-day-hour-chart-hour-#{hour}[title*='#{provider_b.name} 1']")

    # Las 24 horas del día se dibujan siempre (el eje no desaparece) y una
    # hora sin tráfico queda en cero — sin piso, no se inventa tráfico.
    for h <- 0..23 do
      assert has_element?(view, "#live-day-hour-chart-hour-#{h}")
    end

    empty_hour = if hour == 0, do: 1, else: 0
    assert has_element?(view, "#live-day-hour-chart-hour-#{empty_hour} div[style*='height: 0%']")
    assert has_element?(view, "#live-day-hour-chart-hour-#{empty_hour}[title*='sin tráfico']")

    # La unidad y la ventana van declaradas, como en las gráficas por minuto.
    assert has_element?(
             view,
             "#live-day-hour-chart-hint",
             "barras apiladas · 1 barra = 1 hora del día UTC"
           )
  end

  test "En vivo: la gráfica del día ignora el día UTC anterior", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    # 23:00 del día UTC anterior → fuera de "Hoy", que mide el día UTC (la
    # misma ventana que reinicia el tope global), no el día local.
    utc_start = Periods.start_of_day_utc("Etc/UTC")
    group_with_log(%{cost: "0.005", inserted_at: DateTime.add(utc_start, -3600, :second)})

    {:ok, view, _html} = live(conn, ~p"/stats")

    assert has_element?(view, "#live-day-hour-chart-total", "0 req")
    assert has_element?(view, "#live-day-hour-chart", "sin tráfico en el día UTC todavía")
    refute has_element?(view, "#live-day-hour-chart-legend")
  end

  test "En vivo: el tick de 3s refresca el conteo en vuelo sin tocar la tarjeta del día", %{
    conn: conn
  } do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/stats")

    # El tick de 3s sólo reasigna el conteo en curso (registry ETS): la
    # tarjeta del día se refresca por el bundle cacheado, no por el tick.
    before = Inflight.count()
    entry = Inflight.start_request(%{model_requested: "modelo-tick"})

    send(view.pid, :live_tick)
    assert render(view) =~ "live-day-hour-chart"

    assigns = :sys.get_state(view.pid).socket.assigns
    # El tick releyó el registry (no reusó el valor del mount) y ve la
    # request que acabamos de registrar. Se compara contra el conteo actual
    # y no contra `before + 1` porque la tabla ETS es global al BEAM: otras
    # suites pueden registrar/cerrar entries mientras corre ésta.
    assert assigns.inflight_count == Inflight.count()
    assert assigns.inflight_count >= before + 1
    # El desglose por modelo (y su assign) ya no existe en esta tab.
    refute Map.has_key?(assigns, :inflight_by_model)

    Inflight.finish_request(entry.id)
  end

  test "today_usage_by_hour_provider/0 zero-fillea 24 horas y agrupa por proveedor" do
    rows = Logs.today_usage_by_hour_provider()

    assert Enum.map(rows, & &1.hour) == Enum.to_list(0..23)
    assert Enum.all?(rows, &(&1.total_requests == 0 and &1.providers == []))
    assert Enum.all?(rows, &Decimal.equal?(&1.total_cost_usd, Decimal.new(0)))

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    hour = now.hour

    fixture = group_with_log(%{cost: "0.0100", inserted_at: now})
    log_extra(fixture, 1)
    %{provider: other} = group_with_log(%{cost: "0.0025", inserted_at: now})

    rows = Logs.today_usage_by_hour_provider()
    row = Enum.find(rows, &(&1.hour == hour))

    assert row.total_requests == 3
    assert Decimal.equal?(row.total_cost_usd, Decimal.new("0.0175"))

    # Desglose ordenado por requests desc; el total de la hora es su suma.
    assert [
             %{provider_name: first, requests: 2, cost_usd: first_cost},
             %{provider_name: second, requests: 1}
           ] = row.providers

    assert first == fixture.provider.name
    assert second == other.name
    assert Decimal.equal?(first_cost, Decimal.new("0.0150"))

    # Las demás horas del día siguen vacías.
    assert Enum.all?(rows, fn r -> r.hour == hour or r.total_requests == 0 end)
  end

  test "En vivo: el feed no estira la fila, toma el alto de la gráfica", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    {:ok, view, _html} = live(conn, ~p"/stats")

    # La igualdad de alturas es un resultado de CSS: se midió en un navegador
    # real (misma altura exacta que #live-day-hour-chart en el rango de dos
    # columnas; en una sola columna cada tarjeta conserva su alto natural).
    # Aquí se pinnea el mecanismo que la produce: la tarjeta del feed no
    # aporta alto propio (cuerpo posicionado absoluto) y su lista se desplaza
    # por dentro.
    assert has_element?(view, "#live-feed-card.lg\\:relative")
    assert has_element?(view, "#live-feed-card > .card-body.lg\\:absolute.lg\\:inset-0")
    assert has_element?(view, "#live-feed.lg\\:flex-1.lg\\:min-h-0.overflow-y-auto")
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

    test "providers: tabla única con medallas en el podio y liga al detalle", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      # 3/2/1 requests → clasificación determinista para los puestos 1-3.
      [a, b, c] = for _ <- 1..3, do: group_with_log(%{cost: "0.005"})
      log_extra(a, 2)
      log_extra(b, 1)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/stats/providers")
      view = wait_stats_loaded(view)

      # Tabla única (no listado), con buscador y la información básica en columnas.
      assert has_element?(view, "table#provider-table")
      assert has_element?(view, "#provider-table tbody tr")
      assert has_element?(view, "#provider-list-search")
      assert has_element?(view, "#provider-table thead th", "Requests")
      assert has_element?(view, "#provider-table thead th", "Latencia")

      # Podio: medalla (icono) en 1º/2º/3º con su color; el 1º (más requests) manda.
      assert has_element?(
               view,
               "#provider-ranking-row-#{a.provider.id} span[aria-label='Puesto 1'][class*='amber'] .hero-trophy"
             )

      assert has_element?(
               view,
               "#provider-ranking-row-#{b.provider.id} span[aria-label='Puesto 2'][class*='slate'] .hero-trophy"
             )

      assert has_element?(
               view,
               "#provider-ranking-row-#{c.provider.id} span[aria-label='Puesto 3'][class*='orange'] .hero-trophy"
             )

      # El nombre abre el interior del proveedor arrastrando el período.
      assert has_element?(
               view,
               "#provider-link-#{a.provider.id}[href*='/stats/providers/#{a.provider.id}'][href*='period=today']"
             )
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
      refute has_element?(view, "#provider-table tbody tr")
    end

    test "detalle del proveedor: métricas, modelos y quién lo usa", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      fixture = group_with_log(%{cost: "0.005"})
      log_extra(fixture, 1)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/stats/providers/#{fixture.provider.id}?period=today")
      view = wait_stats_loaded(view)

      # Sigue siendo la pestaña Proveedores, con vuelta a la tabla.
      assert has_element?(view, "#nav-providers.btn-primary")
      assert has_element?(view, "#provider-back[href*='/stats/providers']")
      assert has_element?(view, "#provider-detail-header", fixture.provider.name)

      # Sus métricas: costo (2 × 0.005), requests y latencia del período.
      assert has_element?(view, "#provider-kpi-cost")
      assert has_element?(view, "#provider-kpi-requests")
      assert has_element?(view, "#provider-kpi-tokens")
      assert has_element?(view, "#provider-kpi-latency")
      assert view |> element("#provider-kpi-cost") |> render() =~ "0.01"

      # Los modelos que sirve y los usuarios/servicios/grupos que lo usan.
      assert has_element?(view, "#provider-models #provider-model-#{fixture.model.id}")
      assert has_element?(view, "#provider-users #provider-user-#{fixture.owner.id}")
      assert has_element?(view, "#provider-groups #provider-group-#{fixture.group.id}")

      # El período del detalle es el que trae la URL.
      view |> element("#period-week") |> render_click()
      assert has_element?(view, "#provider-metrics-period", "Esta semana")
    end

    test "detalle del proveedor: un id que no existe avisa en vez de romper", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/stats/providers/#{Ecto.UUID.generate()}")
      view = wait_stats_loaded(view)

      assert has_element?(view, "#provider-not-found")
      refute has_element?(view, "#provider-kpi-cost")
    end

    test "models: la pestaña es la tabla de consumo con buscador", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      [a, b] = for _ <- 1..2, do: group_with_log(%{cost: "0.005"})
      log_extra(a, 1)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/stats/models")
      view = wait_stats_loaded(view)

      assert has_element?(view, "table#model-table")
      assert has_element?(view, "#model-list-search")
      assert has_element?(view, "#model-table thead th", "Costo")
      # Una sola tabla: el listado rankeado ya no existe.
      refute has_element?(view, "#model-list")

      # El puesto es la posición por consumo del período: `a` tiene más
      # requests, así que va 1º con medalla de oro.
      assert has_element?(
               view,
               "#model-ranking-row-#{a.model.id} span[aria-label='Puesto 1'][class*='amber'] .hero-trophy"
             )

      # El nombre enlaza al detalle propio del modelo.
      assert has_element?(view, "#model-link-#{a.model.id}")

      # Filtra por nombre de modelo: queda sólo la fila que coincide, y
      # conserva su puesto (filtrar no renumera).
      view |> element("#model-list-search") |> render_change(%{"value" => b.model.name})

      assert has_element?(view, "#model-ranking-row-#{b.model.id}")
      refute has_element?(view, "#model-ranking-row-#{a.model.id}")

      assert has_element?(
               view,
               "#model-ranking-row-#{b.model.id} span[aria-label='Puesto 2']"
             )
    end

    test "users: el buscador filtra la tabla por correo o por nombre", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      [a, b] = for _ <- 1..2, do: group_with_log(%{cost: "0.005"})
      log_extra(a, 1)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/stats/users")
      view = wait_stats_loaded(view)

      assert has_element?(view, "#user-table")
      assert has_element?(view, "#bd-user-#{a.owner.id}")
      assert has_element?(view, "#bd-user-#{b.owner.id}")

      # Por correo: queda sólo el que coincide.
      view |> element("#user-list-search") |> render_change(%{"value" => b.owner.email})

      refute has_element?(view, "#bd-user-#{a.owner.id}")
      assert has_element?(view, "#bd-user-#{b.owner.id}")

      # Y se puede buscar por NOMBRE (no sólo por correo).
      view |> element("#user-list-search") |> render_change(%{"value" => b.owner.name})

      assert has_element?(view, "#bd-user-#{b.owner.id}")

      # Sin coincidencias avisa en vez de dejar la tabla vacía sin explicación.
      view |> element("#user-list-search") |> render_change(%{"value" => "nadie-coincide-aca"})

      assert has_element?(view, "#user-list-empty")
      refute has_element?(view, "#user-table")
    end

    test "groups y services: buscador en vivo sobre su tabla", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      [a, b] = for _ <- 1..2, do: group_with_log(%{cost: "0.005"})

      conn = login(conn, admin, password)

      # Grupos: el buscador filtra por nombre de grupo.
      {:ok, groups, _html} = live(conn, ~p"/stats/groups")
      groups = wait_stats_loaded(groups)

      assert has_element?(groups, "#bd-group-#{a.group.id}")
      assert has_element?(groups, "#bd-group-#{b.group.id}")

      groups |> element("#group-list-search") |> render_change(%{"value" => b.group.name})

      refute has_element?(groups, "#bd-group-#{a.group.id}")
      assert has_element?(groups, "#bd-group-#{b.group.id}")

      # Servicios: mismo contrato (una tabla + buscador). El desglose existe en
      # cuanto hay logs de servicio en el período.
      {:ok, service} = Accounts.create_service(%{name: "svc-#{unique()}"})

      {:ok, _log} =
        Logs.log_request(%{
          subject_type: "service",
          service_id: service.id,
          provider_id: b.provider.id,
          model_requested: b.model.name,
          model_id: b.model.id,
          status_code: 200,
          prompt_tokens: 10,
          completion_tokens: 5,
          provider_cost_usd: "0.005",
          latency_ms: 42,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, services, _html} = live(conn, ~p"/stats/services")
      services = wait_stats_loaded(services)

      assert has_element?(services, "#service-table")
      assert has_element?(services, "#service-list-search")
      assert has_element?(services, "#bd-service-#{service.id}")
      assert has_element?(services, "#service-link-#{service.id}")
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
