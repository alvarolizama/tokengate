defmodule TokengateWeb.MonitorLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.Accounts
  alias Tokengate.Logs.Inflight

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Tokengate.Accounts.register_user(%{
        email: "monitor-#{u}@example.com",
        name: "Monitor #{u}",
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

  test "admin sees monitor page", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/monitor")

    assert has_element?(view, "#monitor-chart") || html =~ "Sin actividad"
    assert html =~ "Monitor en vivo"
  end

  test "regular user is redirected from monitor", %{conn: conn} do
    %{user: owner} = register("user")

    {:ok, team} =
      Tokengate.Accounts.create_team(%{"name" => "Team #{unique()}"})

    {:ok, _member} =
      Tokengate.Accounts.create_team_member(%{"user_id" => owner.id, "team_id" => team.id})

    conn = login(conn, owner, owner.password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/monitor")
  end

  test "shows in-flight count badge", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    # Register a fake in-flight request
    Inflight.start_request(%{
      model_requested: "gpt-4",
      provider_name: "OpenRouter",
      credential_name: "key-1"
    })

    {:ok, _view, html} = live(conn, ~p"/dashboard/monitor")

    # The total in-flight badge should show at least 1
    assert html =~ "en vuelo"

    # Clean up
    Inflight.list() |> Enum.each(fn e -> Inflight.finish_request(e.id) end)
  end

  ## Alert sections moved from /dashboard/logs -----------------------------------

  defp broke_member_fixture(attrs \\ %{}) do
    %{user: member_user} = register("user")

    {:ok, team} =
      Accounts.create_team(
        Map.merge(
          %{
            "name" => "Budget Team #{unique()}",
            "monthly_budget_per_user_usd" => "100.00"
          },
          attrs
        )
      )

    {:ok, member} =
      Accounts.create_team_member(%{"user_id" => member_user.id, "team_id" => team.id})

    {member, member_user, team}
  end

  defp log_spend(member_id, cost) do
    {:ok, _} =
      Tokengate.Logs.log_request(%{
        team_member_id: member_id,
        model_requested: "gpt-4",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        provider_cost_usd: Decimal.new(cost)
      })
  end

  test "exhausted member appears in the budget section with period badge", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    {member, member_user, team} = broke_member_fixture()

    # $150 > $100 monthly.
    log_spend(member.id, "150.00")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/monitor")

    assert has_element?(view, "#alert-budget-#{member.id}", member_user.email)
    assert has_element?(view, "#alert-budget-#{member.id}", team.name)
    assert has_element?(view, "#alert-budget-#{member.id}", "mensual")
    assert has_element?(view, "#alert-budget-credits-#{member.id}")
  end

  test "summary card counts members without credit", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {member, _member_user, _team} = broke_member_fixture()

    log_spend(member.id, "100.00")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/monitor")

    assert has_element?(view, "#alert-count-budgets", "1")
  end

  test "member under the limit does not appear in the budget section", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {member, _member_user, _team} = broke_member_fixture()

    log_spend(member.id, "10.00")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/monitor")

    refute has_element?(view, "#alert-budget-#{member.id}")
  end
end
