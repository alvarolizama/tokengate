defmodule TokengateWeb.ServiceStatsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Logs}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "sstats-#{u}@example.com",
        name: "S #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    # Este archivo afirma etiquetas en español (`Sin presupuesto`), así que el
    # usuario arranca en español: el idioma por defecto de la UI es inglés.
    {:ok, user} = Accounts.update_user_locale(user, "es")

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp service_fixture do
    {:ok, service} =
      Accounts.create_service(%{
        name: "Svc Stats #{unique()}",
        concurrency_limit: 5,
        rpm_limit: 60
      })

    service
  end

  defp key_fixture(service, attrs) do
    {_token, key_hash, key_prefix} = Accounts.generate_api_key_material()

    {:ok, api_key} =
      Accounts.create_api_key(
        Map.merge(
          %{
            "subject_type" => "service",
            "service_id" => service.id,
            "key_hash" => key_hash,
            "key_prefix" => key_prefix,
            "status" => "active"
          },
          attrs
        )
      )

    api_key
  end

  # Texto de una celda de la tabla de API keys (una fila del group by, del
  # preload o Unattributed), sin el ruido del HTML.
  defp cell_text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  defp log_for(service, attrs) do
    Logs.log_request(
      Map.merge(
        %{
          subject_type: "service",
          service_id: service.id,
          model_requested: "gpt-4o-svc",
          status_code: 200,
          prompt_tokens: 100,
          completion_tokens: 50,
          provider_cost_usd: Decimal.new("0.001"),
          latency_ms: 300
        },
        attrs
      )
    )
  end

  describe "auth" do
    test "unauthenticated visitors are redirected to /login", %{conn: conn} do
      service = service_fixture()

      assert {:error, {:redirect, %{to: "/login"}}} =
               live(conn, ~p"/stats/services/#{service.id}")
    end

    test "regular user is redirected to /dashboard (admin-only)", %{conn: conn} do
      service = service_fixture()
      %{user: regular, password: password} = register("user")
      conn = login(conn, regular, password)

      assert {:error, {:redirect, %{to: "/dashboard"}}} =
               live(conn, ~p"/stats/services/#{service.id}")
    end
  end

  describe "render" do
    test "admin sees the service header (name + saw its limit)", %{conn: conn} do
      service = service_fixture()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, _view, html} = live(conn, ~p"/stats/services/#{service.id}")

      assert html =~ service.name
      # El modelo declara el presupuesto del servicio (aquí: sin presupuesto
      # mensual, solo podría gastar contra top-ups).
      assert html =~ "Sin presupuesto"
    end

    test "admin sees the service's logs", %{conn: conn} do
      service = service_fixture()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, _} = log_for(service, %{model_requested: "gpt-4o-svc", status_code: 200})
      {:ok, _} = log_for(service, %{model_requested: "gpt-4o-svc", status_code: 503})

      {:ok, _view, html} = live(conn, ~p"/stats/services/#{service.id}")

      assert html =~ "gpt-4o-svc"
      assert html =~ "200"
      assert html =~ "503"
    end

    test "logs from another service are not shown", %{conn: conn} do
      service = service_fixture()
      other = service_fixture()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, _} = log_for(service, %{model_requested: "only-this-one"})
      {:ok, _} = log_for(other, %{model_requested: "other-service-model"})

      {:ok, _view, html} = live(conn, ~p"/stats/services/#{service.id}")

      assert html =~ "only-this-one"
      refute html =~ "other-service-model"
    end
  end

  describe "api keys table" do
    test "a revoked key with no traffic in the window shows zeros and its badge", %{conn: conn} do
      service = service_fixture()
      key = key_fixture(service, %{"label" => "Old key"})
      {:ok, revoked} = Accounts.revoke_api_key(key)
      assert revoked.status == "revoked"

      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats/services/#{service.id}")

      row = "#api-key-row-#{key.id}"

      # El group by no trae nada (la key no tiene tráfico): la fila existe igual
      # porque viene de la lista de keys del servicio.
      assert has_element?(view, "#service-api-keys-table")
      assert has_element?(view, row)
      assert cell_text(view, "#{row} td:nth-child(1)") == "Old key"
      assert cell_text(view, "#{row} td:nth-child(2)") == "revoked"
      assert cell_text(view, "#{row} td:nth-child(3)") == "0"
      assert cell_text(view, "#{row} td:nth-child(4)") == "0"
      assert cell_text(view, "#{row} td:nth-child(5)") == "0"
      assert cell_text(view, "#{row} td:nth-child(6)") == "$0.00"
      assert cell_text(view, "#{row} td:nth-child(7)") == "—"
      assert has_element?(view, "#{row} .badge-error")
    end

    test "traffic without api_key_id renders an Unattributed row", %{conn: conn} do
      service = service_fixture()

      # Log de servicio sin `api_key_id` (el histórico pre-unificación).
      {:ok, _} = log_for(service, %{model_requested: "sin-key"})

      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats/services/#{service.id}")

      row = "#api-key-row-unattributed"
      assert has_element?(view, row)
      assert cell_text(view, "#{row} td:nth-child(1)") == "Sin atribuir"
      assert cell_text(view, "#{row} td:nth-child(3)") == "1"
    end

    test "traffic from a deleted key is labeled by the log's api_key_prefix", %{conn: conn} do
      service = service_fixture()

      # Key borrada (delete_api_key/1): el id sobrevive en request_logs sin FK,
      # la fila se etiqueta con el `api_key_prefix` del log, nunca con el uuid.
      orphan_id = Ecto.UUID.generate()
      {:ok, _} = log_for(service, %{api_key_id: orphan_id, api_key_prefix: "tg-orphan"})

      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats/services/#{service.id}")

      row = "#api-key-row-#{orphan_id}"
      assert has_element?(view, row)
      assert cell_text(view, "#{row} td:nth-child(1)") == "tg-orphan"
      assert cell_text(view, "#{row} td:nth-child(3)") == "1"
      # Sin fila en api_keys no hay status: la huérfana no lleva badge.
      refute has_element?(view, "#{row} .badge-error")
      refute has_element?(view, "#{row} .badge-success")
    end

    test "the key selector scopes the report to one key or back to all", %{conn: conn} do
      service = service_fixture()
      key_a = key_fixture(service, %{"label" => "Alpha"})
      key_b = key_fixture(service, %{"label" => "Beta"})
      {:ok, _revoked} = Accounts.revoke_api_key(key_b)

      {:ok, _} = log_for(service, %{api_key_id: key_a.id, model_requested: "alpha-model"})
      {:ok, _} = log_for(service, %{api_key_id: key_b.id, model_requested: "beta-model"})

      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/stats/services/#{service.id}")

      # Todas (default): las dos filas —la revocada incluida— y KPI = 2.
      assert has_element?(view, "#api-key-row-#{key_a.id}")
      assert has_element?(view, "#api-key-row-#{key_b.id}")
      assert render(element(view, "#kpi-requests")) =~ ~r/text-2xl font-bold[^>]*>\s*2\s*</

      # Sólo Beta (revocada): una fila, KPI = 1, logs scopeados y el selector
      # la lista marcada como revocada. Payload REAL del browser: anidado por
      # el to_form (name="key_filter[key_id]").
      html =
        view
        |> form("#key-filter-form", %{"key_filter" => %{"key_id" => key_b.id}})
        |> render_change()

      assert html =~ "Beta · Revocada"
      assert has_element?(view, "#api-key-row-#{key_b.id}")
      refute has_element?(view, "#api-key-row-#{key_a.id}")
      assert render(element(view, "#kpi-requests")) =~ ~r/text-2xl font-bold[^>]*>\s*1\s*</
      assert cell_text(view, "#api-key-row-#{key_b.id} td:nth-child(3)") == "1"

      # La lista de logs también quedó scopeada a la key elegida.
      assert render(view) =~ "beta-model"
      refute render(view) =~ "alpha-model"

      # De vuelta a todas: KPI = 2.
      view
      |> form("#key-filter-form", %{"key_filter" => %{"key_id" => "all"}})
      |> render_change()

      assert has_element?(view, "#api-key-row-#{key_a.id}")
      assert has_element?(view, "#api-key-row-#{key_b.id}")

      # Un id ajeno al servicio se ignora (queda el "all" vigente). Payload
      # forjado directo por el socket: render_change crudo, sin pasar por la
      # validación de opciones del form helper.
      view
      |> element("#key-filter-form")
      |> render_change(%{"key_filter" => %{"key_id" => Ecto.UUID.generate()}})

      assert has_element?(view, "#api-key-row-#{key_a.id}")
      assert has_element?(view, "#api-key-row-#{key_b.id}")
    end

    test "the period selector recomputes the window and ignores unknown values", %{conn: conn} do
      service = service_fixture()
      key = key_fixture(service, %{"label" => "Live key"})

      {:ok, _} = log_for(service, %{api_key_id: key.id})

      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats/services/#{service.id}")

      # El selector es un grupo de patch links (?period=...): cambiar de
      # periodo es navegación, no evento — handle_params es el único punto
      # de carga y los unknowns caen al default.
      assert has_element?(
               view,
               "#period-today[href='/stats/services/#{service.id}?period=today']"
             )

      # Click a "today": el log de hoy sigue en la ventana y la tabla cuadra
      # con el KPI (mismo `from` compartido).
      view |> element("#period-today") |> render_click()

      assert has_element?(view, "#api-key-row-#{key.id}")
      assert cell_text(view, "#api-key-row-#{key.id} td:nth-child(3)") == "1"
      assert render(element(view, "#kpi-requests")) =~ ~r/text-2xl font-bold[^>]*>\s*1\s*</

      # Click a "month": el log de hoy también cae dentro.
      view |> element("#period-month") |> render_click()

      assert has_element?(view, "#api-key-row-#{key.id}")

      # Un periodo desconocido viaja por la URL y se resuelve al default en
      # vez de reventar.
      {:ok, view_bogus, _html} = live(conn, ~p"/stats/services/#{service.id}?period=hack")

      assert has_element?(view_bogus, "#api-key-row-#{key.id}")
      # Vuelve al selector con el periodo default resuelto (week).
      assert has_element?(view_bogus, "#period-week.btn-primary")
    end

    test "the table's requests add up to the KPI", %{conn: conn} do
      service = service_fixture()
      key = key_fixture(service, %{"label" => "Live key"})

      {:ok, _} = log_for(service, %{api_key_id: key.id})
      {:ok, _} = log_for(service, %{api_key_id: key.id})
      {:ok, _} = log_for(service, %{model_requested: "sin-key"})

      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats/services/#{service.id}")

      key_row = "#api-key-row-#{key.id}"

      assert cell_text(view, "#{key_row} td:nth-child(3)") == "2"
      assert cell_text(view, "#{key_row} td:nth-child(4)") == "200"
      assert cell_text(view, "#{key_row} td:nth-child(5)") == "100"
      assert cell_text(view, "#api-key-row-unattributed td:nth-child(3)") == "1"

      # 2 atribuidos + 1 sin atribuir = el KPI de requests.
      assert render(element(view, "#kpi-requests")) =~
               ~r/text-2xl font-bold[^>]*>\s*3\s*</
    end
  end

  describe "access from the services list" do
    test "services_live has a stats link for every service", %{conn: conn} do
      service = service_fixture()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, _view, html} = live(conn, ~p"/access/services")
      assert html =~ ~s(id="stats-#{service.id}")
    end
  end
end
