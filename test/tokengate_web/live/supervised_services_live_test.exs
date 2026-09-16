defmodule TokengateWeb.SupervisedServicesLiveTest do
  @moduledoc """
  Tests for `TokengateWeb.SupervisedServicesLive` — the read-only summary of
  the services the current user supervises.

  Verifies:
    * unauthenticated → /login redirect
    * signed-in user who supervises NOTHING → /dashboard (the page is not a
      public "empty state": access is the supervision row, not the session)
    * supervisor WITH a supervised service → summary card with real 30d numbers
    * every card links to the per-service full stats
    * removing the supervision row revokes the access (next mount AND the open
      view, which reacts to the PubSub notice)
    * view exposes ZERO mutating buttons (read-only contract)
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

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "sup-#{u}@example.com",
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

  # Builds a fresh service in the DB and links `user` as its supervisor.
  # Returns the bare service struct. `attrs` is a string-keyed map merged
  # on top of the defaults (e.g. `%{"name" => "Bot de Telegram"}`).
  defp supervised_service(user, attrs \\ %{}) do
    u = unique()

    base_attrs = %{
      "name" => "Svc #{u}",
      "group_id" => svc_group_id(),
      "concurrency_limit" => 5,
      "rpm_limit" => 60
    }

    {:ok, service} = Accounts.create_service(Map.merge(base_attrs, attrs))
    {:ok, _} = Accounts.add_service_supervisor(service.id, user.id)

    service
  end

  # Generates an API key for the service and returns the service with the
  # api_key preloaded (so the card can render the prefix + status badge).
  defp with_api_key(service) do
    {:ok, _api_key, _token} = Accounts.generate_service_api_key(service)
    Repo.preload(service, :api_key)
  end

  # Returns %{model: model}. Used to attach a granted model to a service.
  defp grant_model_to_service(service) do
    u = unique()

    {:ok, model_} =
      Providers.create_model(%{
        name: "sup-model-#{u}",
        context_window: 128_000
      })

    {:ok, _} = Providers.grant_model_to_service(service.id, model_.id)
    %{model: model_}
  end

  # A request log for a SERVICE subject — services carry `service_id`, never
  # `group_member_id`, which is exactly what the summary must aggregate.
  defp log_for(service, attrs \\ %{}) do
    Logs.log_request(
      Map.merge(
        %{
          subject_type: "service",
          service_id: service.id,
          model_requested: "gpt-4o-svc",
          status_code: 200,
          prompt_tokens: 100,
          completion_tokens: 50,
          provider_cost_usd: Decimal.new("0.50"),
          latency_ms: 300
        },
        attrs
      )
    )
  end

  # ----------------------------------------------------------------------
  # Access control
  # ----------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} =
             live(conn, ~p"/services/supervised")
  end

  test "signed-in user who supervises nothing is redirected to /dashboard", %{conn: conn} do
    u = unique()

    {:ok, _service} =
      Accounts.create_service(%{
        "name" => "Unrelated Svc #{u}",
        "group_id" => svc_group_id()
      })

    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             live(conn, ~p"/services/supervised")
  end

  test "a service created but never assigned grants no access", %{conn: conn} do
    # The user created nothing and supervises nothing — the sidebar has no
    # entry and the route itself is closed.
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             live(conn, ~p"/services/supervised")
  end

  test "an admin who supervises nothing gets no access either (role is not enough)",
       %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             live(conn, ~p"/services/supervised")
  end

  # ----------------------------------------------------------------------
  # Summary per service
  # ----------------------------------------------------------------------

  test "supervisor sees the 30d summary of their service with real numbers", %{conn: conn} do
    %{user: user, password: password} = register("user")
    service = supervised_service(user, %{"name" => "Bot de Telegram"})

    # 3 requests, $0.50 each → $1.50 · one of them a 500.
    {:ok, _} = log_for(service)
    {:ok, _} = log_for(service)
    {:ok, _} = log_for(service, %{status_code: 500, provider_cost_usd: Decimal.new("0.50")})

    conn = login(conn, user, password)
    {:ok, view, html} = live(conn, ~p"/services/supervised")

    refute has_element?(view, "#supervised-empty")
    assert has_element?(view, "#supervised-readonly-badge")
    assert html =~ "Bot de Telegram"

    assert render(element(view, "#supervised-service-#{service.id}")) =~ "Solo lectura"

    # Cards read from the service's own logs (`service_id`), not from
    # `group_member_id` — the numbers must be the real ones.
    assert render(element(view, "#metric-cost-#{service.id}")) =~ "$1.50"
    assert render(element(view, "#metric-requests-#{service.id}")) =~ "3"
    assert render(element(view, "#metric-errors-#{service.id}")) =~ "1"
    assert render(element(view, "#metric-input-#{service.id}")) =~ "300"
    assert render(element(view, "#metric-output-#{service.id}")) =~ "150"

    # The page totals aggregate the supervised set.
    assert render(element(view, "#totals-services")) =~ "1"
    assert render(element(view, "#totals-cost")) =~ "$1.50"
    assert render(element(view, "#totals-errors")) =~ "1"
  end

  test "logs from another service never leak into the summary", %{conn: conn} do
    %{user: user, password: password} = register("user")
    service = supervised_service(user, %{"name" => "Mío"})

    other_owner = register("user")
    other = supervised_service(other_owner.user, %{"name" => "Ajeno"})
    {:ok, _} = log_for(other, %{provider_cost_usd: Decimal.new("9.99")})

    conn = login(conn, user, password)
    {:ok, view, html} = live(conn, ~p"/services/supervised")

    assert html =~ "Mío"
    refute html =~ "Ajeno"
    assert render(element(view, "#metric-cost-#{service.id}")) =~ "$0.00"
    refute html =~ "$9.99"
  end

  test "a supervisor without traffic sees zeros, not a crash", %{conn: conn} do
    %{user: user, password: password} = register("user")
    service = supervised_service(user)

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised")

    assert render(element(view, "#metric-cost-#{service.id}")) =~ "$0.00"
    assert render(element(view, "#metric-requests-#{service.id}")) =~ "0"
    assert render(element(view, "#metric-latency-#{service.id}")) =~ "—"
  end

  test "the summary shows the API key status and the granted models", %{conn: conn} do
    %{user: user, password: password} = register("user")

    service =
      supervised_service(user, %{"name" => "Bot de Telegram"})
      |> with_api_key()

    %{model: model_} = grant_model_to_service(service)

    conn = login(conn, user, password)
    {:ok, view, html} = live(conn, ~p"/services/supervised")

    assert html =~ "active"
    assert html =~ service.api_key.key_prefix

    assert has_element?(view, "#models-#{service.id}")
    assert has_element?(view, "#model-badge-#{service.id}-#{model_.id}")
    assert html =~ model_.name
  end

  test "service with no models shows the empty models message", %{conn: conn} do
    %{user: user, password: password} = register("user")
    service = supervised_service(user)

    conn = login(conn, user, password)
    {:ok, view, html} = live(conn, ~p"/services/supervised")

    assert has_element?(view, "#models-#{service.id}")
    assert html =~ "Este servicio no tiene models asignados."
  end

  test "every card links to the full stats of that service", %{conn: conn} do
    %{user: user, password: password} = register("user")
    service = supervised_service(user)

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised")

    assert has_element?(
             view,
             "#service-stats-link-#{service.id}[href='/services/supervised/#{service.id}']"
           )
  end

  # ----------------------------------------------------------------------
  # Revocation
  # ----------------------------------------------------------------------

  test "removing one of two supervised services drops that card in place", %{conn: conn} do
    %{user: user, password: password} = register("user")
    kept = supervised_service(user, %{"name" => "Se queda"})
    dropped = supervised_service(user, %{"name" => "Se va"})

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised")

    assert has_element?(view, "#supervised-service-#{dropped.id}")

    {:ok, :removed} = Accounts.remove_service_supervisor(dropped.id, user.id)
    render(view)

    refute has_element?(view, "#supervised-service-#{dropped.id}")
    assert has_element?(view, "#supervised-service-#{kept.id}")
  end

  test "removing the LAST supervised service kicks the open view out", %{conn: conn} do
    %{user: user, password: password} = register("user")
    service = supervised_service(user)

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised")

    {:ok, :removed} = Accounts.remove_service_supervisor(service.id, user.id)

    assert_redirect(view, ~p"/dashboard")
  end

  test "a revoked supervisor loses the access on the next mount", %{conn: conn} do
    %{user: user, password: password} = register("user")
    service = supervised_service(user)

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised")
    assert has_element?(view, "#supervised-service-#{service.id}")

    {:ok, :removed} = Accounts.remove_service_supervisor(service.id, user.id)

    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             live(conn, ~p"/services/supervised")
  end

  test "assigning a new service reaches an already-open view", %{conn: conn} do
    %{user: user, password: password} = register("user")
    supervised_service(user, %{"name" => "Primero"})

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised")

    u = unique()

    {:ok, fresh} =
      Accounts.create_service(%{"name" => "Recién asignado #{u}", "group_id" => svc_group_id()})

    {:ok, _} = Accounts.add_service_supervisor(fresh.id, user.id)
    render(view)

    assert has_element?(view, "#supervised-service-#{fresh.id}")
  end

  # ----------------------------------------------------------------------
  # Read-only contract
  # ----------------------------------------------------------------------

  test "supervisor sees ZERO mutating buttons (read-only contract)", %{conn: conn} do
    %{user: user, password: password} = register("user")
    supervised_service(user, %{"name" => "Bot de Telegram"})

    conn = login(conn, user, password)
    {:ok, view, html} = live(conn, ~p"/services/supervised")

    # No ServicesLive controls should ever render in the supervised view.
    refute has_element?(view, "#new-service-btn")
    refute html =~ "phx-click=\"edit_service\""
    refute html =~ "phx-click=\"delete_service\""
    refute html =~ "phx-click=\"generate_key\""
    refute html =~ "phx-click=\"revoke_key\""
    refute html =~ "phx-click=\"toggle_model\""
    refute html =~ "phx-click=\"add_supervisor\""
    refute html =~ "phx-click=\"remove_supervisor\""

    # No forms inside the supervised view either
    refute has_element?(view, "#service-form")

    # The "Solo lectura" badge IS displayed so the supervisor knows
    assert has_element?(view, "#supervised-readonly-badge")
  end

  test "mutating phx-click event is halted by the read-only hook", %{conn: conn} do
    %{user: user, password: password} = register("user")
    supervised_service(user, %{"name" => "Doomed Svc"})

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/services/supervised")

    # Even though the DOM has no such button, a hostile client could try to
    # fire a raw event at the WebSocket. The handle_event fallback
    # halts with a flash.
    html = render_click(view, "delete_service", %{"id" => "anything"})

    assert html =~ "Esta vista es de solo lectura"
    # The DB is unchanged: the service still exists
    assert Repo.get_by(Tokengate.Accounts.Service, name: "Doomed Svc") != nil
  end

  # ----------------------------------------------------------------------
  # Sidebar entry
  # ----------------------------------------------------------------------

  test "supervisor gets a sidebar entry to /services/supervised", %{conn: conn} do
    %{user: user, password: password} = register("user")
    supervised_service(user, %{"name" => "Bot de Telegram"})

    conn = login(conn, user, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#sidebar-link-services-supervised[href='/services/supervised']")
    assert html =~ "Servicios supervisados"
  end

  test "non-supervisor gets no sidebar entry", %{conn: conn} do
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    refute has_element?(view, "#sidebar-link-services-supervised")
  end

  test "revocation also removes the sidebar entry", %{conn: conn} do
    %{user: user, password: password} = register("user")
    service = supervised_service(user)

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")
    assert has_element?(view, "#sidebar-link-services-supervised")

    {:ok, :removed} = Accounts.remove_service_supervisor(service.id, user.id)

    # A fresh mount (new navigation) reflects the revocation.
    {:ok, view, _html} = live(conn, ~p"/dashboard")
    refute has_element?(view, "#sidebar-link-services-supervised")
  end

  test "admin gets no supervised entry (reaches every service via /access/services)",
       %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    supervised_service(admin, %{"name" => "Bot admin"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    refute has_element?(view, "#sidebar-link-services-supervised")
  end
end
