defmodule TokengateWeb.AlertsLiveTest do
  @moduledoc """
  LiveView tests for the admin alerts page, focused on the
  "Miembros sin crédito" budget section.

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
        email: "alerts-#{u}@example.com",
        name: "Alerts #{u}",
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

  defp broke_member_fixture(attrs \\ %{}) do
    %{user: member_user} = register("user")

    {:ok, team} =
      Accounts.create_team(
        Map.merge(
          %{
            "name" => "Alerts Team #{unique()}",
            "monthly_budget_per_user_usd" => "100.00"
          },
          attrs
        )
      )

    {:ok, member} =
      Accounts.create_team_member(%{"user_id" => member_user.id, "team_id" => team.id})

    {member, member_user, team}
  end

  setup do
    pid = Process.whereis(Manager) || start_supervised!(Manager)
    _ = :sys.get_state(pid)
    :ok
  end

  test "exhausted member appears in the budget section with period badge", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    {member, member_user, team} = broke_member_fixture()

    # $150 > $100 daily.
    assert :ok = Manager.record_spend(member.id, Decimal.new("150.00"))

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/alerts")

    assert has_element?(view, "#alert-budget-#{member.id}", member_user.email)
    assert has_element?(view, "#alert-budget-#{member.id}", team.name)
    assert has_element?(view, "#alert-budget-#{member.id}", "mensual")
    assert has_element?(view, "#alert-budget-credits-#{member.id}")
  end

  test "summary card counts members without credit", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {member, _member_user, _team} = broke_member_fixture()

    assert :ok = Manager.record_spend(member.id, Decimal.new("100.00"))

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/alerts")

    assert has_element?(view, "#alert-count-budgets", "1")
  end

  test "member under the limit does not appear in the budget section", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {member, _member_user, _team} = broke_member_fixture()

    assert :ok = Manager.record_spend(member.id, Decimal.new("10.00"))

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/alerts")

    refute has_element?(view, "#alert-budget-#{member.id}")
  end
end
