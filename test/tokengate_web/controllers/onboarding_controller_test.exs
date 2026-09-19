defmodule TokengateWeb.OnboardingControllerTest do
  @moduledoc """
  Primer arranque: con la instancia vacía, `/` y `/login` mandan a `/onboarding`
  y la primera cuenta que se crea ahí es el admin global. En cuanto existe un
  usuario, la pantalla se apaga: no se puede usar para fabricar un segundo admin.
  """

  use TokengateWeb.ConnCase, async: false

  alias Tokengate.Accounts
  alias Tokengate.Accounts.User
  alias Tokengate.Repo

  @password "onboarding-secret-1"

  defp params(email, attrs \\ %{}) do
    Map.merge(%{"name" => "Jefa", "email" => email, "password" => @password}, attrs)
  end

  # Un usuario cualquiera basta para que la instancia deje de estar "vacía".
  defp existing_user do
    {:ok, user} =
      Accounts.admin_create_user(%{
        email: "existente@example.com",
        name: "Existente",
        password: @password,
        global_role: "user",
        status: "active"
      })

    user
  end

  test "GET /onboarding renders the first-run form while no user exists", %{conn: conn} do
    html = conn |> get(~p"/onboarding") |> html_response(200)

    assert html =~ ~s(id="onboarding-form")
    assert html =~ ~s(id="onboarding-submit")
  end

  test "POST /onboarding creates the first user as a global admin and signs them in", %{
    conn: conn
  } do
    conn = post(conn, ~p"/onboarding", %{"user" => params("jefa@example.com")})

    assert redirected_to(conn) == "/dashboard"

    user = Repo.get_by(User, email: "jefa@example.com")
    assert user.global_role == "admin"
    assert user.status == "active"
    assert get_session(conn, :user_id) == user.id
  end

  test "POST /onboarding is refused once any user exists", %{conn: conn} do
    existing_user()

    conn = post(conn, ~p"/onboarding", %{"user" => params("intruso@example.com")})

    assert redirected_to(conn) == "/login"
    assert Repo.get_by(User, email: "intruso@example.com") == nil
    assert get_session(conn, :user_id) == nil
  end

  test "a second submit cannot mint a second admin", %{conn: conn} do
    post(conn, ~p"/onboarding", %{"user" => params("primera@example.com")})

    conn = post(conn, ~p"/onboarding", %{"user" => params("segunda@example.com")})

    assert redirected_to(conn) == "/login"
    assert Repo.get_by(User, email: "segunda@example.com") == nil
    assert Repo.aggregate(User, :count) == 1
  end

  test "GET /onboarding is gone once any user exists", %{conn: conn} do
    existing_user()

    conn = get(conn, ~p"/onboarding")

    assert redirected_to(conn) == "/login"
  end

  test "GET /login sends a fresh instance to /onboarding instead of a dead form", %{conn: conn} do
    conn = get(conn, ~p"/login")

    assert redirected_to(conn) == "/onboarding"
  end

  test "an invalid submission re-renders the form and creates nothing", %{conn: conn} do
    conn =
      post(conn, ~p"/onboarding", %{
        "user" => params("jefa@example.com", %{"password" => "corta"})
      })

    assert html_response(conn, 422) =~ ~s(id="onboarding-form")
    assert Repo.aggregate(User, :count) == 0
  end

  test "the created admin can actually log in afterwards", %{conn: conn} do
    post(conn, ~p"/onboarding", %{"user" => params("jefa@example.com")})

    conn = post(conn, ~p"/login", %{email: "jefa@example.com", password: @password})

    assert redirected_to(conn) == "/dashboard"
  end
end
