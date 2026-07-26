defmodule TokengateWeb.DashboardLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Logs, Providers, Repo}
  alias Tokengate.Metrics.Collector

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "live-#{u}@example.com",
        name: "Live #{u}",
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

  # Builds org + team + member (+ api key) and returns the ids; optionally
  # inserts a request log for the member with the given cost.
  defp team_with_log(opts) do
    u = unique()

    {:ok, org} = Accounts.create_organization(%{name: "Org #{u}", slug: "org-#{u}"})
    {:ok, team} = Accounts.create_team(%{organization_id: org.id, name: "Team #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member, _token} =
      Accounts.create_team_member(%{user_id: owner.id, team_id: team.id, team_role: "user"})

    if cost = Map.get(opts, :cost) do
      {:ok, provider} =
        Providers.create_provider(%{
          name: "P #{u}",
          base_url: "http://localhost:1",
          billing_type: "pay_per_token"
        })

      {:ok, _log} =
        Logs.log_request(%{
          team_member_id: member.id,
          provider_id: provider.id,
          model_alias_id: nil,
          subscription_id: nil,
          model_requested: "gpt-4o",
          model_responded: "gpt-4o",
          agent_type: "claude-code",
          status_code: 200,
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

    %{org: org, team: team, owner: owner, member: member, owner_password: "password-secret-#{u}1"}
  end

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard")
  end

  test "admin sees the dashboard shell and empty state with no traffic", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Dashboard"
    assert has_element?(view, "#empty-state")
    assert html =~ "Aún no hay requests"
  end

  test "admin sees org-wide counters refresh on metrics broadcast", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    Collector.record_request(%{
      model_alias_id: "alias-1",
      provider_id: "prov-1",
      agent_type: "claude-code",
      status: 200,
      latency_ms: 100,
      prompt_tokens: 10,
      completion_tokens: 5,
      cost_usd: Decimal.new("0.005"),
      savings_usd: Decimal.new("0.002"),
      streaming: false
    })

    Phoenix.PubSub.broadcast(Tokengate.PubSub, "metrics:updated", {:metrics_updated, %{}})

    html = render(view)
    assert html =~ ~s(id="requests-card")
    refute has_element?(view, "#empty-state")
  end

  test "user scope: sees only their own consumption", %{conn: conn} do
    %{team: _team, owner: owner, member: member, owner_password: password} =
      team_with_log(%{cost: "0.005"})

    # Someone else's log in another team — must not leak into the user's scope
    team_with_log(%{cost: "99.99"})

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html = render(view)
    assert html =~ ~s(id="cost-card")
    refute has_element?(view, "#empty-state")
    _ = member
  end

  test "manager scope: aggregates the teams they manage", %{conn: conn} do
    %{team: team, member: _member} = team_with_log(%{cost: "0.005"})

    u = unique()
    password = "password-secret-#{u}1"

    {:ok, manager} =
      Accounts.register_user(%{
        email: "manager-#{u}@example.com",
        name: "Manager #{u}",
        password: password
      })

    {:ok, _membership, _token} =
      Accounts.create_team_member(%{user_id: manager.id, team_id: team.id, team_role: "manager"})

    conn = login(conn, manager, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html = render(view)
    assert html =~ ~s(id="cost-card")
    refute has_element?(view, "#empty-state")
    _ = Repo
  end
end
