defmodule TokengateWeb.CreditsLiveTest do
  @moduledoc """
  LiveView tests for the admin credits overview (/dashboard/credits).

  `async: false` because the budget ETS table is a named singleton.
  """
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.Accounts
  alias Tokengate.Budgets.Manager

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "credits-#{u}@example.com",
        name: "Credits #{u}",
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

  defp team_fixture(attrs \\ %{}) do
    {:ok, team} =
      Accounts.create_team(
        Map.merge(
          %{
            "name" => "Credits Team #{unique()}",
            "default_daily_budget_usd" => "100.00",
            "default_monthly_budget_usd" => "1000.00"
          },
          attrs
        )
      )

    team
  end

  defp member_fixture(team, user) do
    {:ok, member} =
      Accounts.create_team_member(%{"user_id" => user.id, "team_id" => team.id})

    member
  end

  setup do
    pid = Process.whereis(Manager) || start_supervised!(Manager)
    _ = :sys.get_state(pid)
    :ok
  end

  ## Auth -------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/credits")
  end

  test "regular user is redirected to /dashboard (admin-only)", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/credits")
  end

  ## Admin views --------------------------------------------------------------

  test "admin sees the credits table with summary cards", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: member_user} = register("user")
    team = team_fixture()
    member = member_fixture(team, member_user)

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/credits")

    assert html =~ "Créditos"
    assert has_element?(view, "#credit-row-#{member.id}")
    assert has_element?(view, "#credits-count-total")
    assert has_element?(view, "#credits-count-near")
    assert has_element?(view, "#credits-count-exhausted")
    assert has_element?(view, "#refresh-credits")
  end

  test "member rows show spend, limits and status", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: member_user} = register("user")
    team = team_fixture()
    member = member_fixture(team, member_user)

    assert :ok = Manager.record_spend(member.id, Decimal.new("25.00"))

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/credits")

    assert has_element?(view, "#credit-row-#{member.id}", member_user.email)
    assert has_element?(view, "#credit-row-#{member.id}", team.name)
    assert has_element?(view, "#credit-row-#{member.id}", "$25")
    assert has_element?(view, "#credit-row-#{member.id}", "OK")
  end

  test "exhausted member shows Agotado badge and is counted", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: member_user} = register("user")
    team = team_fixture()
    member = member_fixture(team, member_user)

    assert :ok = Manager.record_spend(member.id, Decimal.new("100.00"))

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/credits")

    assert has_element?(view, "#credit-row-#{member.id}", "Agotado")
    assert has_element?(view, "#credits-count-exhausted", "1")
  end

  test "member without limits shows Sin límite", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: member_user} = register("user")
    team = team_fixture(%{"default_daily_budget_usd" => nil, "default_monthly_budget_usd" => nil})
    member = member_fixture(team, member_user)

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/credits")

    assert has_element?(view, "#credit-row-#{member.id}", "Sin límite")
  end

  test "refresh event reloads the budget list", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: member_user} = register("user")
    team = team_fixture()
    member = member_fixture(team, member_user)

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/credits")

    assert has_element?(view, "#credit-row-#{member.id}", "$0")

    assert :ok = Manager.record_spend(member.id, Decimal.new("42.50"))

    render_click(view, "refresh")
    assert has_element?(view, "#credit-row-#{member.id}", "$42.5")
  end
end
