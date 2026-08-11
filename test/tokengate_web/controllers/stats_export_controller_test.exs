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
        provider_cost_usd: "0.005",
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

  test "logs export neutralizes CSV formula injection in client_agent", %{conn: conn} do
    u = unique()

    {:ok, team} = Accounts.create_team(%{name: "Team #{u}"})
    %{user: user, password: password} = register("user")

    {:ok, member} =
      Accounts.create_team_member(%{user_id: user.id, team_id: team.id, team_role: "user"})

    {:ok, provider} =
      Providers.create_provider(%{name: "P #{u}", base_url: "http://localhost:1"})

    # Attacker-controlled value (arrives via the X-Title request header on
    # real proxy traffic) that Excel would execute as a formula.
    {:ok, _log} =
      Logs.log_request(%{
        team_member_id: member.id,
        provider_id: provider.id,
        model_alias_id: nil,
        model_requested: "gpt-4o",
        agent_type: "curl",
        client_agent: "=cmd|'/c calc'!A1",
        status_code: 200,
        prompt_tokens: 1,
        completion_tokens: 1,
        provider_cost_usd: "0",
        latency_ms: 1,
        streaming: false
      })

    conn =
      conn
      |> login(user, password)
      |> get(~p"/dashboard/stats/export?type=logs")

    body = response(conn, 200)
    # Prefixed with a single quote — renders as text, never as a formula.
    assert body =~ "'=cmd|'/c calc'!A1"
  end

  describe "logs export period coverage" do
    # The UI list is capped at 500 rows; exports must NOT be, otherwise a
    # busy day alone would eat the whole CSV and 30d/90d exports would only
    # contain today's data.
    test "30d export includes logs older than the 500-row UI cap", %{conn: conn} do
      u = unique()
      {:ok, team} = Accounts.create_team(%{name: "Team #{u}"})
      %{user: user, password: password} = register("user")

      {:ok, member} =
        Accounts.create_team_member(%{user_id: user.id, team_id: team.id, team_role: "user"})

      # 510 rows from 10 days ago — more than the old list_logs/1 cap of 500,
      # so the buggy export (ordered newest-first, capped at 500) would never
      # reach them when today has traffic.
      ten_days_ago =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      old_rows =
        for i <- 1..510 do
          %{
            id: Ecto.UUID.generate(),
            inserted_at: DateTime.add(ten_days_ago, i, :second),
            team_member_id: member.id,
            model_requested: "gpt-4o",
            agent_type: "api",
            status_code: 200,
            prompt_tokens: 10,
            completion_tokens: 5,
            latency_ms: 20,
            streaming: false,
            think: false
          }
        end

      {510, _} = Tokengate.Repo.insert_all(Tokengate.Logs.RequestLog, old_rows)

      # One row from today — newest-first ordering puts it at the top of the
      # buggy 500-row window.
      {:ok, _log} =
        Logs.log_request(%{
          team_member_id: member.id,
          model_requested: "gpt-4o",
          agent_type: "api",
          status_code: 200,
          prompt_tokens: 10,
          completion_tokens: 5,
          latency_ms: 20,
          streaming: false
        })

      conn =
        conn
        |> login(user, password)
        |> get(~p"/dashboard/stats/export?type=logs&period=30d")

      body = response(conn, 200)
      data_rows = body |> String.split("\n") |> Enum.drop(1) |> Enum.reject(&(&1 == ""))
      assert length(data_rows) == 511
    end

    test "logs export defaults to 7d and respects today/week/month periods", %{conn: conn} do
      %{owner: owner, owner_password: password} = team_with_log()
      %{user: _user, password: _pw} = register("user")

      conn =
        conn
        |> login(owner, password)
        |> get(~p"/dashboard/stats/export?type=logs&period=today")

      body = response(conn, 200)
      assert body =~ "fecha,estado"
      assert body =~ "gpt-4o"
    end

    test "errors export only includes status >= 400 across the period", %{conn: conn} do
      %{owner: owner, owner_password: password, member: member} = team_with_log()

      for status <- [400, 429, 500, 502] do
        {:ok, _} =
          Logs.log_request(%{
            team_member_id: member.id,
            model_requested: "gpt-4o",
            agent_type: "api",
            status_code: status,
            error_reason: "test_error",
            prompt_tokens: 1,
            completion_tokens: 1,
            latency_ms: 5,
            streaming: false
          })
      end

      conn =
        conn
        |> login(owner, password)
        |> get(~p"/dashboard/stats/export?type=errors&period=30d")

      body = response(conn, 200)
      assert body =~ "test_error"

      # 200-row from team_with_log() must NOT appear in the errors export
      lines = body |> String.split("\n") |> Enum.drop(1) |> Enum.reject(&(&1 == ""))
      assert length(lines) == 4
    end
  end
end
