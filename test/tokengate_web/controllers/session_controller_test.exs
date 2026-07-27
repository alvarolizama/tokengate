defmodule TokengateWeb.SessionControllerTest do
  use TokengateWeb.ConnCase, async: false

  alias Tokengate.Accounts

  defp user_fixture(attrs \\ %{}) do
    u = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "dash-#{u}@example.com",
        name: "Dash #{u}",
        password: "password-secret-#{u}1"
      })

    Map.merge(%{user: user, password: "password-secret-#{u}1"}, attrs)
  end

  test "GET /login renders the form", %{conn: conn} do
    conn = get(conn, ~p"/login")
    html = html_response(conn, 200)
    assert html =~ ~s(id="login-form")
    assert html =~ "Iniciar sesión"
  end

  test "POST /login with valid credentials sets session and redirects", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    conn = post(conn, ~p"/login", %{email: user.email, password: password})

    assert redirected_to(conn) == "/dashboard"
    assert get_session(conn, :user_id) == user.id
  end

  test "POST /login with bad password re-renders with Spanish error", %{conn: conn} do
    %{user: user} = user_fixture()

    conn = post(conn, ~p"/login", %{email: user.email, password: "wrong-password-1"})

    html = html_response(conn, 200)
    assert html =~ "Credenciales inválidas."
    assert get_session(conn, :user_id) == nil
  end

  test "POST /login with unknown email also fails safely", %{conn: conn} do
    conn = post(conn, ~p"/login", %{email: "nadie@example.com", password: "whatever-12345"})

    assert html_response(conn, 200) =~ "Credenciales inválidas."
  end

  test "GET /login redirects authenticated users to /dashboard", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    conn = post(conn, ~p"/login", %{email: user.email, password: password})
    conn = get(recycle(conn), ~p"/login")

    assert redirected_to(conn) == "/dashboard"
  end

  test "DELETE /logout clears the session", %{conn: conn} do
    %{user: user, password: password} = user_fixture()

    conn = post(conn, ~p"/login", %{email: user.email, password: password})
    conn = conn |> recycle() |> delete(~p"/logout")

    assert redirected_to(conn) == "/login"
    assert get_session(conn, :user_id) == nil
  end

  ## Impersonation ----------------------------------------------------------

  alias Tokengate.Auditing.AuditLog
  alias Tokengate.Repo

  defp login(conn, user, password) do
    post(conn, ~p"/login", %{email: user.email, password: password})
  end

  describe "POST /impersonate/:user_id" do
    test "admin can impersonate another user", %{conn: conn} do
      u = System.unique_integer([:positive])

      {:ok, admin} =
        Accounts.register_user(%{
          email: "imp-admin-#{u}@example.com",
          name: "Admin #{u}",
          password: "password-secret-#{u}1",
          global_role: "admin"
        })

      %{user: target} = user_fixture()

      conn = login(conn, admin, "password-secret-#{u}1")
      conn = conn |> recycle() |> post(~p"/impersonate/#{target.id}")

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :user_id) == target.id
      assert get_session(conn, :impersonator_id) == admin.id

      audit = Repo.get_by(AuditLog, action: "impersonate.start", entity_id: target.id)
      assert audit.user_id == admin.id
    end

    test "impersonated session shows the banner on the dashboard", %{conn: conn} do
      u = System.unique_integer([:positive])

      {:ok, admin} =
        Accounts.register_user(%{
          email: "imp-banner-#{u}@example.com",
          name: "Admin #{u}",
          password: "password-secret-#{u}1",
          global_role: "admin"
        })

      %{user: target} = user_fixture()

      conn = login(conn, admin, "password-secret-#{u}1")
      conn = conn |> recycle() |> post(~p"/impersonate/#{target.id}")
      conn = get(recycle(conn), ~p"/dashboard")

      html = html_response(conn, 200)
      assert html =~ ~s(id="impersonation-banner")
      assert html =~ target.email
      assert html =~ "Volver a mi cuenta"
    end

    test "non-admin cannot impersonate", %{conn: conn} do
      %{user: user, password: password} = user_fixture()
      %{user: target} = user_fixture()

      conn = login(conn, user, password)
      conn = conn |> recycle() |> post(~p"/impersonate/#{target.id}")

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :user_id) == user.id
      assert get_session(conn, :impersonator_id) == nil
      refute Repo.get_by(AuditLog, action: "impersonate.start", entity_id: target.id)
    end

    test "unauthenticated visitor is redirected to login", %{conn: conn} do
      %{user: target} = user_fixture()

      conn = post(conn, ~p"/impersonate/#{target.id}")

      assert redirected_to(conn) == "/login"
      assert get_session(conn, :user_id) == nil
    end

    test "admin cannot impersonate themselves", %{conn: conn} do
      u = System.unique_integer([:positive])

      {:ok, admin} =
        Accounts.register_user(%{
          email: "imp-self-#{u}@example.com",
          name: "Admin #{u}",
          password: "password-secret-#{u}1",
          global_role: "admin"
        })

      conn = login(conn, admin, "password-secret-#{u}1")
      conn = conn |> recycle() |> post(~p"/impersonate/#{admin.id}")

      assert redirected_to(conn) == "/dashboard/users"
      assert get_session(conn, :user_id) == admin.id
      assert get_session(conn, :impersonator_id) == nil
    end

    test "cannot nest impersonation while already impersonating", %{conn: conn} do
      u = System.unique_integer([:positive])

      {:ok, admin} =
        Accounts.register_user(%{
          email: "imp-nest-#{u}@example.com",
          name: "Admin #{u}",
          password: "password-secret-#{u}1",
          global_role: "admin"
        })

      %{user: target1} = user_fixture()
      %{user: target2} = user_fixture()

      conn = login(conn, admin, "password-secret-#{u}1")
      conn = conn |> recycle() |> post(~p"/impersonate/#{target1.id}")
      conn = conn |> recycle() |> post(~p"/impersonate/#{target2.id}")

      assert redirected_to(conn) == "/dashboard"
      # Session keeps pointing at the first target — no nesting happened
      assert get_session(conn, :user_id) == target1.id
      assert get_session(conn, :impersonator_id) == admin.id
    end

    test "unknown target user redirects with error", %{conn: conn} do
      u = System.unique_integer([:positive])

      {:ok, admin} =
        Accounts.register_user(%{
          email: "imp-404-#{u}@example.com",
          name: "Admin #{u}",
          password: "password-secret-#{u}1",
          global_role: "admin"
        })

      conn = login(conn, admin, "password-secret-#{u}1")
      conn = conn |> recycle() |> post(~p"/impersonate/#{Ecto.UUID.generate()}")

      assert redirected_to(conn) == "/dashboard/users"
      assert get_session(conn, :user_id) == admin.id
      assert get_session(conn, :impersonator_id) == nil
    end
  end

  describe "DELETE /impersonate" do
    test "restores the original admin session", %{conn: conn} do
      u = System.unique_integer([:positive])

      {:ok, admin} =
        Accounts.register_user(%{
          email: "imp-stop-#{u}@example.com",
          name: "Admin #{u}",
          password: "password-secret-#{u}1",
          global_role: "admin"
        })

      %{user: target} = user_fixture()

      conn = login(conn, admin, "password-secret-#{u}1")
      conn = conn |> recycle() |> post(~p"/impersonate/#{target.id}")
      conn = conn |> recycle() |> delete(~p"/impersonate")

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :user_id) == admin.id
      assert get_session(conn, :impersonator_id) == nil

      audit = Repo.get_by(AuditLog, action: "impersonate.stop", entity_id: target.id)
      assert audit.user_id == admin.id
    end

    test "no-op when not impersonating", %{conn: conn} do
      %{user: user, password: password} = user_fixture()

      conn = login(conn, user, password)
      conn = conn |> recycle() |> delete(~p"/impersonate")

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :user_id) == user.id
    end
  end
end
