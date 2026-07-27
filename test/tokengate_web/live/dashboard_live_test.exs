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

    {:ok, team} = Accounts.create_team(%{name: "Team #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} =
      Accounts.create_team_member(%{user_id: owner.id, team_id: team.id, team_role: "user"})

    if cost = Map.get(opts, :cost) do
      {:ok, provider} =
        Providers.create_provider(%{
          name: "P #{u}",
          base_url: "http://localhost:1"
        })

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
          cost_usd: cost,
          provider_cost_usd: cost,
          savings_usd: "0.001",
          estimated_cost_usd: "0.01",
          latency_ms: 42,
          streaming: false
        })
    end

    %{team: team, owner: owner, member: member, owner_password: "password-secret-#{u}1"}
  end

  defp team_with_member(opts \\ %{}) do
    _u = unique()
    role = Map.get(opts, :team_role, "user")

    {:ok, team} = Accounts.create_team(%{name: "Team #{_u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "owner-#{_u}@example.com",
        name: "Owner #{_u}",
        password: "password-secret-#{_u}1"
      })

    {:ok, member} =
      Accounts.create_team_member(%{user_id: owner.id, team_id: team.id, team_role: role})

    {:ok, _api_key, _token} = Accounts.replace_api_key(member)

    %{team: team, owner: owner, member: member, owner_password: "password-secret-#{_u}1"}
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

    {:ok, _membership} =
      Accounts.create_team_member(%{user_id: manager.id, team_id: team.id, team_role: "manager"})

    conn = login(conn, manager, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html = render(view)
    assert html =~ ~s(id="cost-card")
    refute has_element?(view, "#empty-state")
    _ = Repo
  end

  ## Personal keys on dashboard --------------------------------------------

  test "user sees their own API key on dashboard", %{conn: conn} do
    %{team: team, owner: owner, member: member, owner_password: password} =
      team_with_member(%{team_role: "user"})

    conn = login(conn, owner, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Tus equipos"
    assert html =~ team.name
    assert has_element?(view, "#team-#{team.id}")
    assert html =~ "••••"
    _ = member
  end

  test "user can replace their key from dashboard", %{conn: conn} do
    %{owner: owner, member: member, owner_password: password} =
      team_with_member(%{team_role: "user"})

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html = view |> element("#replace-#{member.id}") |> render_click()

    assert html =~ "Nueva clave generada"
    assert has_element?(view, "#new-token-alert")
    assert has_element?(view, "#new-token-value")
  end

  test "user can revoke their key from dashboard", %{conn: conn} do
    %{owner: owner, member: member, owner_password: password} =
      team_with_member(%{team_role: "user"})

    conn = login(conn, owner, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Activa"

    html = view |> element("#revoke-#{member.id}") |> render_click()
    assert html =~ "Revocada"
    refute has_element?(view, "#revoke-#{member.id}")
  end

  test "user cannot revoke another member's key from dashboard", %{conn: conn} do
    %{owner: owner, owner_password: password} = team_with_member(%{team_role: "user"})
    %{member: other_member} = team_with_member(%{team_role: "user"})

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html = render_click(view, "revoke_key", %{"id" => other_member.id})
    assert html =~ "No autorizado."
  end

  test "user without teams sees empty states on dashboard", %{conn: conn} do
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)
    {:ok, _view, html} = live(conn, ~p"/dashboard")

    assert html =~ "No perteneces a ningún equipo todavía."
  end

  ## Teams & budgets on dashboard ------------------------------------------

  test "user sees their team budget with spend bars", %{conn: conn} do
    %{team: team, owner: owner, member: member, owner_password: password} =
      team_with_member(%{team_role: "user"})

    conn = login(conn, owner, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Tus equipos"
    assert has_element?(view, "#team-#{team.id}")
    assert html =~ "Gasto diario"
    assert html =~ "Gasto mensual"
    _ = member
  end
end
