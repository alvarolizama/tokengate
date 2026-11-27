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

  defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns

  defp wait_loaded(view) do
    wait_for_assign(view, fn assigns -> assigns.stats_loading == false end)
    view
  end

  defp wait_for_assign(view, fun, tries \\ 100) do
    cond do
      fun.(assigns_of(view)) ->
        :ok

      tries == 0 ->
        flunk("timed out waiting for the LiveView assign")

      true ->
        Process.sleep(50)
        wait_for_assign(view, fun, tries - 1)
    end
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

      {:ok, view, _html} = live(conn, ~p"/stats/services/#{service.id}?tab=logs")
      html = render(wait_loaded(view))

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

      {:ok, view, _html} = live(conn, ~p"/stats/services/#{service.id}?tab=logs")
      html = render(wait_loaded(view))

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
      wait_loaded(view)

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
      wait_loaded(view)

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
      wait_loaded(view)

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
      wait_loaded(view)

      # Todas (default): las dos filas —la revocada incluida— y KPI = 2.
      assert has_element?(view, "#api-key-row-#{key_a.id}")
      assert has_element?(view, "#api-key-row-#{key_b.id}")
      assert render(element(view, "#kpi-requests")) =~ ~r/text-2xl font-bold[^>]*>\s*2\s*</

      # Sólo Beta (revocada): una fila, KPI = 1, logs scopeados y el selector
      # la lista marcada como revocada. Payload REAL del browser: anidado por
      # el to_form (name="key_filter[key_id]").
      view
      |> form("#key-filter-form", %{"key_filter" => %{"key_id" => key_b.id}})
      |> render_change()

      html = render(wait_loaded(view))

      assert html =~ "Beta · Revocada"
      assert has_element?(view, "#api-key-row-#{key_b.id}")
      refute has_element?(view, "#api-key-row-#{key_a.id}")
      assert render(element(view, "#kpi-requests")) =~ ~r/text-2xl font-bold[^>]*>\s*1\s*</
      assert cell_text(view, "#api-key-row-#{key_b.id} td:nth-child(3)") == "1"

      # La lista de logs quedó scopeada a la key elegida (Live logs tab).
      view |> element("#tab-logs") |> render_click()
      wait_loaded(view)

      assert render(view) =~ "beta-model"
      refute render(view) =~ "alpha-model"

      # De vuelta a todas: la tabla de keys se lee en Overview.
      view |> element("#tab-overview") |> render_click()
      wait_loaded(view)

      view
      |> form("#key-filter-form", %{"key_filter" => %{"key_id" => "all"}})
      |> render_change()

      wait_loaded(view)

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
      wait_loaded(view)

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
      wait_loaded(view)

      assert has_element?(view, "#api-key-row-#{key.id}")
      assert cell_text(view, "#api-key-row-#{key.id} td:nth-child(3)") == "1"
      assert render(element(view, "#kpi-requests")) =~ ~r/text-2xl font-bold[^>]*>\s*1\s*</

      # Click a "30d": el log de hoy también cae dentro de la ventana móvil.
      view |> element("#period-30d") |> render_click()
      wait_loaded(view)

      assert has_element?(view, "#api-key-row-#{key.id}")

      # Un periodo desconocido viaja por la URL y se resuelve al default en
      # vez de reventar.
      {:ok, view_bogus, _html} = live(conn, ~p"/stats/services/#{service.id}?period=hack")
      wait_loaded(view_bogus)

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
      wait_loaded(view)

      key_row = "#api-key-row-#{key.id}"

      assert cell_text(view, "#{key_row} td:nth-child(3)") == "2"
      assert cell_text(view, "#{key_row} td:nth-child(4)") == "200"
      assert cell_text(view, "#{key_row} td:nth-child(5)") == "100"
      assert cell_text(view, "#api-key-row-unattributed td:nth-child(3)") == "1"

      # 2 atribuidos + 1 sin atribuir = el KPI de requests.
      assert render(element(view, "#kpi-requests")) =~
               ~r/text-2xl font-bold[^>]*>\s*3\s*</
    end

    test "a failed async load surfaces load_error state", %{conn: conn} do
      service = service_fixture()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats/services/#{service.id}")
      wait_loaded(view)

      refute has_element?(view, "#service-stats-load-error")

      socket = :sys.get_state(view.pid).socket

      assert {:noreply, socket} =
               TokengateWeb.ServiceStatsLive.handle_async(
                 :service_bundle,
                 {:exit, :timeout},
                 socket
               )

      assert socket.assigns.load_error == :load_failed
      assert socket.assigns.stats_loading == false
    end
  end

  describe "finops tab" do
    test "renders unit economics, waste & taxes, the trend and the efficiency tables", %{
      conn: conn
    } do
      service = service_fixture()
      key = key_fixture(service, %{"label" => "Alpha"})

      {:ok, _} =
        log_for(service, %{
          api_key_id: key.id,
          prompt_tokens: 1_000,
          completion_tokens: 500,
          cache_read_tokens: 400,
          provider_cost_usd: Decimal.new("0.20")
        })

      {:ok, _} =
        log_for(service, %{
          api_key_id: key.id,
          status_code: 500,
          prompt_tokens: 0,
          completion_tokens: 0,
          provider_cost_usd: Decimal.new("0.10")
        })

      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats/services/#{service.id}?tab=finops")
      wait_loaded(view)

      assert has_element?(view, "#tab-finops.tab-active")
      assert has_element?(view, "#service-stats-finops")

      # Unit economics: $0.30 en 2 requests → $0.15/req, Out/In 0.5x.
      assert render(element(view, "#finops-cpr")) =~ "$0.15"
      assert has_element?(view, "#finops-cpm")
      assert render(element(view, "#finops-out-in")) =~ "0.5x"
      assert has_element?(view, "#finops-burn")

      # Waste & taxes: el 500 cuesta $0.10 y el cache hit 400/1000 = 40%.
      assert render(element(view, "#finops-error-waste")) =~ "$0.1"
      assert has_element?(view, "#finops-thinking-tax")
      assert render(element(view, "#finops-prompt-cache")) =~ "40.0%"
      assert has_element?(view, "#finops-local-cache")
      assert has_element?(view, "#finops-cap")

      # Tendencia y eficiencia por key/modelo (una fila real, no el empty).
      # El log del fixture no lleva model_id: la fila de modelo es el bucket
      # sin modelo ("unknown"), no un empty-state.
      assert has_element?(view, "#finops-trend-chart")
      assert has_element?(view, "#finops-key-#{key.id}")
      assert has_element?(view, "#finops-model-unknown")
    end

    test "the key selector keeps the full-service total as the % of spend denominator", %{
      conn: conn
    } do
      service = service_fixture()
      key_a = key_fixture(service, %{"label" => "Alpha"})
      key_b = key_fixture(service, %{"label" => "Beta"})

      {:ok, _} = log_for(service, %{api_key_id: key_a.id})
      {:ok, _} = log_for(service, %{api_key_id: key_b.id})

      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats/services/#{service.id}")
      wait_loaded(view)

      assert cell_text(view, "#api-key-row-#{key_a.id} td:nth-child(7)") == "50.0%"

      view
      |> form("#key-filter-form", %{"key_filter" => %{"key_id" => key_a.id}})
      |> render_change()

      wait_loaded(view)

      # La fila visible mide contra el gasto del servicio COMPLETO, no contra
      # la lista ya filtrada (que daría 100%).
      assert cell_text(view, "#api-key-row-#{key_a.id} td:nth-child(7)") == "50.0%"
    end

    test "tab and period patch links carry the selected key", %{conn: conn} do
      service = service_fixture()
      key = key_fixture(service, %{"label" => "Beta"})
      {:ok, _} = log_for(service, %{api_key_id: key.id})

      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats/services/#{service.id}")
      wait_loaded(view)

      view
      |> form("#key-filter-form", %{"key_filter" => %{"key_id" => key.id}})
      |> render_change()

      wait_loaded(view)

      assert render(element(view, "#tab-finops")) =~ "key_id=#{key.id}"
      assert render(element(view, "#period-today")) =~ "key_id=#{key.id}"

      # Navegar al tab FinOps relee el key_id de la URL y no pierde el scope.
      view |> element("#tab-finops") |> render_click()
      wait_loaded(view)

      assert assigns_of(view).tab == "finops"
      assert assigns_of(view).key_filter == key.id
    end

    test "the monthly-cap sub only reads as a percentage for a month period", %{conn: conn} do
      {:ok, service} =
        Accounts.create_service(%{name: "Cap #{unique()}", monthly_spend_limit_usd: "100.00"})

      {:ok, _} = log_for(service, %{})

      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, view, _html} = live(conn, ~p"/stats/services/#{service.id}")
      wait_loaded(view)

      cost = render(element(view, "#kpi-cost"))
      refute cost =~ ~r/of monthly cap|del tope mensual/i
      assert cost =~ ~r/proj|proy/
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

    test "unknown or malformed service_id redirects to /stats/services instead of crashing", %{
      conn: conn
    } do
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      assert {:error, {:live_redirect, %{to: "/stats/services"}}} =
               live(conn, ~p"/stats/services/not-a-uuid")

      assert {:error, {:live_redirect, %{to: "/stats/services"}}} =
               live(conn, ~p"/stats/services/#{Ecto.UUID.generate()}")
    end
  end
end
