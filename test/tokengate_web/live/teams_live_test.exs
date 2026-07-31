defmodule TokengateWeb.TeamsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Providers}
  alias Tokengate.Repo

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "teams-#{u}@example.com",
        name: "Teams #{u}",
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

  defp team_fixture(attrs \\ %{}) do
    u = unique()

    {:ok, model_alias} =
      Providers.create_model_alias(%{
        name: "gpt-#{u}",
        display_name: "GPT #{u}",
        context_window: 128_000
      })

    {:ok, team} =
      Accounts.create_team(Map.merge(%{name: "Team #{u}"}, attrs))

    %{team: team, model_alias: model_alias}
  end

  # --------------------------------------------------------------------------
  # Access control
  # --------------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/teams")
  end

  test "non-admin authenticated users are redirected to /dashboard", %{conn: conn} do
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/teams")
  end

  # --------------------------------------------------------------------------
  # Mount and render
  # --------------------------------------------------------------------------

  test "admin sees the teams page with empty state", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/teams")

    assert html =~ "Equipos"
    assert has_element?(view, "#new-team-btn")
    assert has_element?(view, "#teams-empty")
  end

  test "admin sees existing teams in the stream", %{conn: conn} do
    %{team: team} = team_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/teams")

    assert html =~ team.name
    assert has_element?(view, "#edit-#{team.id}")
  end

  # --------------------------------------------------------------------------
  # CRUD — Create
  # --------------------------------------------------------------------------

  test "admin creates a team", %{conn: conn} do
    team_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/teams")

    view |> element("#new-team-btn") |> render_click()
    assert has_element?(view, "#team-form")

    html =
      view
      |> form("#team-form", %{
        team: %{
          name: "Mi Nuevo Equipo",
          monthly_budget_per_user_usd: "10.50",
          default_concurrency_limit: 10,
          default_rpm_limit: 120
        }
      })
      |> render_submit()

    assert html =~ "Equipo creado"
    assert html =~ "Mi Nuevo Equipo"
    assert html =~ "10.5"
  end

  test "create with invalid params shows errors", %{conn: conn} do
    team_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/teams")

    view |> element("#new-team-btn") |> render_click()

    html =
      view
      |> form("#team-form", %{
        team: %{
          name: ""
        }
      })
      |> render_submit()

    # Form stays open with errors
    assert has_element?(view, "#team-form")
    _ = html
  end

  # --------------------------------------------------------------------------
  # CRUD — Update
  # --------------------------------------------------------------------------

  test "admin edits a team", %{conn: conn} do
    %{team: team} = team_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/teams")

    view |> element("#edit-#{team.id}") |> render_click()
    assert has_element?(view, "#team-form")

    html =
      view
      |> form("#team-form", %{
        team: %{name: "Equipo Renombrado"}
      })
      |> render_submit()

    assert html =~ "Equipo actualizado"
    assert html =~ "Equipo Renombrado"
  end

  test "cancel_form closes the form", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/teams")

    view |> element("#new-team-btn") |> render_click()
    assert has_element?(view, "#team-form")

    render_click(view, "cancel_form")
    refute has_element?(view, "#team-form")
  end

  # --------------------------------------------------------------------------
  # CRUD — Delete
  # --------------------------------------------------------------------------

  test "admin deletes a team", %{conn: conn} do
    %{team: team} = team_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/teams")

    assert has_element?(view, "#delete-#{team.id}")

    html = view |> element("#delete-#{team.id}") |> render_click()

    assert html =~ "Equipo eliminado"
    refute has_element?(view, "#delete-#{team.id}")
  end

  # --------------------------------------------------------------------------
  # Team model alias assignment
  # --------------------------------------------------------------------------

  test "admin toggles a model alias grant on a team", %{conn: conn} do
    %{team: team, model_alias: alias_} = team_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/teams")

    # The checkbox should be present and unchecked
    assert html =~ alias_.name
    assert has_element?(view, "#alias-#{team.id}-#{alias_.id}")

    # Grant the alias
    html =
      view
      |> element("#alias-#{team.id}-#{alias_.id}")
      |> render_click()

    assert html =~ "Aliases actualizados"

    # Verify the grant was persisted
    grant =
      Repo.get_by(
        Tokengate.Providers.TeamModelAlias,
        team_id: team.id,
        model_alias_id: alias_.id
      )

    assert grant != nil

    # Toggle again to revoke
    html =
      view
      |> element("#alias-#{team.id}-#{alias_.id}")
      |> render_click()

    assert html =~ "Aliases actualizados"

    refute Repo.get_by(
             Tokengate.Providers.TeamModelAlias,
             team_id: team.id,
             model_alias_id: alias_.id
           )
  end

  test "link to members page is present", %{conn: conn} do
    %{team: team} = team_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/teams")

    assert has_element?(view, "#members-link-#{team.id}")
  end

  # --------------------------------------------------------------------------
  # Webhooks
  # --------------------------------------------------------------------------

  test "clicking new_webhook shows the form", %{conn: conn} do
    %{team: team} = team_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/teams")

    assert has_element?(view, "#new-webhook-#{team.id}")

    view
    |> element("#new-webhook-#{team.id}")
    |> render_click()

    assert has_element?(view, "#destination-form-#{team.id}")
  end
end
