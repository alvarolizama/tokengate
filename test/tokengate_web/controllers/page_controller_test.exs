defmodule TokengateWeb.PageControllerTest do
  use TokengateWeb.ConnCase

  alias Tokengate.Accounts

  test "GET / redirects to /onboarding while the instance has no user at all", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/onboarding"
  end

  test "GET / redirects to /login when unauthenticated", %{conn: conn} do
    {:ok, _user} =
      Accounts.register_user(%{
        email: "home-test-#{System.unique_integer([:positive])}@example.com",
        name: "Home Test",
        password: "password-secret-1"
      })

    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/login"
  end

  test "GET / redirects to /dashboard when authenticated", %{conn: conn} do
    {:ok, user} =
      Tokengate.Accounts.register_user(%{
        email: "home-test-#{System.unique_integer([:positive])}@example.com",
        name: "Home Test",
        password: "password-secret-1"
      })

    conn =
      conn
      |> post(~p"/login", %{email: user.email, password: "password-secret-1"})
      |> recycle()
      |> get(~p"/")

    assert redirected_to(conn) == "/dashboard"
  end
end
