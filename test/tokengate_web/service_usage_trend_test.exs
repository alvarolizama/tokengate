defmodule TokengateWeb.ServiceUsageTrendTest do
  @moduledoc """
  Regresión del chart "Spend & requests" del Overview de un servicio
  (`TokengateWeb.ServiceStatsBody.service_usage_trend/1`) y del chart apilado
  compartido de `/stats` (`StatsLive.DailyStackedChart`).

  Dos fallas que el usuario ve como "la gráfica no se ve":

    1. Los segmentos se pintan con `height: X%`. Un porcentaje dentro de un
       contenedor de **alto automático** resuelve a `auto`, así que las barras
       medían 0px: la tarjeta se veía con su título, su eje y su leyenda, pero
       el área de la gráfica quedaba vacía. El contenedor de la pila necesita
       una altura definida (`h-full`).
    2. La tarjeta entera iba envuelta en `:if={@rows != []}`: sin tráfico en la
       ventana desaparecía sin empty-state y parecía rota. Ahora se renderiza
       siempre, con su mensaje.

  El primer punto no se puede verificar sin navegador (es CSS), así que el test
  afirma el contrato del markup: el wrapper de la pila lleva `h-full` y cada
  segmento lleva su `height` en porcentaje. Las aserciones van sobre el HTML
  crudo porque `LazyHTML.query/2` devuelve matches duplicados cuando dos tests
  del mismo proceso consultan el mismo selector.
  """
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias TokengateWeb.ServiceStatsBody

  defp day(offset) do
    DateTime.new!(~D[2026-11-20], ~T[00:00:00], "Etc/UTC") |> DateTime.add(offset, :day)
  end

  # Filas tal como las entrega `Rollup.usage_series_by_model_for_service/2`.
  defp rows do
    [
      %{date: day(0), label: "gpt-4o", request_count: 40, total_cost_usd: Decimal.new("0.30")},
      %{date: day(0), label: "claude", request_count: 10, total_cost_usd: Decimal.new("0.05")},
      %{date: day(1), label: "gpt-4o", request_count: 90, total_cost_usd: Decimal.new("0.70")}
    ]
  end

  defp render_trend(overrides \\ []) do
    assigns =
      Keyword.merge(
        [
          id: "service-usage-trend",
          rows: rows(),
          granularity: :day,
          period: "30d",
          total_cost: Decimal.new("1.05")
        ],
        overrides
      )

    render_component(&ServiceStatsBody.service_usage_trend/1, assigns)
  end

  # Alturas (en %) de los segmentos apilados; 0 = no se pintó ninguna barra.
  defp segment_heights(html) do
    ~r/class="w-full shrink-0[^"]*"\s+style="height: ([\d.]+)%"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, pct] -> pct |> Float.parse() |> elem(0) end)
  end

  # Alturas (en %) de las barras completas (una por bucket).
  defp bar_heights(html) do
    ~r/class="w-full flex flex-col-reverse[^"]*"\s+style="height: ([\d.]+)%"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, pct] -> pct |> Float.parse() |> elem(0) end)
  end

  describe "con tráfico" do
    test "la tarjeta, la leyenda y las barras existen" do
      html = render_trend()

      assert html =~ ~s(id="service-usage-trend")
      assert html =~ "Spend &amp; requests"
      assert html =~ ~s(id="service-usage-trend-legend")

      # Leyenda ordenada por gasto descendente: gpt-4o ($1.00) antes que claude.
      assert html =~ ~r/id="service-usage-trend-legend".*gpt-4o.*claude/s
    end

    test "la barra se escala por el total del bucket y los segmentos no desbordan" do
      html = render_trend()

      # El alto de la barra va en la pila: sin altura propia (contenedor de alto
      # automático) los `height: X%` de los segmentos colapsan a 0px y la
      # gráfica se ve vacía.
      bars = bar_heights(html)
      # Dos días.
      assert length(bars) == 2
      # El día más cargado (90 requests) llega al 100% del área.
      assert Enum.max(bars) == 100.0
      # El de 50 requests: sqrt(50/90) → ~74.5%, no 100%.
      assert Enum.min(bars) < 80.0

      heights = segment_heights(html)
      # Dos días × dos modelos.
      assert length(heights) == 4
      # Cada bucket reparte 100% entre sus modelos: día 0 = 40/10 → 80/20,
      # día 1 = 90/0 → 100/0. Nunca suman de más (el apilado se recortaba).
      assert heights == [80.0, 20.0, 100.0, 0.0]
    end
  end

  describe "sin tráfico en la ventana" do
    test "la tarjeta se queda con su empty-state en vez de desaparecer" do
      html = render_trend(rows: [], total_cost: Decimal.new(0))

      assert html =~ ~s(id="service-usage-trend")
      assert html =~ ~s(id="service-usage-trend-empty")
      assert html =~ "No requests in this period."
      # Sin barras, sin eje y sin leyenda vacíos.
      refute html =~ "flex-col-reverse"
      refute html =~ "service-usage-trend-legend"
    end
  end

  describe "chart apilado compartido de /stats" do
    test "también escala la barra por el total del día" do
      html =
        render_component(&TokengateWeb.StatsLive.DailyStackedChart.daily_stacked_chart/1,
          id: "daily-stacked",
          title: "Uso diario",
          period: "30d",
          series: rows(),
          labels: ["gpt-4o", "claude"]
        )

      assert html =~ ~s(id="daily-stacked")

      bars = bar_heights(html)
      assert length(bars) == 2
      assert Enum.max(bars) == 100.0
      assert Enum.min(bars) < 80.0

      # Día 0: 40/10 → 80/20. Día 1: 90/0 → 100/0.
      assert segment_heights(html) == [80.0, 20.0, 100.0, 0.0]
    end
  end

  describe "en la página del servicio supervisado" do
    defp unique, do: System.unique_integer([:positive])

    defp register do
      u = unique()

      {:ok, user} =
        Accounts.register_user(%{
          email: "trend-live-#{u}@example.com",
          name: "Trend Live #{u}",
          password: "password-secret-#{u}1",
          global_role: "user"
        })

      %{user: user, password: "password-secret-#{u}1"}
    end

    defp login(conn, user, password) do
      conn
      |> post(~p"/login", %{email: user.email, password: password})
      |> recycle()
    end

    defp service_with_supervisor(user) do
      {:ok, group} = Accounts.create_group(%{name: "Trend #{unique()}"})

      {:ok, service} =
        Accounts.create_service(%{"name" => "Trend #{unique()}", "group_id" => group.id})

      {:ok, _} = Accounts.add_service_supervisor(service.id, user.id)
      service
    end

    defp log_for(service) do
      Logs.log_request(%{
        subject_type: "service",
        service_id: service.id,
        model_requested: "trend-model",
        model_responded: "trend-model",
        status_code: 200,
        prompt_tokens: 1_000,
        completion_tokens: 500,
        provider_cost_usd: Decimal.new("0.25"),
        latency_ms: 400
      })
    end

    defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns

    defp wait_loaded(view, tries \\ 100) do
      cond do
        assigns_of(view).stats_loading == false ->
          :ok

        tries == 0 ->
          flunk("timed out waiting for the stats load")

        true ->
          Process.sleep(50)
          wait_loaded(view, tries - 1)
      end
    end

    test "con tráfico el chart se pinta en el Overview", %{conn: conn} do
      %{user: user, password: password} = register()
      service = service_with_supervisor(user)
      {:ok, _} = log_for(service)

      conn = login(conn, user, password)

      {:ok, view, _html} =
        live(conn, ~p"/services/supervised/#{service.id}?tab=overview&period=30d")

      wait_loaded(view)

      assert assigns_of(view).usage_series != []
      assert has_element?(view, "#service-usage-trend")
      assert has_element?(view, "#service-usage-trend-legend")
      refute has_element?(view, "#service-usage-trend-empty")
    end

    test "sin tráfico el chart sigue visible con su empty-state", %{conn: conn} do
      %{user: user, password: password} = register()
      service = service_with_supervisor(user)

      conn = login(conn, user, password)
      {:ok, view, _html} = live(conn, ~p"/services/supervised/#{service.id}?tab=overview")

      wait_loaded(view)

      assert has_element?(view, "#service-usage-trend")
      assert has_element?(view, "#service-usage-trend-empty")
    end
  end
end
