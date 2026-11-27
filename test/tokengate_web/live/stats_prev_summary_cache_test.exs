defmodule TokengateWeb.StatsPrevSummaryCacheTest do
  @moduledoc """
  Shared caches of the stats surface: the previous-window summary of the
  Resumen (`/stats/overview`), the current-window counters, and the
  structural bundle of EVERY tab.

  El resumen de la ventana ANTERIOR va por `DashboardCache` con TTL de 60 s:
  la ventana está cerrada e inmutable, pero el Resumen se recarga por
  `logs:new` cada ~3 s por visor y cada uno re-ejecutaba el agregado.

  El cache de stats está apagado en `config/test.exs` (el ETS se comparte
  entre tests), así que este archivo lo enciende para sus casos y lo
  restaura.
  """

  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.Accounts
  alias Tokengate.Metrics.DashboardCache

  @table :tokengate_dashboard_cache

  defp unique, do: System.unique_integer([:positive])

  defp register_admin do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "prevsummary-#{u}@example.com",
        name: "Prev #{u}",
        password: "password-secret-#{u}1",
        global_role: "admin"
      })

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  setup do
    previous = Application.get_env(:tokengate, :stats_structural_cache)
    Application.put_env(:tokengate, :stats_structural_cache, enabled: true)
    DashboardCache.invalidate_all()

    on_exit(fn ->
      Application.put_env(:tokengate, :stats_structural_cache, previous)
      DashboardCache.invalidate_all()
    end)

    :ok
  end

  test "the previous-window summary is cached for the closed window", %{conn: conn} do
    %{user: user, password: password} = register_admin()
    conn = login(conn, user, password)

    {:ok, view, _html} = live(conn, ~p"/stats/overview?period=today")
    wait_assign(view, &(!&1.stats_loading))
    # Los contadores (resumen actual + el anterior) llegan en su propia tarea.
    wait_assign(view, &(&1[:prev_metrics] != nil))

    entries = prev_entries()
    assert [{key, _summary, expires_at}] = entries
    assert match?({:stats_prev_summary, nil, nil, "today", _tz, nil}, key)

    # TTL del cache: la ventana cerrada se comparte 60 s (no se recalcula en
    # cada una de las recargas de contadores del visor).
    now = System.monotonic_time(:millisecond)
    assert expires_at - now > 50_000
    assert expires_at - now <= 60_000

    # Envenena la entrada: la recarga de contadores debe LEERLA (mismo
    # deadline, valor servido tal cual) en vez de volver a agregar la ventana.
    poisoned = %{
      total_cost_usd: Decimal.new(0),
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      request_count: 999_999,
      avg_tps: nil
    }

    :ets.insert(@table, {key, poisoned, expires_at})

    send(view.pid, :reload_counters)

    # `prev_metrics` es el resumen anterior ya convertido a las llaves de KPI
    # (`requests_total`), no el map de `fetch_summary/2`.
    wait_assign(view, fn assigns ->
      match?(%{requests_total: 999_999}, assigns[:prev_metrics])
    end)

    # La entrada sigue siendo la misma (nadie la reescribió con un recompute).
    assert [{^key, _poisoned, ^expires_at}] = prev_entries()
  end

  test "the current-window summary is shared between viewers", %{conn: conn} do
    %{user: user, password: password} = register_admin()
    conn = login(conn, user, password)

    {:ok, view, _html} = live(conn, ~p"/stats/overview?period=today")
    wait_assign(view, &(!&1.stats_loading))
    wait_until(fn -> current_entries() != [] end)

    assert [{key, _summary, expires_at}] = current_entries()
    assert match?({:stats_current_summary, nil, nil, "today", _tz, nil}, key)

    # TTL corto pero mayor que el tick de 3 s: el siguiente tick de cada visor
    # lee esta entrada en vez de recalcular su propio resumen.
    now = System.monotonic_time(:millisecond)
    assert expires_at - now > 0
    assert expires_at - now <= 3_500

    # Envenena el resumen del período actual con un deadline nuevo (el valor
    # servido es lo que importa): un segundo visor que monta la misma página
    # debe leerlo del cache en vez de agregar la ventana.
    poisoned = %{
      total_cost_usd: Decimal.new(0),
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      request_count: 777_777,
      avg_tps: nil
    }

    :ets.insert(@table, {key, poisoned, now + 30_000})

    {:ok, viewer2, _html} = live(conn, ~p"/stats/overview?period=today")

    wait_assign(viewer2, fn assigns ->
      match?(%{requests_total: 777_777}, assigns[:metrics])
    end)

    # Un tercer visor con OTRO período no hereda la entrada: la clave lleva
    # el período (y el scope), no solo la pestaña.
    {:ok, other_period, _html} = live(conn, ~p"/stats/overview?period=week")
    wait_assign(other_period, &(!&1.stats_loading))

    refute match?(
             %{requests_total: 777_777},
             :sys.get_state(other_period.pid).socket.assigns.metrics
           )
  end

  test "every tab serves its bundle from the structural cache", %{conn: conn} do
    %{user: user, password: password} = register_admin()
    conn = login(conn, user, password)

    # Una pestaña que NO es el Resumen: ranked providers (percentile_cont,
    # p95, fallos) — antes corría completa en cada clic y por visor.
    {:ok, view, _html} = live(conn, ~p"/stats/providers?period=today")
    wait_assign(view, &(!&1.stats_loading))

    assert [
             {{:stats_structural, :providers, "today", _tz, nil, nil, nil, nil, nil, nil, nil,
               nil}, _bundle, _}
           ] =
             structural_entries(:providers)

    # Segundo visor del mismo scope/período: el bundle sale del cache, así que
    # no toca las tablas de logs ni el rollup.
    {queries, _} =
      count_queries(fn ->
        {:ok, viewer2, _html} = live(conn, ~p"/stats/providers?period=today")
        wait_assign(viewer2, &(!&1.stats_loading))
      end)

    assert queries == []
  end

  test "tabs that do not render the counters do not compute the period summaries", %{conn: conn} do
    %{user: user, password: password} = register_admin()
    conn = login(conn, user, password)

    # Servicios no pinta `@metrics`: sus dos summaries híbridos (cada uno con
    # el guard de cobertura) eran trabajo completo descartado en el render.
    {queries, _} =
      count_queries(fn ->
        {:ok, view, _html} = live(conn, ~p"/stats/services?period=today")
        wait_assign(view, &(!&1.stats_loading))
      end)

    refute Enum.any?(queries, &summary_query?/1)
  end

  defp structural_entries(live_action) do
    :ets.tab2list(@table)
    |> Enum.filter(fn
      {{:stats_structural, ^live_action, _, _, _, _, _, _, _, _, _, _}, _bundle, _expires_at} ->
        true

      _ ->
        false
    end)
  end

  # Queries against the log/rollup tables issued while `fun` runs. Telemetry
  # fires in the querying process; the messages are drained when `fun` returns.
  defp count_queries(fun) do
    parent = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:tokengate, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        sql = metadata[:query] || ""

        if String.contains?(sql, ["request_logs", "request_metrics_hourly"]) do
          send(parent, {ref, sql})
        end
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler_id)

    {drain_queries(ref, []), result}
  end

  defp drain_queries(ref, acc) do
    receive do
      {^ref, sql} -> drain_queries(ref, [sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The KPI summary aggregate (`Logs.cost_summary`): sums plus a count(id).
  defp summary_query?(sql),
    do: String.contains?(sql, "SUM(provider_cost_usd)") and String.contains?(sql, "count(")

  # Claves del resumen anterior que este test dejó en el cache.
  defp prev_entries do
    :ets.tab2list(@table)
    |> Enum.filter(fn
      {{:stats_prev_summary, _, _, _, _, _}, _summary, _expires_at} -> true
      _ -> false
    end)
  end

  # Resumen del período ACTUAL (la mitad caras de los contadores del Resumen).
  defp current_entries do
    :ets.tab2list(@table)
    |> Enum.filter(fn
      {{:stats_current_summary, _, _, _, _, _}, _summary, _expires_at} -> true
      _ -> false
    end)
  end

  defp wait_assign(view, fun, attempts \\ 400)

  defp wait_assign(view, fun, attempts) when attempts > 0 do
    assigns = :sys.get_state(view.pid).socket.assigns

    if fun.(assigns) do
      view
    else
      Process.sleep(10)
      wait_assign(view, fun, attempts - 1)
    end
  end

  defp wait_assign(_view, _fun, 0), do: flunk("timed out waiting for the LiveView assign")

  defp wait_until(fun, attempts \\ 400)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("timed out waiting for the condition")
end
