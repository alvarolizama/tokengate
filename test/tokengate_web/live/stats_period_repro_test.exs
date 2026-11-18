defmodule TokengateWeb.StatsPeriodReproTest do
  @moduledoc """
  Repro temporal del reporte del dueño: «da error en temporalidades de más de
  una semana». Monta /stats/overview con CADA periodo canónico y deja correr
  la carga async — el error (si existe) sale al procesar las tareas con esos
  rangos.
  """

  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.Accounts
  alias Tokengate.Repo

  setup do
    u = Ecto.UUID.generate()

    {:ok, user} =
      Accounts.register_user(%{
        email: "period-repro-#{u}@example.com",
        name: "Period Repro",
        password: "password-secret-#{u}1",
        global_role: "admin"
      })

    {:ok, user} = Accounts.update_user_locale(user, "es")

    conn =
      build_conn()
      |> post(~p"/login", %{email: user.email, password: "password-secret-#{u}1"})
      |> recycle()

    {:ok, conn: conn}
  end

  for period <- ~w(today yesterday week 30d) do
    test "overview con periodo #{period} no revienta", %{conn: conn} do
      _log = repro_log()

      conn = conn
      {:ok, view, _html} = live(conn, ~p"/stats/overview?period=#{unquote(period)}")
      view = wait_loaded(view)

      html = render(view)
      assert html =~ "Estadísticas"
      refute html =~ "Internal Server Error"
    end

    test "services tab con periodo #{period} no revienta", %{conn: conn} do
      conn = conn
      {:ok, view, _html} = live(conn, ~p"/stats/services?period=#{unquote(period)}")
      view = wait_loaded(view)

      assert render(view) =~ "Estadísticas"
    end

    test "users tab con periodo #{period} no revienta", %{conn: conn} do
      conn = conn
      {:ok, view, _html} = live(conn, ~p"/stats/users?period=#{unquote(period)}")
      view = wait_loaded(view)

      assert render(view) =~ "Estadísticas"
    end
  end

  # Ventana cerrada: las tres lecturas del cuerpo de stats (summary, tabla de
  # keys y matriz modelo × key) usan from Y to, así que "ayer" no arrastra el
  # día en curso. Es el bug de F2 tal cual: con sólo `from`, las tres sumaban de
  # más y la tabla dejaba de cuadrar con su KPI.
  describe "service stats body window" do
    test "ayer no suma hoy en summary, keys ni modelos" do
      {:ok, service} =
        Accounts.create_service(%{"name" => "bounds-#{Ecto.UUID.generate()}"})

      today = DateTime.utc_now() |> DateTime.truncate(:second)

      yesterday_mid =
        today
        |> DateTime.to_date()
        |> Date.add(-1)
        |> DateTime.new!(~T[12:00:00], "Etc/UTC")

      service_log(service, yesterday_mid)
      service_log(service, today)

      yesterday = compute(service, "yesterday")

      assert yesterday.summary.request_count == 1
      assert Enum.sum(Enum.map(yesterday.key_rows, & &1.stats.request_count)) == 1
      assert Enum.sum(Enum.map(yesterday.model_breakdown.rows, & &1.request_count)) == 1

      today_stats = compute(service, "today")

      assert today_stats.summary.request_count == 1
      assert Enum.sum(Enum.map(today_stats.model_breakdown.rows, & &1.request_count)) == 1
    end

    defp compute(service, period) do
      TokengateWeb.ServiceStatsBody.compute_stats_assigns(%{
        service_id: service.id,
        service_api_keys: [],
        period: period,
        timezone: "Etc/UTC",
        key_filter: "all"
      })
    end

    # Los filtros Desde/Hasta del form llegan como fecha ISO: compute_logs los
    # convierte a datetime ANTES de tocar Logs (antes viajaban como string y
    # Ecto.Query.CastError mataba el socket). Una fecha que no parsea se ignora.
    test "los filtros Desde/Hasta parsean a datetime y nunca revientan" do
      {:ok, service} = Accounts.create_service(%{"name" => "dates-#{Ecto.UUID.generate()}"})
      service_log(service, DateTime.utc_now() |> DateTime.truncate(:second))

      today = Date.utc_today() |> Date.to_iso8601()

      valid =
        logs_for(service, %{"from" => today, "to" => today}, "Etc/UTC")

      assert length(valid.logs) == 1

      # Un rango de ayer no trae el log de hoy: el filtro sí acota.
      yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

      assert logs_for(service, %{"from" => yesterday, "to" => yesterday}, "Etc/UTC").logs == []

      # Basura y params forjados: filtro ignorado, no crash.
      for garbage <- ["no-es-fecha", "2026-13-45", "2026-11-01T99:00:00", ["2026-11-01"]] do
        assert length(logs_for(service, %{"from" => garbage, "to" => garbage}, "Etc/UTC").logs) ==
                 1
      end

      # Medianoche local inexistente (spring-forward de Chile): el parseo cae al
      # primer instante válido del día en vez de reventar con DateTime.new!.
      assert length(logs_for(service, %{"from" => "2026-09-06"}, "America/Santiago").logs) == 1
    end

    defp logs_for(service, filters, timezone) do
      TokengateWeb.ServiceStatsBody.compute_logs(
        %{
          service_id: service.id,
          filters: Map.merge(TokengateWeb.ServiceStatsBody.default_filters(), filters),
          timezone: timezone,
          key_filter: "all",
          page_size: 50
        },
        :reset,
        nil
      )
    end

    defp service_log(service, at) do
      %Tokengate.Logs.RequestLog{}
      |> Ecto.Changeset.change(%{
        inserted_at: at,
        subject_type: "service",
        service_id: service.id,
        model_requested: "gpt-4o",
        status_code: 200,
        prompt_tokens: 5,
        completion_tokens: 5,
        provider_cost_usd: Decimal.new("0.001")
      })
      |> Repo.insert!()
    end
  end

  # Log de servicio con fecha de hace 95 días: cruza el borde de retención de
  # particiones (request_logs conserva 90 días) y de los rollups.
  defp repro_log do
    {:ok, service} = Accounts.create_service(%{"name" => "repro-#{Ecto.UUID.generate()}"})
    old = DateTime.add(DateTime.utc_now(), -95 * 86_400, :second) |> DateTime.truncate(:second)

    %Tokengate.Logs.RequestLog{}
    |> Ecto.Changeset.change(%{
      inserted_at: old,
      subject_type: "service",
      service_id: service.id,
      model_requested: "old-model",
      status_code: 200,
      prompt_tokens: 5,
      completion_tokens: 5,
      provider_cost_usd: Decimal.new("0.001")
    })
    |> Repo.insert()
  end

  defp wait_loaded(view, attempts \\ 200)

  defp wait_loaded(_view, 0), do: flunk("stats nunca terminó de cargar")

  defp wait_loaded(view, attempts) do
    # Leer el assign del socket (como wait_stats_loaded de stats_live_test):
    # el HTML miente — skeletons y clases de carga persisten sin indicar que
    # la carga siga en curso.
    state = :sys.get_state(view.pid)

    case get_in(state, [Access.key(:socket), Access.key(:assigns), Access.key(:stats_loading)]) do
      false ->
        view

      _other ->
        Process.sleep(50)
        wait_loaded(view, attempts - 1)
    end
  end
end
