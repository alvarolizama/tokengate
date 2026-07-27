defmodule TokengateWeb.LogsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Logs, Providers}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "logs-#{u}@example.com",
        name: "Logs #{u}",
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

  defp team_with_logs(opts \\ %{}) do
    u = unique()
    role = Map.get(opts, :team_role, "user")

    {:ok, team} = Accounts.create_team(%{name: "Team #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} =
      Accounts.create_team_member(%{user_id: owner.id, team_id: team.id, team_role: role})

    {:ok, provider} =
      Providers.create_provider(%{
        name: "P #{u}",
        base_url: "http://localhost:1"
      })

    for {status, agent, cost} <- Map.get(opts, :logs, [{200, "claude-code", "0.005"}]) do
      {:ok, _log} =
        Logs.log_request(%{
          team_member_id: member.id,
          provider_id: provider.id,
          model_alias_id: nil,
          model_requested: "gpt-4o",
          model_responded: "gpt-4o",
          agent_type: agent,
          status_code: status,
          prompt_tokens: 100,
          completion_tokens: 50,
          cost_usd: cost,
          provider_cost_usd: cost,
          savings_usd: "0.001",
          estimated_cost_usd: "0.01",
          latency_ms: 42,
          streaming: false
        })
    end

    %{
      team: team,
      owner: owner,
      member: member,
      provider: provider,
      owner_password: "password-secret-#{u}1"
    }
  end

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/logs")
  end

  test "admin sees logs from all teams with the summary strip", %{conn: conn} do
    team_with_logs()
    team_with_logs()

    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/logs")

    assert html =~ "Logs"
    assert has_element?(view, "#summary-requests")
    assert has_element?(view, "#summary-cost")
    assert has_element?(view, "#summary-savings")
    # Both teams' logs visible
    assert html =~ "gpt-4o"
    assert html =~ "claude-code"
  end

  test "user scope: sees only their own logs", %{conn: conn} do
    %{owner: owner, owner_password: password} = team_with_logs()
    # Another team's logs — must not leak
    team_with_logs(%{logs: [{200, "other-agent", "99.99"}]})

    conn = login(conn, owner, password)
    {:ok, _view, html} = live(conn, ~p"/dashboard/logs")

    assert html =~ "claude-code"
    refute html =~ "other-agent"
  end

  test "manager scope: sees the logs of the teams they manage", %{conn: conn} do
    %{team: team} = team_with_logs()
    team_with_logs(%{logs: [{200, "other-agent", "99.99"}]})

    u = unique()
    password = "password-secret-#{u}1"

    {:ok, manager} =
      Accounts.register_user(%{
        email: "manager-#{u}@example.com",
        name: "Manager #{u}",
        password: password
      })

    {:ok, _membership} =
      Accounts.create_team_member(%{user_id: manager.id, team_id: team.id, team_role: "manager"})

    conn = login(conn, manager, password)
    {:ok, _view, html} = live(conn, ~p"/dashboard/logs")

    assert html =~ "claude-code"
    refute html =~ "other-agent"
  end

  test "cost breakdown columns are rendered", %{conn: conn} do
    %{owner: owner, owner_password: password} = team_with_logs()

    conn = login(conn, owner, password)
    {:ok, _view, html} = live(conn, ~p"/dashboard/logs")

    for header <- ["Estimado", "Costo", "Proveedor", "Ahorro"] do
      assert html =~ header
    end

    assert html =~ "0.01"
    assert html =~ "0.005"
    assert html =~ "0.001"
  end

  test "filter by status_class shows only matching logs", %{conn: conn} do
    %{owner: owner, owner_password: password} =
      team_with_logs(%{logs: [{200, "claude-code", "0.005"}, {500, "codex", "0.007"}]})

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/logs")

    html =
      view
      |> form("#logs-filter-form", filter: %{status_class: "5xx"})
      |> render_change()

    assert html =~ "codex"
    refute html =~ "claude-code"
  end

  test "filter by agent_type shows only matching logs", %{conn: conn} do
    %{owner: owner, owner_password: password} =
      team_with_logs(%{logs: [{200, "claude-code", "0.005"}, {200, "cursor", "0.007"}]})

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/logs")

    html =
      view
      |> form("#logs-filter-form", filter: %{agent_type: "cursor"})
      |> render_change()

    assert html =~ "cursor"
    refute html =~ "claude-code"
  end
end
