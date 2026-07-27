defmodule TokengateWeb.UsersLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.Accounts

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "users-#{u}@example.com",
        name: "Users #{u}",
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

  ## Auth -------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/users")
  end

  test "regular user is redirected to /dashboard (admin-only)", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/users")
  end

  ## Admin views ------------------------------------------------------------

  test "admin sees users list with create button", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/users")

    assert html =~ "Usuarios"
    assert has_element?(view, "#new-user-btn")
  end

  test "admin sees existing users in the table", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    _other = register("user")
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    assert has_element?(view, "#users")
    assert has_element?(view, "#new-user-btn")
  end

  test "admin sees spend column with user budget rollup", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: member_user} = register("user")

    {:ok, team} =
      Accounts.create_team(%{
        "name" => "Spend Team #{unique()}",
        "default_daily_budget_usd" => "100.00",
        "default_monthly_budget_usd" => "1000.00"
      })

    {:ok, member} =
      Accounts.create_team_member(%{"user_id" => member_user.id, "team_id" => team.id})

    assert :ok = Tokengate.Budgets.Manager.record_spend(member.id, Decimal.new("7.25"))

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    assert has_element?(view, "#spend-#{member_user.id}", "$7.25")
    assert has_element?(view, "#spend-#{admin.id}", "—")
  end

  test "user without credit shows sin crédito badge", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: member_user} = register("user")

    {:ok, team} =
      Accounts.create_team(%{
        "name" => "Broke Team #{unique()}",
        "default_daily_budget_usd" => "100.00",
        "default_monthly_budget_usd" => "1000.00"
      })

    {:ok, member} =
      Accounts.create_team_member(%{"user_id" => member_user.id, "team_id" => team.id})

    assert :ok = Tokengate.Budgets.Manager.record_spend(member.id, Decimal.new("100.00"))

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    assert has_element?(view, "#spend-#{member_user.id}", "sin crédito")
  end

  ## Create user ------------------------------------------------------------

  test "admin can create a new user", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    view |> element("#new-user-btn") |> render_click()
    assert has_element?(view, "#user-form")

    html =
      view
      |> form("#user-form", %{
        user: %{
          email: "newuser@example.com",
          name: "New User",
          password: "valid-password-123",
          global_role: "user"
        }
      })
      |> render_submit()

    assert html =~ "Usuario creado correctamente"
  end

  test "admin cannot create user with weak password", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    view |> element("#new-user-btn") |> render_click()

    html =
      view
      |> form("#user-form", %{
        user: %{
          email: "weak@example.com",
          name: "Weak",
          password: "short",
          global_role: "user"
        }
      })
      |> render_submit()

    refute html =~ "Usuario creado"
  end

  ## Edit user --------------------------------------------------------------

  test "admin can edit a user's role", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    view |> element("#edit-#{target.id}") |> render_click()
    assert has_element?(view, "#user-edit-form")

    html =
      view
      |> form("#user-edit-form", %{
        user: %{name: target.name, global_role: "admin", status: "active"}
      })
      |> render_submit()

    assert html =~ "Usuario actualizado"

    updated = Accounts.get_user!(target.id)
    assert updated.global_role == "admin"
  end

  ## Suspend/activate -------------------------------------------------------

  test "admin can suspend a user", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    html = view |> element("#status-#{target.id}") |> render_click()
    assert html =~ "Usuario suspendido"

    updated = Accounts.get_user!(target.id)
    assert updated.status == "suspended"
  end

  test "suspended user cannot login with password", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target, password: target_password} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")
    view |> element("#status-#{target.id}") |> render_click()

    # Now try to login as the suspended user
    conn = build_conn()
    conn = post(conn, ~p"/login", %{email: target.email, password: target_password})
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "suspendida"
  end

  ## Reset password ---------------------------------------------------------

  test "admin can reset a user's password", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    view |> element("#pwd-#{target.id}") |> render_click()
    assert has_element?(view, "#user-reset-form")

    html =
      view
      |> form("#user-reset-form", %{user: %{password: "new-password-123"}})
      |> render_submit()

    assert html =~ "Contraseña actualizada"

    # Verify the new password works
    conn = build_conn()
    conn = post(conn, ~p"/login", %{email: target.email, password: "new-password-123"})
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Sesión iniciada"
  end

  ## Impersonate --------------------------------------------------------------

  test "admin sees impersonate link for other users but not for self", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    assert has_element?(view, "#impersonate-#{target.id}")
    refute has_element?(view, "#impersonate-#{admin.id}")
  end

  test "root admin cannot be impersonated", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")

    root = Accounts.get_user_by_email("admin@tokengate.local")
    assert root, "seeds should create the root admin"

    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    refute has_element?(view, "#impersonate-#{root.id}")
  end
end
