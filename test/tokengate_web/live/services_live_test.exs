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

    # Este archivo afirma los mensajes en español del LiveView; el idioma por
    # defecto de la UI es inglés, así que el usuario arranca en español.
    {:ok, user} = Accounts.update_user_locale(user, "es")

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

  test "ordenar por gasto pone primero al que más gasta, no al que no tiene datos",
       %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    caro = service_fixture()
    barato = service_fixture()
    sin_gasto = service_fixture()

    {:ok, _} =
      Tokengate.Logs.log_request(%{
        subject_type: "service",
        service_id: caro.id,
        model_requested: "gpt-4o",
        provider_cost_usd: Decimal.new("50.00"),
        latency_ms: 100
      })

    {:ok, _} =
      Tokengate.Logs.log_request(%{
        subject_type: "service",
        service_id: barato.id,
        model_requested: "gpt-4o",
        provider_cost_usd: Decimal.new("1.00"),
        latency_ms: 100
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    # Primer click = desc (más gasto primero). El que no tiene datos pinta
    # $0.00, así que va al final, no encabezando el listado.
    html = view |> element("#sort-monthly_spend") |> render_click()

    ids =
      Regex.scan(~r/<tr[^>]+id="service-([^"]+)"/, html)
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.filter(&(&1 in [to_string(caro.id), to_string(barato.id), to_string(sin_gasto.id)]))

    assert ids == [to_string(caro.id), to_string(barato.id), to_string(sin_gasto.id)]
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

  test "un servicio sin requests muestra $0.00 en las dos columnas de gasto", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    service = service_fixture()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    # No aparece en los agregados (no tiene logs): es $0.00, no «—».
    assert has_element?(view, "#monthly-spend-#{service.id}", "$0.00")
    assert has_element?(view, "#total-spend-#{service.id}", "$0.00")
  end

  test "la columna Límite mensual lee consumo/techo, igual que en Usuarios", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    {:ok, group} =
      Accounts.create_group(%{name: "Credit Svc Group #{System.unique_integer([:positive])}"})

    {:ok, service} =
      Accounts.create_service(%{
        name: "Credit Service #{System.unique_integer([:positive])}",
        group_id: group.id,
        monthly_spend_limit_usd: "50.00",
        concurrency_limit: 5,
        rpm_limit: 60
      })

    # $20 consumidos del techo: la celda y su barra miden lo mismo (antes la
    # columna solo imprimía el techo como texto: «$50.00/mes»).
    {:ok, _} =
      Tokengate.Logs.log_request(%{
        subject_type: "service",
        service_id: service.id,
        model_requested: "gpt-4o",
        provider_cost_usd: Decimal.new("20.00"),
        latency_ms: 100
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    assert has_element?(view, "#credit-#{service.id}", "20.0000 / 50.0000")
    # El gasto real del mes sigue en su propia columna (incluye top-ups).
    assert has_element?(view, "#monthly-spend-#{service.id}", "$20.00")
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

    # El ruteo sticky del servicio vive en su panel de claves (igual que en
    # usuarios), no en el modal de detalle.
    view
    |> element("#keys-#{service.id}")
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

  ## API keys (N claves con etiqueta, igual que un usuario) -----------------

  describe "claves API del servicio" do
    defp create_service_key(service, label) do
      {_token, key_hash, key_prefix} = Accounts.generate_api_key_material()

      {:ok, key} =
        Accounts.create_api_key(%{
          "subject_type" => "service",
          "service_id" => service.id,
          "key_hash" => key_hash,
          "key_prefix" => key_prefix,
          "label" => label
        })

      key
    end

    test "la columna Claves cuenta las N claves y abre el panel", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()
      k1 = create_service_key(service, "ci")
      k2 = create_service_key(service, "server")

      conn = login(conn, admin, password)
      {:ok, view, html} = live(conn, ~p"/access/services")

      assert html =~ "Claves"
      assert has_element?(view, "#keys-#{service.id}", "2 claves")

      view |> element("#keys-#{service.id}") |> render_click()

      assert has_element?(view, "#service-keys-modal")
      assert has_element?(view, "#key-#{k1.id}", "ci")
      assert has_element?(view, "#key-#{k2.id}", "server")
      assert has_element?(view, "#revoke-key-#{k1.id}")
      assert has_element?(view, "#new-key-form")
    end

    test "crear una clave con etiqueta no toca las existentes", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()
      k1 = create_service_key(service, "ci")

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      view |> element("#keys-#{service.id}") |> render_click()
      assert has_element?(view, "#key-#{k1.id}", "ci")

      html =
        view
        |> form("#new-key-form", %{key: %{label: "nueva"}})
        |> render_submit()

      assert html =~ "Clave creada"
      assert has_element?(view, "#new-key-token")
      assert has_element?(view, "#key-#{k1.id}", "ci")

      labels =
        Accounts.list_api_keys_for_service(service.id) |> Enum.map(& &1.label) |> Enum.sort()

      assert labels == ["ci", "nueva"]
    end

    test "revocar una clave no afecta a las demás", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()
      k1 = create_service_key(service, "revocar")
      k2 = create_service_key(service, "seguir")

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      view |> element("#keys-#{service.id}") |> render_click()
      view |> element("#revoke-key-#{k1.id}") |> render_click()

      refute has_element?(view, "#key-#{k1.id}")
      assert has_element?(view, "#key-#{k2.id}", "seguir")

      assert Accounts.get_api_key(k1.id).status == "revoked"
      assert Accounts.get_api_key(k2.id).status == "active"
      assert Enum.map(Accounts.list_api_keys_for_service(service.id), & &1.id) == [k2.id]
    end

    test "una clave revocada se lista aparte y se puede reactivar", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()
      k1 = create_service_key(service, "volver")
      k2 = create_service_key(service, "seguir")

      {:ok, _} = Accounts.revoke_service_api_key(k1)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      view |> element("#keys-#{service.id}") |> render_click()

      refute has_element?(view, "#key-#{k1.id}")
      assert has_element?(view, "#revoked-key-#{k1.id}", "volver")
      assert has_element?(view, "#revoke-key-#{k2.id}")

      html = view |> element("#reactivate-key-#{k1.id}") |> render_click()
      assert html =~ "Clave reactivada"

      assert has_element?(view, "#key-#{k1.id}", "volver")
      assert has_element?(view, "#key-#{k1.id}", "Activo")
      refute has_element?(view, "#revoked-key-#{k1.id}")

      assert Accounts.get_api_key(k1.id).status == "active"
      assert Accounts.get_api_key(k2.id).status == "active"
    end

    test "reactivar una clave de otro servicio se rechaza", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()
      other_service = service_fixture()
      foreign = create_service_key(other_service, "ajena")
      {:ok, _} = Accounts.revoke_service_api_key(foreign)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      view |> element("#keys-#{service.id}") |> render_click()

      html = render_hook(view, "reactivate_service_key", %{"key-id" => foreign.id})

      assert html =~ "Clave no encontrada"
      assert Accounts.get_api_key(foreign.id).status == "revoked"
    end

    test "renombrar una clave cambia su label sin tocar hash ni status", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()
      k1 = create_service_key(service, "ci")

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      view |> element("#keys-#{service.id}") |> render_click()

      # Lápiz → form inline → submit.
      view |> element("#rename-key-#{k1.id}") |> render_click()
      assert has_element?(view, "#rename-key-form-#{k1.id}")

      html =
        view
        |> form("#rename-key-inline-#{k1.id}", %{"key-id" => k1.id, key: %{label: "prod"}})
        |> render_submit()

      assert html =~ "Clave renombrada"
      assert has_element?(view, "#key-#{k1.id}", "prod")
      refute has_element?(view, "#rename-key-form-#{k1.id}")

      renamed = Accounts.get_api_key(k1.id)
      assert renamed.label == "prod"
      assert renamed.key_hash == k1.key_hash
      assert renamed.status == "active"
    end

    test "renombrar con label vacío limpia la etiqueta (queda «sin etiqueta»)", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()
      k1 = create_service_key(service, "ci")

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      view |> element("#keys-#{service.id}") |> render_click()
      view |> element("#rename-key-#{k1.id}") |> render_click()

      view
      |> form("#rename-key-inline-#{k1.id}", %{"key-id" => k1.id, key: %{label: "   "}})
      |> render_submit()

      assert Accounts.get_api_key(k1.id).label in [nil, ""]
      assert has_element?(view, "#key-#{k1.id}", "sin etiqueta")
    end

    test "renombrar la key de otro servicio (payload forjado) es rechazado", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()
      other = service_fixture()
      other_key = create_service_key(other, "ajena")
      own_key = create_service_key(service, "propia")

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      view |> element("#keys-#{service.id}") |> render_click()
      view |> element("#rename-key-#{own_key.id}") |> render_click()

      # Payload forjado: el key-id del submit apunta a la key del OTRO
      # servicio. El chequeo hermético (service_id == keys_service_id) debe
      # rechazarlo y la key ajena queda intacta. Params crudos (el form helper
      # validaría el hidden contra el DOM y no dejaría forjar).
      html =
        view
        |> element("#rename-key-inline-#{own_key.id}")
        |> render_submit(%{"key-id" => other_key.id, "key" => %{"label" => "hack"}})

      assert html =~ "No se pudo renombrar la clave"
      assert Accounts.get_api_key(other_key.id).label == "ajena"
      assert Accounts.get_api_key(own_key.id).label == "propia"
    end

    test "cancelar el rename cierra el form sin cambiar nada", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()
      k1 = create_service_key(service, "ci")

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      view |> element("#keys-#{service.id}") |> render_click()
      view |> element("#rename-key-#{k1.id}") |> render_click()

      view |> element("#cancel-rename-key-#{k1.id}") |> render_click()

      refute has_element?(view, "#rename-key-form-#{k1.id}")
      assert Accounts.get_api_key(k1.id).label == "ci"
    end

    test "eliminar el servicio borra TODAS sus claves", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()
      k1 = create_service_key(service, "una")
      k2 = create_service_key(service, "otra")

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      view |> element("#delete-#{service.id}") |> render_click()
      view |> element("#confirm-delete-service") |> render_click()

      assert Accounts.get_service(service.id) == nil
      assert Accounts.get_api_key(k1.id) == nil
      assert Accounts.get_api_key(k2.id) == nil
    end
  end

  # L38 — doble click en Guardar o submit encolado justo detrás de Cancelar
  # llegan con `editing_service_id` nil: no-op, no un crash del LiveView.
  test "un submit con id de edición stale no revienta el LiveView", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    view |> element("#new-service-btn") |> render_click()
    view |> render_click("cancel_form")

    # El submit estaba en vuelo cuando Cancelar limpió el id de edición.
    html =
      render_click(view, "save_service", %{"service" => %{"name" => "Late #{unique()}"}})

    refute html =~ "Something went wrong"
    assert has_element?(view, "#new-service-btn")
    refute Enum.any?(Accounts.list_services(), &String.starts_with?(&1.name, "Late "))
  end
end
