defmodule TokengateWeb.ServicesLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Repo}
  alias Tokengate.Accounts.{Service, User}

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
    {:ok, service} =
      Accounts.create_service(%{
        name: "Service #{System.unique_integer([:positive])}",
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
    {:ok, view, _html} = live(conn, ~p"/dashboard/services")

    # Open the supervisor form
    view
    |> element("button[phx-click='toggle_supervisor_form'][phx-value-service-id='#{service.id}']")
    |> render_click()

    # Search for the user
    view
    |> element("input[name='supervisor_query']")
    |> render_keyup(%{"value" => user.email})

    # Click the user result
    view
    |> element("button[phx-click='add_supervisor'][phx-value-service-id='#{service.id}'][phx-value-user-id='#{user.id}']")
    |> render_click()

    # Verify the supervisor was added
    supervisors = Accounts.service_supervisors(service.id)
    assert length(supervisors) == 1
    assert hd(supervisors).user_id == user.id
  end
end
