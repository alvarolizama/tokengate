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

    {:ok, org} = Accounts.create_organization(%{name: "Org #{u}", slug: "org-#{u}"})
    {:ok, team} = Accounts.create_team(%{organization_id: org.id, name: "Team #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member, token} =
      Accounts.create_team_member(%{user_id: owner.id, team_id: team.id, team_role: role})

    %{
      org: org,
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

  test "user sees their own key masked per team", %{conn: conn} do
    %{team: team, owner: owner, member: member, owner_password: password} = team_with_member()

    conn = login(conn, owner, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/keys")

    assert html =~ "Tus claves"
    assert html =~ team.name
    assert has_element?(view, "#membership-#{member.id}")
    # Never shows the full token, only the prefix
    assert html =~ "••••"
    refute html =~ "Sin clave"
  end

  test "user without teams sees the empty state", %{conn: conn} do
    %{user: user, password: password} = register()

    conn = login(conn, user, password)
    {:ok, _view, html} = live(conn, ~p"/dashboard/keys")

    assert html =~ "No perteneces a ningún equipo todavía."
  end

  test "replace_key generates a new token and shows it once", %{conn: conn} do
    %{owner: owner, member: member, token: old_token, owner_password: password} =
      team_with_member()

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/keys")

    html =
      view
      |> element("#replace-#{member.id}")
      |> render_click()

    assert html =~ "Nueva clave generada"
    assert has_element?(view, "#new-token-alert")
    assert has_element?(view, "#new-token-value")
    refute html =~ old_token

    # Dismissing hides the alert
    view
    |> element("#dismiss-token-btn")
    |> render_click()

    refute has_element?(view, "#new-token-alert")
  end

  test "revoke_key marks the key as revoked", %{conn: conn} do
    %{owner: owner, member: member, owner_password: password} = team_with_member()

    conn = login(conn, owner, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/keys")

    assert html =~ "Activa"

    html =
      view
      |> element("#revoke-#{member.id}")
      |> render_click()

    assert html =~ "Revocada"
    refute has_element?(view, "#revoke-#{member.id}")
  end

  test "user cannot revoke or replace another member's key", %{conn: conn} do
    %{owner: owner, member: _member, owner_password: password} = team_with_member()
    %{member: other_member} = team_with_member()

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/keys")

    html = render_click(view, "revoke_key", %{"id" => other_member.id})
    assert html =~ "No autorizado."

    html = render_click(view, "replace_key", %{"id" => other_member.id})
    assert html =~ "No autorizado."
  end

  test "manager sees the managed teams keys section", %{conn: conn} do
    %{owner: manager, owner_password: password} = team_with_member(%{team_role: "manager"})

    conn = login(conn, manager, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/keys")

    assert html =~ "Claves de equipos"
    assert has_element?(view, "#managed-keys-section")
  end

  test "plain user does not see the managed teams section", %{conn: conn} do
    %{owner: owner, owner_password: password} = team_with_member(%{team_role: "user"})

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/keys")

    refute has_element?(view, "#managed-keys-section")
  end
end
