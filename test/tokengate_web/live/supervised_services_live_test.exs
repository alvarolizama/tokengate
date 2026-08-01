defmodule TokengateWeb.SupervisedServicesLiveTest do
  @moduledoc """
  Tests for `TokengateWeb.SupervisedServicesLive` — the read-only view of
  services the current user supervises.

  Verifies:
    * unauthenticated → /login redirect
    * authenticated user with NO supervised services → empty state
    * authenticated user WITH a supervised service → card visible
    * view exposes ZERO mutating buttons (read-only contract)
  """
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Providers}
  alias Tokengate.Repo

  defp unique, do: System.unique_integer([:positive])

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
      "monthly_budget_usd" => "50.00",
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

  # Returns %{model_alias: alias}. Used to attach a granted alias to a service.
  defp grant_alias_to_service(service) do
    u = unique()

    {:ok, alias_} =
      Providers.create_model_alias(%{
        name: "sup-alias-#{u}",
        display_name: "Sup Alias #{u}",
        context_window: 128_000
      })

    {:ok, _} = Providers.grant_alias_to_service(service.id, alias_.id)
    %{model_alias: alias_}
  end

  # ----------------------------------------------------------------------
  # Access control
  # ----------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} =
             live(conn, ~p"/dashboard/services/supervised")
  end

  # ----------------------------------------------------------------------
  # Empty state
  # ----------------------------------------------------------------------

  test "authenticated user with NO supervised services sees the empty state", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)

    {:ok, view, html} = live(conn, ~p"/dashboard/services/supervised")

    assert has_element?(view, "#supervised-empty")
    assert html =~ "No supervisas ningún servicio."
    assert html =~ "Un administrador puede asignarte servicios"
    assert html =~ "Servicios"
    refute html =~ "Svc "
    assert has_element?(view, "#supervised-readonly-badge")
  end

  test "authenticated non-admin who is NOT a supervisor sees the empty state",
       %{conn: conn} do
    # Create a service but DON'T add this user as supervisor
    u = unique()

    {:ok, _service} =
      Accounts.create_service(%{
        "name" => "Unrelated Svc #{u}",
        "monthly_budget_usd" => "10.00"
      })

    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)

    {:ok, view, html} = live(conn, ~p"/dashboard/services/supervised")

    assert has_element?(view, "#supervised-empty")
    refute html =~ "Unrelated Svc"
  end

  # ----------------------------------------------------------------------
  # Service card render with stats
  # ----------------------------------------------------------------------

  test "supervisor sees their service with api_key status, stats, and aliases",
       %{conn: conn} do
    %{user: user, password: password} = register("user")

    service =
      supervised_service(user, %{"name" => "Bot de Telegram"})
      |> with_api_key()

    %{model_alias: alias_} = grant_alias_to_service(service)

    conn = login(conn, user, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/services/supervised")

    refute has_element?(view, "#supervised-empty")

    # The service card shows the name
    assert html =~ "Bot de Telegram"

    # API key status badge — prefix + status (only ever displayed, never editable)
    assert html =~ "active"
    assert html =~ service.api_key.key_prefix

    # 30d stats row renders (zero values, since there's no log row —
    # the FK enforces `team_member_id` points to team_members, not services,
    # so live service traffic is sparse and the empty-stats branch is the
    # realistic render path).
    assert html =~ "$0.00"
    assert html =~ "Requests"
    assert html =~ "Tokens In"
    assert html =~ "Tokens Out"
    assert html =~ "Latencia media"

    # The granted alias appears as a badge, NOT as a clickable button
    assert has_element?(view, "#aliases-#{service.id}")
    assert has_element?(view, "#alias-badge-#{service.id}-#{alias_.id}")
    assert html =~ alias_.name
  end

  test "supervisor sees ZERO mutating buttons (read-only contract)", %{conn: conn} do
    %{user: user, password: password} = register("user")
    supervised_service(user, %{"name" => "Bot de Telegram"})

    conn = login(conn, user, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/services/supervised")

    # No ServicesLive controls should ever render in the supervised view.
    refute has_element?(view, "#new-service-btn")
    refute html =~ "phx-click=\"edit_service\""
    refute html =~ "phx-click=\"delete_service\""
    refute html =~ "phx-click=\"generate_key\""
    refute html =~ "phx-click=\"revoke_key\""
    refute html =~ "phx-click=\"toggle_alias\""

    # No forms inside the supervised view either
    refute has_element?(view, "#service-form")

    # The "Solo lectura" badge IS displayed so the supervisor knows
    assert has_element?(view, "#supervised-readonly-badge")
  end

  test "mutating phx-click event is halted by the read-only hook", %{conn: conn} do
    %{user: user, password: password} = register("user")
    supervised_service(user, %{"name" => "Doomed Svc"})

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/services/supervised")

    # Even though the DOM has no such button, a hostile client could try to
    # fire a raw event at the WebSocket. The handle_event fallback
    # halts with a flash.
    html = render_click(view, "delete_service", %{"id" => "anything"})

    assert html =~ "Esta vista es de solo lectura"
    # The DB is unchanged: the service still exists
    assert Repo.get_by(Tokengate.Accounts.Service, name: "Doomed Svc") != nil
  end

  # ----------------------------------------------------------------------
  # Alias visibility — granted vs not granted
  # ----------------------------------------------------------------------

  test "service with no model aliases shows the empty aliases message", %{conn: conn} do
    %{user: user, password: password} = register("user")
    service = supervised_service(user)

    conn = login(conn, user, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/services/supervised")

    assert has_element?(view, "#aliases-#{service.id}")
    assert html =~ "Este servicio no tiene modelos asignados."
  end
end
