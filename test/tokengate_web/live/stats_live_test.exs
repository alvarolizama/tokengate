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

  test "hour distribution excludes the previous local day", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, "America/Mexico_City")

    # 23:00 del día anterior local → fuera de "Hoy" local
    today_start = Periods.start_of_day_utc("America/Mexico_City")
    group_with_log(%{cost: "0.005", inserted_at: DateTime.add(today_start, -3600, :second)})

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
end
