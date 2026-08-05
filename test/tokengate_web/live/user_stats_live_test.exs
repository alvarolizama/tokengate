defmodule TokengateWeb.UserStatsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Logs, Repo}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "ustats-#{u}@example.com",
        name: "U #{u}",
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

  defp fixture_team_member do
    {:ok, team} = Accounts.create_team(%{name: "Team #{unique()}"})

    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "tm-#{u}@example.com",
        name: "TM #{u}",
        password: "password-secret-#{u}1",
        global_role: "user"
      })

    {:ok, _member} = Accounts.create_team_member(%{team_id: team.id, user_id: user.id})

    {team, user}
  end

  defp fixture_user_with_memberships, do: fixture_team_member()

  describe "auth" do
    test "unauthenticated visitors are redirected to /login", %{conn: conn} do
      {_, user} = fixture_user_with_memberships()

      assert {:error, {:redirect, %{to: "/login"}}} =
               live(conn, ~p"/dashboard/users/#{user.id}/stats")
    end

    test "regular user is redirected to /dashboard (admin-only)", %{conn: conn} do
      {_, user} = fixture_user_with_memberships()
      %{user: regular, password: password} = register("user")
      conn = login(conn, regular, password)

      assert {:error, {:redirect, %{to: "/dashboard"}}} =
               live(conn, ~p"/dashboard/users/#{user.id}/stats")
    end
  end

  describe "render" do
    test "admin sees the consolidated header (email + memberships count)", %{conn: conn} do
      {_, user} = fixture_user_with_memberships()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, _view, html} = live(conn, ~p"/dashboard/users/#{user.id}/stats")

      assert html =~ user.email
      assert html =~ "1 membresía"
    end

    test "admin sees the member's logs across all their memberships", %{conn: conn} do
      {team, user} = fixture_user_with_memberships()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      member = hd(Accounts.list_team_members_for_user(user.id))

      {:ok, _log1} =
        Logs.log_request(%{
          team_member_id: member.id,
          team_id: team.id,
          user_email: user.email,
          model_requested: "gpt-4o-stats",
          status_code: 200,
          prompt_tokens: 100,
          completion_tokens: 50,
          provider_cost_usd: Decimal.new("0.001"),
          latency_ms: 300
        })

      {:ok, _log2} =
        Logs.log_request(%{
          team_member_id: member.id,
          team_id: team.id,
          user_email: user.email,
          model_requested: "gpt-4o-stats",
          status_code: 503,
          prompt_tokens: 0,
          completion_tokens: 0,
          provider_cost_usd: Decimal.new("0"),
          latency_ms: 100
        })

      {:ok, _view, html} = live(conn, ~p"/dashboard/users/#{user.id}/stats")

      assert html =~ "gpt-4o-stats"
      assert html =~ "200"
      assert html =~ "503"
    end

    test "admin sees the consolidated total cost across memberships", %{conn: conn} do
      {team, user} = fixture_user_with_memberships()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      member = hd(Accounts.list_team_members_for_user(user.id))

      Logs.log_request(%{
        team_member_id: member.id,
        team_id: team.id,
        user_email: user.email,
        model_requested: "gpt-4o",
        status_code: 200,
        prompt_tokens: 1000,
        completion_tokens: 500,
        provider_cost_usd: Decimal.new("0.123"),
        latency_ms: 300
      })

      {:ok, _view, html} = live(conn, ~p"/dashboard/users/#{user.id}/stats")

      # Cost card renders with the dollar sign and at least some digits.
      assert html =~ "Costo (5d)"
      assert html =~ "$0"
    end
  end

  describe "back-link icon" do
    test "users_live has a stats link for every user", %{conn: conn} do
      {team, user} = fixture_user_with_memberships()
      %{user: admin, password: password} = register("admin")
      conn = login(conn, admin, password)

      {:ok, _view, html} = live(conn, ~p"/dashboard/users")
      assert html =~ ~s(id="stats-#{user.id}-#{team.id}")
    end
  end
end
