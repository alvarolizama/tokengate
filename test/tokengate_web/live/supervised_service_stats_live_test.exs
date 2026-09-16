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

    assert has_element?(view, "#supervised-service-readonly")
    assert html =~ "Bot de Telegram"
    assert html =~ "Stats completos"

    # KPI strip (30d default)
    assert render(element(view, "#kpi-cost")) =~ "$0.50"
    assert render(element(view, "#kpi-requests")) =~ "2"
    assert render(element(view, "#kpi-input")) =~ "2.0K"
    assert render(element(view, "#kpi-output")) =~ "1.0K"
    assert render(element(view, "#kpi-errors")) =~ "1"

    # Per-model breakdown (one row per model served)
    assert has_element?(view, "#model-rows")
    assert has_element?(view, "#model-row-#{model_.id}")

    # Status classes + top models + roster + config
    assert has_element?(view, "#status-breakdown")
    assert render(element(view, "#top-models")) =~ "gpt-4o-svc"
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
    {:ok, view, html} = live(conn, ~p"/services/supervised/#{service.id}")

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

    assert has_element?(view, "#service-supervisor-#{user.id}")
    assert has_element?(view, "#service-supervisor-#{peer.user.id}")
  end

  test "a service with no traffic renders empty states, not a crash", %{conn: conn} do
    %{user: user, password: password} = register()
    service = service() |> supervised(user)

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised/#{service.id}")

    assert has_element?(view, "#model-rows-empty")
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

    # 30d default: both requests.
    assert render(element(view, "#kpi-cost")) =~ "$0.50"

    # Every period is a patch link (no event, nothing to halt).
    assert has_element?(
             view,
             "#period-7d[href='/services/supervised/#{service.id}?period=7d']"
           )

    assert has_element?(
             view,
             "#period-90d[href='/services/supervised/#{service.id}?period=90d']"
           )

    # Navigating with the param answers the narrower window: only the fresh one.
    {:ok, view_7d, _html} = live(conn, ~p"/services/supervised/#{service.id}?period=7d")
    assert render(element(view_7d, "#kpi-cost")) =~ "$0.25"
    refute render(element(view_7d, "#kpi-cost")) =~ "$0.50"

    # An unknown period falls back to the 30d default instead of crashing.
    {:ok, view_bogus, _html} = live(conn, ~p"/services/supervised/#{service.id}?period=banana")
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

    html = render_click(view, "delete_service", %{"id" => service.id})

    assert html =~ "Esta vista es de solo lectura"
    assert Accounts.get_service(service.id) != nil

    html = render_click(view, "revoke_key", %{"service-id" => service.id})
    assert html =~ "Esta vista es de solo lectura"
  end

  # ----------------------------------------------------------------------
  # Revocation
  # ----------------------------------------------------------------------

  test "removing the supervision row closes the open detail page", %{conn: conn} do
    %{user: user, password: password} = register()
    service = service() |> supervised(user)

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised/#{service.id}")

    {:ok, :removed} = Accounts.remove_service_supervisor(service.id, user.id)

    assert_redirect(view, ~p"/services/supervised")
  end

  test "revocation of ANOTHER service leaves this page alone", %{conn: conn} do
    %{user: user, password: password} = register()
    kept = service() |> supervised(user)
    peer_service = service() |> supervised(user)

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised/#{kept.id}")

    {:ok, :removed} = Accounts.remove_service_supervisor(peer_service.id, user.id)

    # Still rendering the page of the service that is still supervised.
    assert has_element?(view, "#kpi-cost")
  end
end
