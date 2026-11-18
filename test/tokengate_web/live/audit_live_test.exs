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

    {:ok, log} =
      Auditing.log(admin, "model.create", "model", "m-1", %{"name" => "gpt-x"}, %{
        ip: "10.0.0.1"
      })

    conn = login(conn, admin, password)

    {:ok, view, html} = live(conn, ~p"/operations/audit")

    # Default UI language is English: the msgid is rendered as-is.
    assert html =~ "Audit"
    assert html =~ "Who did what, to what, and when"
    refute html =~ "Auditoría"
    assert html =~ "model.create"
    assert html =~ admin.email

    # The .table contract: tbody carries the id and each row keeps its dom id.
    assert has_element?(view, "tbody#audit-rows")
    assert has_element?(view, "tr#audit-#{log.id}")

    # And the Spanish catalog still renders the same screen in Spanish.
    {:ok, _admin} = Accounts.update_user_locale(admin, "es")
    {:ok, _view_es, html_es} = live(recycle(conn), ~p"/operations/audit")

    assert html_es =~ "Auditoría"
    assert html_es =~ "Quién hizo qué"
    refute html_es =~ "Who did what"
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

    # No match → the .table empty-state slot renders instead of a colspan row.
    view
    |> form("#audit-filters", %{"f" => %{"action" => "does.not.exist"}})
    |> render_change()

    assert has_element?(view, "#audit-rows-empty", "No events for the selected filters.")
    refute has_element?(view, "#audit-rows")
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
