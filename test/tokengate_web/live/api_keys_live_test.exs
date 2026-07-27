defmodule TokengateWeb.ApiKeysLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.Accounts

  defp unique, do: System.unique_integer([:positive])

  defp register(role \\ "user") do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "keys-#{u}@example.com",
        name: "Keys #{u}",
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

  defp team_with_member(opts \\ %{}) do
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

    {:ok, _api_key, token} = Accounts.replace_api_key(member)

    %{
      team: team,
      owner: owner,
      member: member,
      token: token,
      owner_password: "password-secret-#{u}1"
    }
  end

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/keys")
  end

  test "plain user is redirected to dashboard (keys are admin-only)", %{conn: conn} do
    %{owner: owner, owner_password: password} = team_with_member(%{team_role: "user"})

    conn = login(conn, owner, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/keys")
  end

  test "manager is redirected to dashboard (keys are admin-only)", %{conn: conn} do
    %{owner: manager, owner_password: password} = team_with_member(%{team_role: "manager"})

    conn = login(conn, manager, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/keys")
  end

  test "admin can revoke a team member's key", %{conn: conn} do
    %{member: member} = team_with_member(%{team_role: "user"})

    %{user: admin, password: admin_password} = register("admin")

    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/keys")

    html = view |> element("#revoke-#{member.id}") |> render_click()
    assert html =~ "Revocada"
    refute has_element?(view, "#revoke-#{member.id}")
  end

  test "admin sees all teams", %{conn: conn} do
    %{team: team, owner: owner, owner_password: password, member: member} =
      team_with_member(%{team_role: "user"})

    %{user: admin, password: admin_password} = register("admin")

    conn = login(conn, admin, admin_password)
    {:ok, view, html} = live(conn, ~p"/dashboard/keys")

    assert html =~ team.name
    assert has_element?(view, "#team-key-#{member.id}")
    _ = owner
  end
end
