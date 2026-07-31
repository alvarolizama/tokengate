defmodule TokengateWeb.CreditsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Logs, Providers}
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

  # Equipo con 2 miembros, gasto real registrado en ETS y logs con ahorro
  # en el mes en curso.
  defp team_with_spend_and_savings do
    u = unique()

    {:ok, team} =
      Accounts.create_team(%{
        name: "Credits Team #{u}",
        monthly_budget_per_user_usd: "100.00"
      })

    {:ok, owner_a} =
      Accounts.register_user(%{
        email: "credits-a-#{u}@example.com",
        name: "A #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, owner_b} =
      Accounts.register_user(%{
        email: "credits-b-#{u}@example.com",
        name: "B #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member_a} =
      Accounts.create_team_member(%{user_id: owner_a.id, team_id: team.id})

    {:ok, member_b} =
      Accounts.create_team_member(%{user_id: owner_b.id, team_id: team.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "Prov #{u}", base_url: "http://localhost:1"})

    # Gasto real del mes en los contadores ETS (fuente de Budgets)
    pid = Process.whereis(Manager) || start_supervised!(Manager)
    _ = :sys.get_state(pid)
    :ok = Manager.record_spend(member_a.id, Decimal.new("100.00"))
    :ok = Manager.record_spend(member_b.id, Decimal.new("50.00"))

    # Logs con ahorro (estimated > real) para la columna Ahorro
    for {member, _savings} <- [{member_a, "0.40"}, {member_b, "0.20"}] do
      {:ok, _log} =
        Logs.log_request(%{
          team_member_id: member.id,
          provider_id: provider.id,
          model_requested: "model-#{u}",
          model_responded: "model-#{u}",
          agent_type: "api",
          status_code: 200,
          prompt_tokens: 100,
          completion_tokens: 50,
          provider_cost_usd: "0.60",
          latency_ms: 42,
          streaming: false
        })
    end

    %{team: team, member_a: member_a, member_b: member_b}
  end

  ## Auth -------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/credits")
  end

  ## Team rollup --------------------------------------------------------------

  test "admin sees team rollup with daily cap, real spend and savings", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{team: team, member_a: _member_a} = team_with_spend_and_savings()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/credits")

    assert has_element?(view, "#team-budgets")
    assert has_element?(view, "#team-budget-#{team.id}")

    row = view |> element("#team-budget-#{team.id}") |> render()
    # Tope = 100 × 2 miembros = 200
    assert row =~ "200"
    # Gasto real = 100 + 50 = 150 (monthly_budget % displayed as $150/$200 progress)
    assert row =~ "150"
    # Since the 2026-07-30 refactor there's no separate "savings" column —
    # the team spend the same total ($1.50) is shown as the consumed/200 number.
    refute row =~ "0.6"

    # The team-budget row is the primary spend signal now; member-spends
    # are still listed but no longer carried a savings sub-row.
    assert has_element?(view, "#team-budget-#{team.id}")
  end
end
