defmodule TokengateWeb.StatsExportControllerTest do
  @moduledoc """
  CSV export endpoint tests — focusing on authorization: the team drill-down
  exposes member-level data (emails, costs), so only admins may export it.
  """

  use TokengateWeb.ConnCase, async: false

  alias Tokengate.{Accounts, Logs, Providers}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "export-#{u}@example.com",
        name: "Export #{u}",
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

  # Team with one member (owner) and one request log.
  defp team_with_log do
    u = unique()

    {:ok, team} = Accounts.create_team(%{name: "Team #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} =
      Accounts.create_team_member(%{user_id: owner.id, team_id: team.id, team_role: "user"})

    {:ok, provider} =
      Providers.create_provider(%{name: "P #{u}", base_url: "http://localhost:1"})

    {:ok, _log} =
      Logs.log_request(%{
        team_member_id: member.id,
        provider_id: provider.id,
        model_alias_id: nil,
        model_requested: "gpt-4o",
        model_responded: "gpt-4o",
        agent_type: "claude-code",
        status_code: 200,
        prompt_tokens: 100,
        completion_tokens: 50,
        cost_usd: "0.005",
        provider_cost_usd: "0.005",
        savings_usd: "0.001",
        estimated_cost_usd: "0.01",
        latency_ms: 42,
        streaming: false
      })

    %{team: team, owner: owner, member: member, owner_password: "password-secret-#{u}1"}
  end

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    conn = get(conn, ~p"/dashboard/stats/export?type=teams")
    assert redirected_to(conn) =~ "/login"
  end

  test "admin can export a team drill-down", %{conn: conn} do
    %{team: team} = team_with_log()
    %{user: admin, password: password} = register("admin")

    conn =
      conn
      |> login(admin, password)
      |> get(~p"/dashboard/stats/export?type=teams&team_id=#{team.id}")

    assert response(conn, 200) =~ "usuario,equipo"
  end

  test "plain member of the team cannot export its drill-down", %{conn: conn} do
    %{team: team, owner: owner, owner_password: password} = team_with_log()

    conn =
      conn
      |> login(owner, password)
      |> get(~p"/dashboard/stats/export?type=teams&team_id=#{team.id}")

    assert json_response(conn, 403) == %{"error" => "no autorizado"}
  end

  test "non-member user gets 403 on another team's drill-down", %{conn: conn} do
    %{team: team} = team_with_log()
    %{user: outsider, password: password} = register("user")

    conn =
      conn
      |> login(outsider, password)
      |> get(~p"/dashboard/stats/export?type=teams&team_id=#{team.id}")

    assert json_response(conn, 403) == %{"error" => "no autorizado"}
  end

  test "models export works for any authenticated user", %{conn: conn} do
    team_with_log()
    %{user: user, password: password} = register("user")

    conn =
      conn
      |> login(user, password)
      |> get(~p"/dashboard/stats/export?type=models")

    assert response(conn, 200) =~ "modelo,requests"
  end
end
