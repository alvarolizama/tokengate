defmodule TokengateWeb.ServicesLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
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
    |> element("#supervisor-search-form")
    |> render_change(%{"supervisor_query" => user.email})

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

    # El header ordenable del componente .table dispara `sort_services` con
    # phx-value-field (antes era un botón con id #sort-<campo>).
    html =
      view
      |> element("th button[phx-value-field='monthly_spend']")
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
    html = view |> element("th button[phx-value-field='monthly_spend']") |> render_click()

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

  # Contrato .table (Fase 0): el listado es una tabla real — tbody con stream
  # y una fila por servicio con su dom_id —, con headers ordenables que
  # disparan el evento existente por phx-value-field.
  test "el listado usa el componente .table (stream + headers ordenables)", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    service = service_fixture()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    assert has_element?(view, "table tbody#services[phx-update='stream']")
    assert has_element?(view, "tbody#services tr#service-#{service.id}")
    assert has_element?(view, "th button[phx-click='sort_services'][phx-value-field='name']")
    assert has_element?(view, "th button[phx-value-field='monthly_spend']")
    # Los numéricos van a la derecha.
    assert has_element?(view, "td.text-right #monthly-spend-#{service.id}")
    assert has_element?(view, "td.text-right #total-spend-#{service.id}")
  end

  test "sin resultados el empty-state sustituye a las filas", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    _service = service_fixture()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    refute has_element?(view, "#services-empty")

    view |> element("#search-form") |> render_change(%{"q" => "no-existe-#{unique()}"})

    assert has_element?(view, "#services-empty")
    refute has_element?(view, "tbody#services")
  end

  ## Paginado (espejo de la tabla de Usuarios) ------------------------------

  # N servicios con nombres ordenables ("Paged Svc <pid> 001".."031"), para que
  # la página sea determinista con el orden por nombre.
  defp paged_services(count) do
    prefix = "Paged Svc #{unique()}"

    for i <- 1..count do
      {:ok, service} =
        Accounts.create_service(%{
          name: "#{prefix} #{i |> Integer.to_string() |> String.pad_leading(3, "0")}"
        })

      service
    end
  end

  test "pagina en la base: page 2 y el pie reportan total y total_pages", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    services = paged_services(31)

    first = hd(services)
    last = List.last(services)

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    # 31 servicios → 30 en la página 1 y 1 en la página 2 (la página la corta
    # Postgres; antes venían los 500 en una sola lista).
    assert has_element?(view, "#services-pagination")
    assert has_element?(view, "#services-pagination-range", "1–30 de 31")
    assert has_element?(view, "#service-#{first.id}")
    refute has_element?(view, "#service-#{last.id}")

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.total_count == 31
    assert assigns.total_pages == 2

    view |> element("#services-pagination-page-2") |> render_click()

    assert has_element?(view, "#services-pagination-range", "31–31 de 31")
    assert has_element?(view, "#service-#{last.id}")
    refute has_element?(view, "#service-#{first.id}")

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.page == 2
    assert assigns.total_count == 31
    assert assigns.total_pages == 2
  end

  # Los agregados por fila (stats 30d, crédito, supervisores y claves) se pagan
  # SOLO para los service_ids de la página: antes se calculaban para los 500
  # cargados en cada carga.
  test "stats, crédito, supervisores y claves se calculan solo para la página", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    services = paged_services(31)

    first = hd(services)
    last = List.last(services)
    page1_ids = services |> Enum.take(30) |> Enum.map(& &1.id) |> Enum.sort()

    refute last.id in page1_ids

    # Un servicio de cada página con consumo, supervisor y clave: si el
    # LiveView agregara sobre TODOS los servicios, el de la página 2 saldría en
    # los maps de la página 1.
    for service <- [first, last] do
      {:ok, _} =
        Tokengate.Logs.log_request(%{
          subject_type: "service",
          service_id: service.id,
          model_requested: "gpt-4o",
          provider_cost_usd: Decimal.new("2.00"),
          latency_ms: 100
        })

      {:ok, _} = Accounts.add_service_supervisor(service.id, admin.id)

      {_token, key_hash, key_prefix} = Accounts.generate_api_key_material()

      {:ok, _} =
        Accounts.create_api_key(%{
          "subject_type" => "service",
          "service_id" => service.id,
          "key_hash" => key_hash,
          "key_prefix" => key_prefix,
          "label" => "k-#{key_prefix}"
        })
    end

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    assigns = :sys.get_state(view.pid).socket.assigns

    assert Map.keys(assigns.service_stats) == [first.id]
    assert Enum.sort(Map.keys(assigns.service_credit)) == page1_ids
    assert Map.keys(assigns.supervisors_map) == [first.id]
    assert Map.keys(assigns.keys_by_service) == [first.id]

    view |> element("#services-pagination-page-2") |> render_click()

    assigns = :sys.get_state(view.pid).socket.assigns

    assert Map.keys(assigns.service_stats) == [last.id]
    assert Map.keys(assigns.service_credit) == [last.id]
    assert Map.keys(assigns.supervisors_map) == [last.id]
    assert Map.keys(assigns.keys_by_service) == [last.id]
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

  # F9: the modal promised "the service API key" (singular) although a
  # service holds N keys, and said nothing about the real CASCADE over its
  # history. The copy now states the true FK effect.
  test "el modal de borrado describe el CASCADE real sobre request_logs", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    service = service_fixture()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    view |> element("#delete-#{service.id}") |> render_click()

    html = render(view)

    assert html =~ "request_logs"
    assert html =~ "ON DELETE CASCADE"
    assert html =~ "Sus claves API"
    assert html =~ "top-ups"
    # The old promise (a single key) is gone.
    refute html =~ "La clave API del servicio"
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

    test "revocar una clave no afecta a las demás y emite una nueva", %{conn: conn} do
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

      # Revoke = issue a new key (W2 contract): the old row stays `revoked`
      # to preserve the historical attribution and the service gains a new
      # key with the same label. The token is shown exactly once.
      active = Accounts.list_api_keys_for_service(service.id)
      active_ids = Enum.map(active, & &1.id)

      assert length(active_ids) == 2
      assert k2.id in active_ids
      refute k1.id in active_ids

      replacement = Enum.find(active, &(&1.id != k2.id))
      assert replacement.label == "revocar"
      assert replacement.key_hash != k1.key_hash
      assert has_element?(view, "#new-key-token")
    end

    test "una clave revocada se oculta (soft-delete) y no ofrece reactivación", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()
      k1 = create_service_key(service, "volver")
      k2 = create_service_key(service, "seguir")

      {:ok, _} = Accounts.revoke_service_api_key(k1)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      view |> element("#keys-#{service.id}") |> render_click()

      refute has_element?(view, "#key-#{k1.id}")
      refute has_element?(view, "#revoked-key-#{k1.id}")
      assert has_element?(view, "#revoke-key-#{k2.id}")

      # Soft-delete: the revoked key is hidden from the panel entirely. The
      # panel never resurrects tokens — neither "reactivate" nor "revoke"
      # renders on the revoked row again.
      refute has_element?(view, "#reactivate-key-#{k1.id}")
      refute has_element?(view, "#revoke-key-#{k1.id}")
      # ...while the active key does carry its delete (soft-hide) button.
      assert has_element?(view, "#hide-key-#{k2.id}")

      assert Accounts.get_api_key(k1.id).status == "revoked"
      assert Accounts.get_api_key(k2.id).status == "active"
    end

    test "revocar u ocultar la clave de otro servicio (payload forjado) se rechaza", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()
      other_service = service_fixture()
      foreign = create_service_key(other_service, "ajena")

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      view |> element("#keys-#{service.id}") |> render_click()

      html = render_hook(view, "revoke_service_key", %{"key-id" => foreign.id})
      assert html =~ "Clave no encontrada"

      html = render_hook(view, "hide_service_key", %{"key-id" => foreign.id})
      assert html =~ "Clave no encontrada"

      survived = Accounts.get_api_key(foreign.id)
      assert survived.status == "active"
      assert survived.hidden_at == nil

      assert Enum.map(Accounts.list_api_keys_for_service(other_service.id), & &1.id) ==
               [foreign.id]
    end

    test "borrar una clave es soft-hide: la oculta y conserva la atribución", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()
      k1 = create_service_key(service, "efímera")
      k2 = create_service_key(service, "estable")

      {:ok, log} =
        Tokengate.Logs.log_request(%{
          subject_type: "service",
          service_id: service.id,
          api_key_id: k1.id,
          model_requested: "gpt-4o",
          provider_cost_usd: Decimal.new("1.25"),
          latency_ms: 100
        })

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      assert has_element?(view, "#keys-#{service.id}", "2 claves")

      view |> element("#keys-#{service.id}") |> render_click()
      html = view |> element("#hide-key-#{k1.id}") |> render_click()

      assert html =~ "Clave borrada"
      refute has_element?(view, "#key-#{k1.id}")
      refute has_element?(view, "#revoked-key-#{k1.id}")
      assert has_element?(view, "#key-#{k2.id}", "estable")

      hidden = Accounts.get_api_key(k1.id)
      assert hidden.hidden_at != nil
      assert hidden.status == "revoked"

      # The log keeps its api_key_id: deleting never rewrites the history.
      # (`request_logs` is partitioned and its PK is (id, inserted_at), so
      # `Repo.get/2` by id is not available.)
      persisted_key_id =
        Tokengate.Repo.one(
          from(rl in Tokengate.Logs.RequestLog,
            where: rl.id == ^log.id,
            select: rl.api_key_id
          )
        )

      assert persisted_key_id == k1.id
      # And the row no longer counts for the table's keys badge.
      badge_keys = Accounts.list_api_keys_for_services([service.id])[service.id]
      assert Enum.map(badge_keys, & &1.id) == [k2.id]
    end

    test "renombrar audita api_key.rename con old/new label", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()
      k1 = create_service_key(service, "antes")

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      view |> element("#keys-#{service.id}") |> render_click()
      view |> element("#rename-key-#{k1.id}") |> render_click()

      view
      |> form("#rename-key-inline-#{k1.id}", %{"key-id" => k1.id, key: %{label: "después"}})
      |> render_submit()

      assert [audit] =
               Tokengate.Auditing.list_audit_logs(%{
                 action: "api_key.rename",
                 entity_id: k1.id
               })

      assert audit.changes["old_label"] == "antes"
      assert audit.changes["new_label"] == "después"
      assert audit.entity_type == "api_key"
    end

    test "un id de cliente no-UUID no revienta la vista", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      # Every handler that touches the DB casts the id first: garbage is a
      # flash, not an `Ecto.Query.CastError` that kills the LiveView.
      assert render_hook(view, "edit_service", %{"id" => "no-es-uuid"}) =~
               "Servicio no encontrado"

      assert render_hook(view, "delete_service", %{"id" => "no-es-uuid"}) =~
               "Servicio no encontrado"

      assert render_hook(view, "manage_keys", %{"id" => "no-es-uuid"}) =~ "Servicio no encontrado"

      assert render_hook(view, "clear_service_sticky_routes", %{"id" => "no-es-uuid"}) =~
               "Servicio no encontrado"

      assert render_hook(view, "add_supervisor", %{
               "service-id" => "no-es-uuid",
               "user-id" => "tampoco"
             }) =~ "No se pudo agregar"

      # The view is still alive and serving real events.
      view |> element("#new-service-btn") |> render_click()
      assert has_element?(view, "#service-form-modal")

      # A well-formed but missing id does not crash either.
      assert render_hook(view, "edit_service", %{"id" => Ecto.UUID.generate()}) =~
               "Servicio no encontrado"

      # And adding a supervisor that does not exist is an error, not an FK violation.
      assert render_hook(view, "add_supervisor", %{
               "service-id" => service.id,
               "user-id" => Ecto.UUID.generate()
             }) =~ "No se pudo agregar"
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

  test "service row and detail modal link to /access/services/:id/members and models modal has valid id",
       %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    service = service_fixture()
    %{user: sup} = register("user")
    {:ok, _} = Accounts.add_service_supervisor(service.id, sup.id)

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    assert has_element?(
             view,
             "#members-link-#{service.id}[href=\"/access/services/#{service.id}/members\"]",
             "1"
           )

    view |> element("#detail-#{service.id}") |> render_click()
    assert has_element?(view, "#service-detail-modal")

    assert has_element?(
             view,
             "#manage-service-members-link[href=\"/access/services/#{service.id}/members\"]"
           )

    view |> element("#close-detail-btn") |> render_click()

    view |> element("#edit-models-#{service.id}") |> render_click()
    assert has_element?(view, "#models-modal-#{service.id}")
  end

  describe "filtros, sort de límite, modal de modelos, detalle y URL params" do
    test "placeholder de búsqueda dice presupuesto y no perfil de límites", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)
      {:ok, view, html} = live(conn, ~p"/access/services")

      assert html =~ "Buscar por nombre o presupuesto"
      refute html =~ "perfil de límites"
      assert has_element?(view, "#service-filter-pills")
    end

    test "pills de filtro filtran en Postgres por presupuesto y sin claves", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      {:ok, budgeted} =
        Accounts.create_service(%{
          name: "Svc Budgeted #{unique()}",
          monthly_spend_limit_usd: "50"
        })

      {:ok, unlimited} =
        Accounts.create_service(%{name: "Svc Unlimited #{unique()}", unlimited_spend: true})

      {:ok, no_budget} = Accounts.create_service(%{name: "Svc NoBudget #{unique()}"})

      {_token, key_hash, key_prefix} = Accounts.generate_api_key_material()

      {:ok, _} =
        Accounts.create_api_key(%{
          "subject_type" => "service",
          "service_id" => budgeted.id,
          "key_hash" => key_hash,
          "key_prefix" => key_prefix,
          "label" => "k1"
        })

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      view |> element("#filter-service-budgeted") |> render_click()
      assert has_element?(view, "#service-#{budgeted.id}")
      refute has_element?(view, "#service-#{unlimited.id}")
      refute has_element?(view, "#service-#{no_budget.id}")

      view |> element("#filter-service-unlimited") |> render_click()
      assert has_element?(view, "#service-#{unlimited.id}")
      refute has_element?(view, "#service-#{budgeted.id}")

      view |> element("#filter-service-no_budget") |> render_click()
      assert has_element?(view, "#service-#{no_budget.id}")
      refute has_element?(view, "#service-#{budgeted.id}")
      refute has_element?(view, "#service-#{unlimited.id}")

      view |> element("#filter-service-no_keys") |> render_click()
      assert has_element?(view, "#service-#{unlimited.id}")
      assert has_element?(view, "#service-#{no_budget.id}")
      refute has_element?(view, "#service-#{budgeted.id}")
    end

    test "sort por límite mensual ordena numéricamente por consumo contra el techo", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      {:ok, low} =
        Accounts.create_service(%{name: "A Low #{unique()}", monthly_spend_limit_usd: "100"})

      {:ok, high} =
        Accounts.create_service(%{name: "B High #{unique()}", monthly_spend_limit_usd: "100"})

      {:ok, unlim} =
        Accounts.create_service(%{name: "C Unlim #{unique()}", unlimited_spend: true})

      {:ok, _} =
        Tokengate.Logs.log_request(%{
          subject_type: "service",
          service_id: low.id,
          model_requested: "gpt-4o",
          provider_cost_usd: Decimal.new("9.00"),
          latency_ms: 50
        })

      {:ok, _} =
        Tokengate.Logs.log_request(%{
          subject_type: "service",
          service_id: high.id,
          model_requested: "gpt-4o",
          provider_cost_usd: Decimal.new("40.00"),
          latency_ms: 50
        })

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      html = view |> element("th button[phx-value-field='limit']") |> render_click()

      ids =
        Regex.scan(~r/<tr[^>]+id="service-([^"]+)"/, html)
        |> Enum.map(&Enum.at(&1, 1))
        |> Enum.filter(&(&1 in [to_string(low.id), to_string(high.id), to_string(unlim.id)]))

      assert ids == [to_string(high.id), to_string(low.id), to_string(unlim.id)]
    end

    test "modal de modelos filtra la lista de modelos por nombre", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()

      {:ok, m1} =
        Tokengate.Providers.create_model(%{name: "alpha-model-#{unique()}", context_window: 8192})

      {:ok, m2} =
        Tokengate.Providers.create_model(%{name: "beta-model-#{unique()}", context_window: 8192})

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      view |> element("#edit-models-#{service.id}") |> render_click()
      assert has_element?(view, "#model-picker-#{service.id}-#{m1.id}")
      assert has_element?(view, "#model-picker-#{service.id}-#{m2.id}")

      view
      |> element("#models-modal-search-form")
      |> render_change(%{"q" => "alpha-model"})

      assert has_element?(view, "#model-picker-#{service.id}-#{m1.id}")
      refute has_element?(view, "#model-picker-#{service.id}-#{m2.id}")
    end

    test "modal de detalle usa metric_tile con precisión adaptativa y picker substring", %{
      conn: conn
    } do
      %{user: admin, password: password} = register("admin")
      service = service_fixture()
      u = unique()

      {:ok, sub_user} =
        Accounts.register_user(%{
          email: "picker-#{u}@example.com",
          name: "Maria Substring #{u}",
          password: "password-secret-#{u}1",
          global_role: "user"
        })

      {:ok, _} =
        Tokengate.Logs.log_request(%{
          subject_type: "service",
          service_id: service.id,
          model_requested: "gpt-4o",
          provider_cost_usd: Decimal.new("0.000500"),
          latency_ms: 50
        })

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services")

      view |> element("#detail-#{service.id}") |> render_click()
      assert has_element?(view, "#detail-stat-cost", "$0.0005")
      assert has_element?(view, "#detail-stat-requests", "1")

      view
      |> element(
        "button[phx-click='toggle_supervisor_form'][phx-value-service-id='#{service.id}']"
      )
      |> render_click()

      # Substring match (2+ chars, mid-string) funciona igual que en ServiceMembersLive.
      view
      |> element("#supervisor-search-form")
      |> render_change(%{"supervisor_query" => "Substring"})

      assert has_element?(
               view,
               "button[phx-click='add_supervisor'][phx-value-user-id='#{sub_user.id}']"
             )
    end

    test "handle_params aplica búsqueda y filtro desde URL", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      {:ok, target} =
        Accounts.create_service(%{name: "DeepLinkSvc #{unique()}", unlimited_spend: true})

      {:ok, _other} = Accounts.create_service(%{name: "OtherSvc #{unique()}"})

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/services?q=DeepLinkSvc&filter=unlimited")

      assert has_element?(view, "#service-#{target.id}")
      assert has_element?(view, "#filter-service-unlimited.btn-primary")
    end
  end

  # --------------------------------------------------------------------------
  # SmartRouter access — flag propio del servicio
  # --------------------------------------------------------------------------

  test "editar un servicio persiste el acceso al router, audita y pinta la pastilla",
       %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    service = service_fixture()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/services")

    refute has_element?(view, "#router-badge-#{service.id}")

    view |> element("#edit-#{service.id}") |> render_click()
    assert has_element?(view, "#service-form input[name='service[router_enabled]']")

    view
    |> form("#service-form", %{service: %{name: service.name, router_enabled: "true"}})
    |> render_submit()

    assert Accounts.get_service!(service.id).router_enabled
    assert has_element?(view, "#router-badge-#{service.id}")

    assert [audit] =
             Tokengate.Auditing.list_audit_logs(%{
               action: "service.update",
               entity_id: service.id
             })

    assert audit.changes["changes"]["router_enabled"] == "true"
  end
end
