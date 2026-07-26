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
end
