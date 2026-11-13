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

  for period <- ~w(today week month last_month 30d) do
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
