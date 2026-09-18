defmodule TokengateWeb.AuditLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Auditing}

  defp register(role) do
    u = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "audit-live-#{u}@example.com",
        name: "User #{u}",
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

  test "admin sees recorded audit entries", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    {:ok, _} =
      Auditing.log(admin, "model.create", "model", "m-1", %{"name" => "gpt-x"}, %{
        ip: "10.0.0.1"
      })

    conn = login(conn, admin, password)

    {:ok, _view, html} = live(conn, ~p"/operations/audit")

    assert html =~ "Auditoría"
    assert html =~ "model.create"
    assert html =~ admin.email
  end

  test "filtering by action narrows the table", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    {:ok, _} = Auditing.log(admin, "model.create", "model", "m-1", %{}, %{})
    {:ok, _} = Auditing.log(admin, "topup.create", "topup", "t-1", %{}, %{})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/audit")

    html =
      view
      |> form("#audit-filters", %{"f" => %{"action" => "topup.create"}})
      |> render_change()

    assert html =~ "topup.create"
    refute html =~ "model.create"
  end

  test "non-admin is redirected to the dashboard", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/operations/audit")
  end

  test "CSV export returns an attachment", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, _} = Auditing.log(admin, "model.create", "model", "m-1", %{}, %{})

    conn =
      conn
      |> login(admin, password)
      |> get("/operations/audit/export?action=model.create")

    assert response(conn, 200) =~ "model.create"
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/csv"
  end
end
