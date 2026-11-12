defmodule TokengateWeb.StatsPrevSummaryCacheTest do
  @moduledoc """
  El resumen de la ventana ANTERIOR del Resumen (`/stats/overview`) va por
  `DashboardCache` con TTL de 60 s: la ventana está cerrada e inmutable, pero
  el Resumen se recarga por `logs:new` cada ~3 s por visor y cada uno
  re-ejecutaba el agregado.

  El cache de stats está apagado en `config/test.exs` (el ETS se comparte
  entre tests), así que este archivo lo enciende para el caso y lo restaura.
  El test envenena la entrada cacheada y fuerza una recarga de contadores: si
  el delta del KPI sale del veneno, la recarga leyó del cache y no re-ejecutó
  el agregado.
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

  # Claves del resumen anterior que este test dejó en el cache.
  defp prev_entries do
    :ets.tab2list(@table)
    |> Enum.filter(fn
      {{:stats_prev_summary, _, _, _, _, _}, _summary, _expires_at} -> true
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
end
