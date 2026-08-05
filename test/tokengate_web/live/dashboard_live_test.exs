defmodule TokengateWeb.DashboardLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Logs, Periods, Providers}
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

    owner =
      case Map.get(opts, :user) do
        nil ->
          {:ok, user} =
            Accounts.register_user(%{
              email: "owner-#{u}@example.com",
              name: "Owner #{u}",
              password: "password-secret-#{u}1"
            })

          user

        %{} = user ->
          user
      end

    {:ok, member} =
      Accounts.create_team_member(%{user_id: owner.id, team_id: team.id, team_role: "user"})

    if cost = Map.get(opts, :cost) do
      {:ok, provider} =
        Providers.create_provider(%{
          name: "P #{u}",
          base_url: "http://localhost:1"
        })

      inserted_at =
        Map.get(opts, :inserted_at) || DateTime.utc_now() |> DateTime.truncate(:second)

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
          provider_cost_usd: cost,
          latency_ms: 42,
          streaming: false,
          inserted_at: inserted_at
        })
    end

    password =
      case Map.get(opts, :user) do
        nil -> "password-secret-#{u}1"
        _ -> nil
      end

    %{team: team, owner: owner, member: member, owner_password: password}
  end

  defp team_with_member(_opts) do
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

    {:ok, _api_key, _token} = Accounts.replace_api_key(member)

    %{team: team, owner: owner, member: member, owner_password: "password-secret-#{u}1"}
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

  test "admin sees period selector with all options", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#period-selector")
    assert has_element?(view, "#period-today")
    assert has_element?(view, "#period-7d")
    assert has_element?(view, "#period-30d")
    assert has_element?(view, "#period-90d")
    _ = html
  end

  test "admin sees metric cards when there is traffic", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    # Insert a log for the ADMIN's own membership (user-wide scope)
    team_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    refute has_element?(view, "#empty-state")
    assert has_element?(view, "#requests-card")
    assert has_element?(view, "#cost-card")
    assert has_element?(view, "#tokens-card")
    assert has_element?(view, "#tps-card")
    _ = html
  end

  test "admin does NOT see other members' traffic (user-wide)", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    # Log belongs to ANOTHER user's membership — admin must NOT see it
    team_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#empty-state")
    assert html =~ "Aún no hay requests"
  end

  test "admin with no memberships sees empty state", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#empty-state")
  end

  test "scope label is Personal for admin (user-wide dashboard)", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    conn = login(conn, admin, password)
    {:ok, _view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Personal"
  end

  test "admin sees breakdown tabs", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    team_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#breakdown-tabs")
    assert has_element?(view, "#tab-model")
    assert has_element?(view, "#tab-member")
    # Team breakdown is not shown on the personal dashboard
    refute has_element?(view, "#tab-team")
  end

  test "switching breakdown tab shows the right table", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    team_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    # Default is model
    html = render(view)
    assert html =~ "bd-model-"

    # Switch to member
    view |> element("#tab-member") |> render_click()
    html = render(view)
    assert html =~ "bd-member-"

    # Team tab is not rendered on the personal dashboard
    refute has_element?(view, "#tab-team")
  end

  test "switching period reloads metrics", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    team_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    # Default period is today — chart title reflects it
    assert html =~ "Costo por hora"
    # Switch to 30d
    view |> element("#period-30d") |> render_click()
    html = render(view)
    assert html =~ "Costo por día (30d)"
  end

  test "today period excludes logs from the previous local day", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, "America/Mexico_City")
    Collector.reset()

    # 23:00 del día anterior local (UTC-6) → NO cuenta en "Hoy" local
    today_start = Periods.start_of_day_utc("America/Mexico_City")

    team_with_log(%{
      cost: "0.005",
      user: admin,
      inserted_at: DateTime.add(today_start, -3600, :second)
    })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#empty-state")
  end

  test "today period includes logs from the current local day", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, "America/Mexico_City")
    Collector.reset()

    today_start = Periods.start_of_day_utc("America/Mexico_City")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    candidate = DateTime.add(today_start, 3600, :second)

    inserted_at =
      if DateTime.compare(candidate, now) == :lt,
        do: candidate,
        else: DateTime.add(now, -60, :second)

    team_with_log(%{cost: "0.005", user: admin, inserted_at: inserted_at})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    refute has_element?(view, "#empty-state")
    assert has_element?(view, "#requests-card")
  end

  test "admin sees analytics charts with traffic", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    # Admin needs their own team + member + log to see personal data
    %{owner_password: _password} = team_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#charts-grid")
    assert has_element?(view, "#cost-chart")
    assert has_element?(view, "#requests-chart")

    # Series carry the rollup data (cost + requests)
    assert html =~ "Costo por hora"
    assert html =~ "Requests por hora"

    # SVG bars rendered for the non-zero series
    assert has_element?(view, "#cost-chart svg rect")
    assert has_element?(view, "#requests-chart svg rect")
  end

  test "user scope: sees only their own consumption", %{conn: conn} do
    %{team: _team, owner: owner, member: member, owner_password: password} =
      team_with_log(%{cost: "0.005"})

    # Someone else's log in another team — must not leak into the user's scope
    team_with_log(%{cost: "99.99"})

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    refute has_element?(view, "#empty-state")
    assert has_element?(view, "#requests-card")
    # The user's cost card should show 0.005 (their own), not 99.99
    html = render(view)
    assert html =~ "0.005"
    _ = member
  end

  ## Personal keys on dashboard --------------------------------------------

  test "user sees their own API key on dashboard", %{conn: conn} do
    %{team: team, owner: owner, member: member, owner_password: password} =
      team_with_member(%{team_role: "user"})

    conn = login(conn, owner, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

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

  test "user without teams sees empty state, no General auto-created", %{conn: conn} do
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    # No team assigned — should show empty state, not auto-create General
    assert has_element?(view, "#no-team-state")
    assert html =~ "No tienes ningún equipo asignado"
    refute html =~ "General", "should not auto-create General team"
    refute html =~ "Endpoint de la API", "should not show endpoint info without team"
    refute has_element?(view, "#api-usage-info")
    refute has_element?(view, "#period-selector")
  end

  ## Teams & budgets on dashboard ------------------------------------------

  test "user sees their team budget with spend bars", %{conn: conn} do
    %{team: team, owner: owner, member: member, owner_password: password} =
      team_with_member(%{team_role: "user"})

    conn = login(conn, owner, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#team-#{team.id}")
    assert html =~ "Gasto mensual"
    _ = member
  end
end
