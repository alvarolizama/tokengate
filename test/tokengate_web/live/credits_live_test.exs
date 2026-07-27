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
        default_daily_budget_usd: "100.00",
        default_monthly_budget_usd: "500.00"
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
    for {member, savings} <- [{member_a, "0.40"}, {member_b, "0.20"}] do
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
          cost_usd: "0.60",
          provider_cost_usd: "0.60",
          savings_usd: savings,
          estimated_cost_usd: "1.00",
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

  test "admin sees team rollup with monthly cap, real spend and savings", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{team: team, member_a: member_a} = team_with_spend_and_savings()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/credits")

    assert has_element?(view, "#team-budgets")
    assert has_element?(view, "#team-budget-#{team.id}")

    row = view |> element("#team-budget-#{team.id}") |> render()
    # Tope = 500 × 2 miembros = 1000
    assert row =~ "1000"
    # Gasto real = 100 + 50 = 150
    assert row =~ "150"
    # Ahorro del mes = 0.40 + 0.20 = 0.60
    assert row =~ "0.6"

    # Columna Ahorro en la tabla de miembros
    assert has_element?(view, "#member-savings-#{member_a.id}")
  end
end
