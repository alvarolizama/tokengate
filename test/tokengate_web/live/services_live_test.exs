defmodule TokengateWeb.ServicesLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.Accounts

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "admin-#{u}@example.com",
        name: "Admin #{u}",
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

  defp service_fixture do
    {:ok, group} =
      Accounts.create_group(%{name: "Svc Group #{System.unique_integer([:positive])}"})

    {:ok, service} =
      Accounts.create_service(%{
        name: "Service #{System.unique_integer([:positive])}",
        group_id: group.id,
        monthly_budget_usd: "100.00",
        concurrency_limit: 5,
        rpm_limit: 60
      })

    service
  end

  test "agregar supervisor via LiveView events", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    service = service_fixture()
    %{user: user} = register("user")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    # Open the detail modal first (supervisors live there now)
    view
    |> element("button[phx-click='view_detail'][phx-value-id='#{service.id}']")
    |> render_click()

    # Open the supervisor form inside the detail modal
    view
    |> element("button[phx-click='toggle_supervisor_form'][phx-value-service-id='#{service.id}']")
    |> render_click()

    # Search for the user
    view
    |> element("input[name='supervisor_query']")
    |> render_keyup(%{"value" => user.email})

    # Click the user result
    view
    |> element(
      "button[phx-click='add_supervisor'][phx-value-service-id='#{service.id}'][phx-value-user-id='#{user.id}']"
    )
    |> render_click()

    # Verify the supervisor was added
    supervisors = Accounts.service_supervisors(service.id)
    assert length(supervisors) == 1
    assert hd(supervisors).user_id == user.id
  end

  test "búsqueda filtra servicios por nombre", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    service = service_fixture()
    other = service_fixture()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    prefix = String.slice(service.name, 0, 12)

    view
    |> element("#search-form")
    |> render_change(%{"q" => prefix})

    html = render(view)
    assert html =~ service.name
    refute html =~ "id=\"service-#{other.id}\""
  end

  test "sort por gasto alterna dirección", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    _s1 = service_fixture()
    _s2 = service_fixture()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    html =
      view
      |> element("#sort-monthly_spend")
      |> render_click()

    assert html =~ "Gasto mensual"
    assert html =~ "▼"
  end

  test "muestra las columnas Gasto mensual y Gasto total", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    service = service_fixture()

    {:ok, _} =
      Tokengate.Logs.log_request(%{
        subject_type: "service",
        service_id: service.id,
        model_requested: "gpt-4o",
        provider_cost_usd: Decimal.new("1.50"),
        latency_ms: 100
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    assert has_element?(view, "#monthly-spend-#{service.id}", "$1.50")
    assert has_element?(view, "#total-spend-#{service.id}", "$1.50")
  end

  test "eliminar servicio via modal de confirmación", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    service = service_fixture()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    # El modal de borrado vive siempre en el DOM; se abre con el evento.
    view |> element("#delete-#{service.id}") |> render_click()

    assert has_element?(view, "#delete-service-modal")
    assert has_element?(view, "#delete-service-name", service.name)
    assert has_element?(view, "#confirm-delete-service")

    html = view |> element("#confirm-delete-service") |> render_click()
    assert html =~ "Servicio eliminado"
    assert Accounts.get_service(service.id) == nil
  end

  # Los servicios tienen la misma función que los usuarios: limpiar su stickiness
  # (todas sus keys) para forzar el re-ruteo en la próxima petición.
  test "limpiar sticky routes del servicio (todas sus keys)", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    service = service_fixture()

    # Dos keys del servicio: la stickiness es del sujeto, no de una key.
    {_t1, h1, p1} = Accounts.generate_api_key_material()
    {_t2, h2, p2} = Accounts.generate_api_key_material()

    for {h, p} <- [{h1, p1}, {h2, p2}] do
      {:ok, _} =
        Accounts.create_api_key(%{
          "subject_type" => "service",
          "service_id" => service.id,
          "key_hash" => h,
          "key_prefix" => p,
          "label" => "k-#{p}"
        })
    end

    other_hash = "hash-de-otro-servicio"

    for hash <- [h1, h2, other_hash] do
      Tokengate.Routing.StickyTracker.put(hash, "model-1", "ap-1")
    end

    _ = :sys.get_state(Tokengate.Routing.StickyTracker)

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    view
    |> element("button[phx-click='view_detail'][phx-value-id='#{service.id}']")
    |> render_click()

    assert has_element?(view, "#clear-service-sticky-btn")

    html = view |> element("#clear-service-sticky-btn") |> render_click()

    assert html =~ "Sticky routes limpiadas"

    for hash <- [h1, h2] do
      assert Tokengate.Routing.StickyTracker.get(hash, "model-1") == nil
    end

    # La de otro servicio sobrevive.
    assert Tokengate.Routing.StickyTracker.get(other_hash, "model-1") == "ap-1"
  end
end
