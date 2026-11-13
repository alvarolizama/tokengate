defmodule TokengateWeb.SupervisedServiceStatsLiveTest do
  @moduledoc """
  Tests for `TokengateWeb.SupervisedServiceStatsLive` — the full read-only
  stats of ONE supervised service (`/services/supervised/:service_id`).

  Verifies:
    * unauthenticated → /login redirect
    * signed-in user with no supervision → /dashboard
    * supervisor of a DIFFERENT service → back to the supervised list (the
      detail is scoped to that service's own supervisor row)
    * supervisor of the service → KPIs, per-model table, status classes, top
      models, supervisor roster, config and recent requests
    * the period selector is `patch` navigation and the numbers follow it
    * `load_more` is allowed; every other event is halted (read-only contract)
    * removing the supervision row while the page is open navigates away
  """
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Logs, Providers}
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Repo

  defp unique, do: System.unique_integer([:positive])

  defp svc_group_id do
    {:ok, group} = Accounts.create_group(%{name: "Svc Group #{unique()}"})
    group.id
  end

  defp register(role \\ "user") do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "svcstats-#{u}@example.com",
        name: "Supervisor #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    # Este archivo afirma los textos en español del LiveView; el idioma por
    # defecto de la UI es inglés, así que el usuario arranca en español.
    {:ok, user} = Accounts.update_user_locale(user, "es")

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp service(attrs \\ %{}) do
    base = %{"name" => "Svc #{unique()}", "group_id" => svc_group_id()}
    {:ok, service} = Accounts.create_service(Map.merge(base, attrs))
    service
  end

  defp supervised(service, user) do
    {:ok, _} = Accounts.add_service_supervisor(service.id, user.id)
    service
  end

  defp log_for(service, attrs \\ %{}) do
    Logs.log_request(
      Map.merge(
        %{
          subject_type: "service",
          service_id: service.id,
          model_requested: "gpt-4o-svc",
          model_responded: "gpt-4o-svc",
          status_code: 200,
          prompt_tokens: 1_000,
          completion_tokens: 500,
          provider_cost_usd: Decimal.new("0.25"),
          latency_ms: 400
        },
        attrs
      )
    )
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

  # Texto de una celda de la tabla de keys, sin el ruido del HTML.
  defp cell_text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns

  # La carga del período corre en `start_async/3` (carga async, igual que el
  # admin en /stats): el primer render llega con los assigns vacíos, así que se
  # espera el assign y no el HTML — que conserva las clases de loading.
  defp wait_loaded(view) do
    wait_for_assign(view, fn assigns -> assigns.stats_loading == false end)
  end

  # El summary del realtime se recomputa con el timer de coalescing (2 s);
  # :sys.get_state devuelve el estado actual, así que se espera a que el
  # assign cumpla la condición en vez de dormir a ciegas.
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

  defp grant_model(service) do
    {:ok, model_} =
      Providers.create_model(%{name: "svc-model-#{unique()}", context_window: 128_000})

    {:ok, _} = Providers.grant_model_to_service(service.id, model_.id)
    model_
  end

  # Rows of the recent-activity stream, empty-state row excluded. Counting the
  # DOM rows (instead of matching text) is the only honest check here: the
  # empty-state row is always in the markup, hidden by `only:table-row`.
  defp log_rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#supervised-service-logs tr:not(#supervised-service-logs-empty)")
  end

  # ----------------------------------------------------------------------
  # Access
  # ----------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    service = service()

    assert {:error, {:redirect, %{to: "/login"}}} =
             live(conn, ~p"/services/supervised/#{service.id}")
  end

  test "user who supervises nothing is redirected to /dashboard", %{conn: conn} do
    service = service()
    %{user: user, password: password} = register()
    conn = login(conn, user, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             live(conn, ~p"/services/supervised/#{service.id}")
  end

  test "supervising ANOTHER service does not open this one", %{conn: conn} do
    mine = service(%{"name" => "Mío"})
    other = service(%{"name" => "Ajeno"})

    %{user: user, password: password} = register()
    supervised(mine, user)

    conn = login(conn, user, password)

    assert {:error, {:live_redirect, %{to: "/services/supervised"}}} =
             live(conn, ~p"/services/supervised/#{other.id}")
  end

  test "a service id that does not exist bounces back to the list", %{conn: conn} do
    %{user: user, password: password} = register()
    supervised(service(), user)

    conn = login(conn, user, password)

    assert {:error, {:live_redirect, %{to: "/services/supervised"}}} =
             live(conn, ~p"/services/supervised/#{Ecto.UUID.generate()}")
  end

  test "an admin who supervises nothing is redirected to /dashboard", %{conn: conn} do
    service = service()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             live(conn, ~p"/services/supervised/#{service.id}")
  end

  test "an admin who supervises another service cannot open this one", %{conn: conn} do
    mine = service(%{"name" => "Mío"})
    other = service(%{"name" => "Ajeno"})

    %{user: admin, password: password} = register("admin")
    supervised(mine, admin)

    conn = login(conn, admin, password)

    assert {:error, {:live_redirect, %{to: "/services/supervised"}}} =
             live(conn, ~p"/services/supervised/#{other.id}")
  end

  # ----------------------------------------------------------------------
  # Full stats
  # ----------------------------------------------------------------------

  test "supervisor sees the service's KPIs, models, supervisors and config", %{conn: conn} do
    %{user: user, password: password} = register()
    service = service(%{"name" => "Bot de Telegram"}) |> supervised(user)

    {:ok, _api_key, _token} = Accounts.generate_service_api_key(service)
    service = Repo.preload(service, :api_key)
    model_ = grant_model(service)

    {:ok, _} = log_for(service, %{model_id: model_.id})
    {:ok, _} = log_for(service, %{model_id: model_.id, status_code: 502})

    conn = login(conn, user, password)
    {:ok, view, html} = live(conn, ~p"/services/supervised/#{service.id}")
    wait_loaded(view)

    assert has_element?(view, "#supervised-service-readonly")
    assert html =~ "Bot de Telegram"
    assert html =~ "Stats completos"

    # KPI strip (30d default)
    assert render(element(view, "#kpi-cost")) =~ "$0.50"
    assert render(element(view, "#kpi-requests")) =~ "2"
    assert render(element(view, "#kpi-input")) =~ "2.0K"
    assert render(element(view, "#kpi-output")) =~ "1.0K"
    assert render(element(view, "#kpi-errors")) =~ "1"

    # Model × API key pivot (shared body): the old per-model card is gone and
    # the daily-series chart is no longer rendered at all. Status classes and
    # top models stay on the page (the pivot does not replace those cards).
    assert has_element?(view, "#service-model-breakdown-table")
    assert has_element?(view, "#model-breakdown-gpt-4o-svc")
    refute html =~ "Uso diario por modelo"

    # Status breakdown + top models (never dropped by the shared body)
    assert render(element(view, "#status-breakdown")) =~ "badge-error"
    assert render(element(view, "#top-models")) =~ "gpt-4o-svc"

    # Supervisor roster + read-only config stay on the page
    assert render(element(view, "#service-supervisors")) =~ user.email
    assert render(element(view, "#service-config")) =~ service.api_key.key_prefix
    assert has_element?(view, "#model-badge-#{service.id}-#{model_.id}")

    # Recent requests: both of them, including the failed one
    assert Enum.count(log_rows(view)) == 2
    assert render(view) =~ "502"
  end

  test "logs from another service never show up in the detail", %{conn: conn} do
    %{user: user, password: password} = register()
    service = service() |> supervised(user)
    other = service()

    {:ok, _} = log_for(service, %{model_requested: "solo-este"})
    {:ok, _} = log_for(other, %{model_requested: "otro-servicio"})

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised/#{service.id}")
    wait_loaded(view)

    html = render(view)
    assert html =~ "solo-este"
    refute html =~ "otro-servicio"
    assert Enum.count(log_rows(view)) == 1
  end

  test "the roster lists every supervisor of the service", %{conn: conn} do
    %{user: user, password: password} = register()
    peer = register()
    service = service() |> supervised(user) |> supervised(peer.user)

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised/#{service.id}")
    wait_loaded(view)

    assert has_element?(view, "#service-supervisor-#{user.id}")
    assert has_element?(view, "#service-supervisor-#{peer.user.id}")
  end

  test "a service with no traffic renders empty states, not a crash", %{conn: conn} do
    %{user: user, password: password} = register()
    service = service() |> supervised(user)

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised/#{service.id}")
    wait_loaded(view)

    assert has_element?(view, "#service-model-breakdown-empty")
    assert render(element(view, "#kpi-cost")) =~ "$0.00"
    assert Enum.count(log_rows(view)) == 0
  end

  # ----------------------------------------------------------------------
  # Period
  # ----------------------------------------------------------------------

  test "the period selector patches the URL and the numbers follow", %{conn: conn} do
    %{user: user, password: password} = register()
    service = service() |> supervised(user)

    # Inside every window: $0.25.
    {:ok, _} = log_for(service)

    # Older than 7 days, inside 30/90: $0.25 more.
    old_date =
      DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

    {:ok, _} = log_for(service, %{inserted_at: old_date})

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised/#{service.id}")
    wait_loaded(view)

    # 30d default: both requests.
    assert render(element(view, "#kpi-cost")) =~ "$0.50"

    # Every period is a patch link (no event, nothing to halt).
    assert has_element?(
             view,
             "#period-week[href='/services/supervised/#{service.id}?period=week']"
           )

    assert has_element?(
             view,
             "#period-last_month[href='/services/supervised/#{service.id}?period=last_month']"
           )

    # Navigating with the param answers the narrower window: only the fresh one.
    {:ok, view_week, _html} = live(conn, ~p"/services/supervised/#{service.id}?period=week")
    wait_loaded(view_week)
    assert render(element(view_week, "#kpi-cost")) =~ "$0.25"
    refute render(element(view_week, "#kpi-cost")) =~ "$0.50"

    # An unknown period falls back to the 30d default instead of crashing.
    {:ok, view_bogus, _html} = live(conn, ~p"/services/supervised/#{service.id}?period=banana")
    wait_loaded(view_bogus)
    assert render(element(view_bogus, "#kpi-cost")) =~ "$0.50"
  end

  # ----------------------------------------------------------------------
  # Pagination + read-only contract
  # ----------------------------------------------------------------------

  test "load_more is allowed and pages the recent activity", %{conn: conn} do
    %{user: user, password: password} = register()
    service = service() |> supervised(user)

    for i <- 1..30 do
      {:ok, _} =
        log_for(service, %{
          inserted_at:
            DateTime.utc_now() |> DateTime.add(-i, :second) |> DateTime.truncate(:second)
        })
    end

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised/#{service.id}")
    wait_loaded(view)

    assert Enum.count(log_rows(view)) == 25
    assert has_element?(view, "#load-more-supervised-logs")

    html = render_click(element(view, "#load-more-supervised-logs"))

    refute html =~ "Esta vista es de solo lectura"
    assert Enum.count(log_rows(view)) == 30
    # 30 logs, page size 25 → after the second page there is nothing left.
    refute has_element?(view, "#load-more-supervised-logs")
  end

  test "no mutating control is rendered (read-only contract)", %{conn: conn} do
    %{user: user, password: password} = register()
    service = service() |> supervised(user)

    conn = login(conn, user, password)
    {:ok, view, html} = live(conn, ~p"/services/supervised/#{service.id}")
    wait_loaded(view)

    refute has_element?(view, "#new-service-btn")
    refute html =~ "phx-click=\"edit_service\""
    refute html =~ "phx-click=\"delete_service\""
    refute html =~ "phx-click=\"generate_key\""
    refute html =~ "phx-click=\"revoke_key\""
    refute html =~ "phx-click=\"toggle_model\""
    refute html =~ "phx-click=\"add_supervisor\""
    refute html =~ "phx-click=\"remove_supervisor\""
    refute has_element?(view, "#service-form")
  end

  test "any other event is halted by the read-only hook", %{conn: conn} do
    %{user: user, password: password} = register()
    service = service(%{"name" => "Intacto"}) |> supervised(user)

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised/#{service.id}")
    wait_loaded(view)

    html = render_click(view, "delete_service", %{"id" => service.id})

    assert html =~ "Esta vista es de solo lectura"
    assert Accounts.get_service(service.id) != nil

    html = render_click(view, "revoke_key", %{"service-id" => service.id})
    assert html =~ "Esta vista es de solo lectura"
  end

  # ----------------------------------------------------------------------
  # Admin parity: API keys, key scope, log filters, realtime
  # ----------------------------------------------------------------------

  describe "admin parity" do
    test "the API key table lists labels, including a revoked key with zeros", %{conn: conn} do
      %{user: user, password: password} = register()
      service = service() |> supervised(user)
      active = key_fixture(service, %{"label" => "Activa"})
      revoked = key_fixture(service, %{"label" => "Vieja"})
      {:ok, _} = Accounts.revoke_api_key(revoked)
      {:ok, _} = log_for(service, %{api_key_id: active.id})

      conn = login(conn, user, password)
      {:ok, view, _html} = live(conn, ~p"/services/supervised/#{service.id}")
      wait_loaded(view)

      assert has_element?(view, "#service-api-keys-table")
      assert cell_text(view, "#api-key-row-#{active.id} td:nth-child(1)") == "Activa"

      # La revocada no tiene tráfico en la ventana: la fila existe igual, con
      # ceros y su badge de estado (nunca el secreto ni el uuid desnudo).
      row = "#api-key-row-#{revoked.id}"
      assert cell_text(view, "#{row} td:nth-child(1)") == "Vieja"
      assert cell_text(view, "#{row} td:nth-child(2)") == "revoked"
      assert cell_text(view, "#{row} td:nth-child(3)") == "0"
      assert cell_text(view, "#{row} td:nth-child(4)") == "0"
      assert cell_text(view, "#{row} td:nth-child(6)") == "$0.00"
      assert has_element?(view, "#{row} .badge-error")

      # El selector lista las keys por label y marca la revocada.
      assert render(element(view, "#key-filter-form")) =~ "Vieja · Revocada"
    end

    test "set_key scopes summary, pivot and logs to one key and back to all", %{conn: conn} do
      %{user: user, password: password} = register()
      service = service() |> supervised(user)
      key_a = key_fixture(service, %{"label" => "Alpha"})
      key_b = key_fixture(service, %{"label" => "Beta"})

      {:ok, _} = log_for(service, %{api_key_id: key_a.id, model_requested: "alpha-model"})
      {:ok, _} = log_for(service, %{api_key_id: key_b.id, model_requested: "beta-model"})

      conn = login(conn, user, password)
      {:ok, view, _html} = live(conn, ~p"/services/supervised/#{service.id}")
      wait_loaded(view)

      # Todas: dos filas, los dos modelos en el pivote y KPI = 2.
      assert has_element?(view, "#api-key-row-#{key_a.id}")
      assert has_element?(view, "#api-key-row-#{key_b.id}")
      assert has_element?(view, "#model-breakdown-alpha-model")
      assert has_element?(view, "#model-breakdown-beta-model")
      assert render(element(view, "#kpi-requests")) =~ ~r/text-2xl font-bold[^>]*>\s*2\s*</

      # Sólo Beta: una fila, un modelo en el pivote, KPI = 1 y logs scopeados.
      view
      |> form("#key-filter-form", %{"key_filter" => %{"key_id" => key_b.id}})
      |> render_change()

      assert has_element?(view, "#api-key-row-#{key_b.id}")
      refute has_element?(view, "#api-key-row-#{key_a.id}")
      assert has_element?(view, "#model-breakdown-beta-model")
      refute has_element?(view, "#model-breakdown-alpha-model")
      assert render(element(view, "#kpi-requests")) =~ ~r/text-2xl font-bold[^>]*>\s*1\s*</
      assert render(view) =~ "beta-model"
      refute render(view) =~ "alpha-model"

      # De vuelta a todas.
      view
      |> form("#key-filter-form", %{"key_filter" => %{"key_id" => "all"}})
      |> render_change()

      assert has_element?(view, "#api-key-row-#{key_a.id}")
      assert has_element?(view, "#api-key-row-#{key_b.id}")
      assert render(element(view, "#kpi-requests")) =~ ~r/text-2xl font-bold[^>]*>\s*2\s*</
    end

    test "the log filter is allowed by the read-only hook and narrows the stream", %{conn: conn} do
      %{user: user, password: password} = register()
      service = service() |> supervised(user)

      {:ok, ok_log} = log_for(service, %{model_requested: "ok-model", status_code: 200})
      {:ok, boom_log} = log_for(service, %{model_requested: "boom-model", status_code: 500})

      conn = login(conn, user, password)
      {:ok, view, _html} = live(conn, ~p"/services/supervised/#{service.id}")
      wait_loaded(view)

      assert has_element?(view, "#logs-#{ok_log.id}")
      assert has_element?(view, "#logs-#{boom_log.id}")

      html =
        view
        |> form("#service-stats-filter-form", %{"filter" => %{"status_class" => "5xx"}})
        |> render_change()

      # El hook read-only NO haltea el filtro: es un evento de vista. La tabla
      # de logs se refiltra (el pivote no depende del filtro de status).
      refute html =~ "Esta vista es de solo lectura"
      assert has_element?(view, "#logs-#{boom_log.id}")
      refute has_element?(view, "#logs-#{ok_log.id}")

      # Quitar el filtro vuelve a traer todo.
      view
      |> form("#service-stats-filter-form", %{"filter" => %{"status_class" => ""}})
      |> render_change()

      assert has_element?(view, "#logs-#{ok_log.id}")
    end

    test "logs:new lands in the stream and refreshes the summary coalesced", %{conn: conn} do
      %{user: user, password: password} = register()
      service = service() |> supervised(user)

      conn = login(conn, user, password)
      {:ok, view, _html} = live(conn, ~p"/services/supervised/#{service.id}")
      wait_loaded(view)

      assert render(element(view, "#kpi-requests")) =~ ~r/text-2xl font-bold[^>]*>\s*0\s*</

      {:ok, log_one} = log_for(service, %{model_requested: "live-one"})
      {:ok, log_two} = log_for(service, %{model_requested: "live-two"})

      # El proxy publica `logs:new` por cada request; el summary se recomputa
      # como mucho una vez por ventana de coalescing (2 s).
      Phoenix.PubSub.broadcast(Tokengate.PubSub, "logs:new", {:new_log, log_one})
      Phoenix.PubSub.broadcast(Tokengate.PubSub, "logs:new", {:new_log, log_two})

      # La entrada al stream es inmediata…
      assert has_element?(view, "#logs-#{log_one.id}")
      assert has_element?(view, "#logs-#{log_two.id}")
      # …y sólo hay un refresh pendiente.
      assert assigns_of(view).summary_refresh_scheduled

      # El TTL corto del DashboardCache es la ventana de staleness documentada
      # del summary; aquí se fuerza el recompute para no medir el TTL.
      DashboardCache.invalidate_all()

      wait_for_assign(view, fn assigns -> assigns.summary.request_count == 2 end)

      assert render(element(view, "#kpi-requests")) =~ ~r/text-2xl font-bold[^>]*>\s*2\s*</
      refute assigns_of(view).summary_refresh_scheduled
    end

    test "the daily-series chart is gone; the model pivot replaces it", %{conn: conn} do
      %{user: user, password: password} = register()
      service = service() |> supervised(user)

      conn = login(conn, user, password)
      {:ok, view, html} = live(conn, ~p"/services/supervised/#{service.id}")
      wait_loaded(view)

      refute html =~ "Uso diario por modelo"
      assert has_element?(view, "#service-model-breakdown-table")
      assert has_element?(view, "#supervised-service-readonly")
    end
  end

  # ----------------------------------------------------------------------
  # Revocation
  # ----------------------------------------------------------------------

  test "removing the supervision row closes the open detail page", %{conn: conn} do
    %{user: user, password: password} = register()
    service = service() |> supervised(user)

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised/#{service.id}")
    wait_loaded(view)

    {:ok, :removed} = Accounts.remove_service_supervisor(service.id, user.id)

    assert_redirect(view, ~p"/services/supervised")
  end

  test "revocation of ANOTHER service leaves this page alone", %{conn: conn} do
    %{user: user, password: password} = register()
    kept = service() |> supervised(user)
    peer_service = service() |> supervised(user)

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised/#{kept.id}")
    wait_loaded(view)

    {:ok, :removed} = Accounts.remove_service_supervisor(peer_service.id, user.id)

    # Still rendering the page of the service that is still supervised.
    assert has_element?(view, "#kpi-cost")
  end

  test "a failed async load (timeout) surfaces a visible banner", %{conn: conn} do
    %{user: user, password: password} = register()
    service = service() |> supervised(user)

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised/#{service.id}")
    wait_loaded(view)

    # Happy path: no banner.
    refute has_element?(view, "#supervised-stats-load-error")

    # The async bundle died (cold queries hitting the start_async timeout):
    # the callback must leave a visible error state, not just a log line.
    socket = :sys.get_state(view.pid).socket

    assert {:noreply, socket} =
             TokengateWeb.SupervisedServiceStatsLive.handle_async(
               :service_bundle,
               {:exit, :timeout},
               socket
             )

    assert socket.assigns.load_error == :load_failed
    assert socket.assigns.stats_loading == false

    # The template gates `#supervised-stats-load-error` on `load_error` (the
    # full template can't be rendered outside a LiveView: it mounts the
    # profile-modal LiveComponent), so the assign is the contract here.
  end
end
