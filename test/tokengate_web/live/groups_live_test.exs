defmodule TokengateWeb.GroupsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Providers}
  alias Tokengate.Repo

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "groups-#{u}@example.com",
        name: "Groups #{u}",
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

  defp group_fixture(attrs \\ %{}) do
    u = unique()

    {:ok, model} =
      Providers.create_model(%{
        name: "gpt-#{u}",
        context_window: 128_000
      })

    {:ok, group} =
      Accounts.create_group(Map.merge(%{name: "Group #{u}"}, attrs))

    %{group: group, model: model}
  end

  # --------------------------------------------------------------------------
  # Access control
  # --------------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/admin/groups")
  end

  test "non-admin authenticated users are redirected to /dashboard", %{conn: conn} do
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/admin/groups")
  end

  # --------------------------------------------------------------------------
  # Mount and render
  # --------------------------------------------------------------------------

  test "admin sees the groups page with empty state via search filter", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/admin/groups")

    assert html =~ "Grupos"
    assert has_element?(view, "#new-group-btn")

    # Type a search term that matches no group → triggers empty state deterministically
    no_match_term = "zzz-no-match-#{System.unique_integer([:positive])}"
    view |> element("input[name='group_search']") |> render_change(%{group_search: no_match_term})

    assert has_element?(view, "#groups-empty")
  end

  test "admin sees existing groups in the stream", %{conn: conn} do
    %{group: group} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/admin/groups")

    assert html =~ group.name
    assert has_element?(view, "#edit-#{group.id}")
  end

  # --------------------------------------------------------------------------
  # CRUD — Create
  # --------------------------------------------------------------------------

  test "admin creates a group", %{conn: conn} do
    group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/admin/groups")

    view |> element("#new-group-btn") |> render_click()
    assert has_element?(view, "#group-form")

    html =
      view
      |> form("#group-form", %{
        group: %{
          name: "Mi Nuevo Grupo",
          monthly_budget_per_user_usd: "10.50",
          default_concurrency_limit: 10,
          default_rpm_limit: 120
        }
      })
      |> render_submit()

    assert html =~ "Grupo creado"
    assert html =~ "Mi Nuevo Grupo"
    assert html =~ "10.5"
  end

  test "create with invalid params shows errors", %{conn: conn} do
    group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/admin/groups")

    view |> element("#new-group-btn") |> render_click()

    html =
      view
      |> form("#group-form", %{
        group: %{
          name: ""
        }
      })
      |> render_submit()

    # Form stays open with errors
    assert has_element?(view, "#group-form")
    _ = html
  end

  # --------------------------------------------------------------------------
  # CRUD — Update
  # --------------------------------------------------------------------------

  test "admin edits a group", %{conn: conn} do
    %{group: group} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/admin/groups")

    view |> element("#edit-#{group.id}") |> render_click()
    assert has_element?(view, "#group-form")

    html =
      view
      |> form("#group-form", %{
        group: %{name: "Grupo Renombrado"}
      })
      |> render_submit()

    assert html =~ "Grupo actualizado"
    assert html =~ "Grupo Renombrado"
  end

  test "cancel_form closes the form", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/admin/groups")

    view |> element("#new-group-btn") |> render_click()
    assert has_element?(view, "#group-form")

    render_click(view, "cancel_form")
    refute has_element?(view, "#group-form")
  end

  # --------------------------------------------------------------------------
  # CRUD — Delete
  # --------------------------------------------------------------------------

  test "admin deletes a group", %{conn: conn} do
    %{group: group} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/admin/groups")

    assert has_element?(view, "#delete-#{group.id}")

    html = view |> element("#delete-#{group.id}") |> render_click()

    assert html =~ "Grupo eliminado"
    refute has_element?(view, "#delete-#{group.id}")
  end

  # --------------------------------------------------------------------------
  # Group model model assignment
  # --------------------------------------------------------------------------

  test "admin toggles a model grant on a group via the models modal", %{conn: conn} do
    %{group: group, model: model_} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/admin/groups")

    # The model picker is NOT in the card — only inside the models modal
    refute html =~ "Modelos del grupo</h4>"
    refute has_element?(view, "#model-picker-#{group.id}-#{model_.id}")

    # Open the models modal from the group card header
    view |> element("#edit-models-#{group.id}") |> render_click()
    assert has_element?(view, "#models-modal-#{group.id}")
    assert has_element?(view, "#model-picker-#{group.id}-#{model_.id}")

    # Grant the model
    html =
      view
      |> element("#model-picker-#{group.id}-#{model_.id}")
      |> render_click()

    assert html =~ "Modelos actualizados"

    # Verify the grant was persisted
    grant =
      Repo.get_by(
        Tokengate.Providers.GroupModel,
        group_id: group.id,
        model_id: model_.id
      )

    assert grant != nil

    # Toggle again to revoke
    html =
      view
      |> element("#model-picker-#{group.id}-#{model_.id}")
      |> render_click()

    assert html =~ "Modelos actualizados"

    refute Repo.get_by(
             Tokengate.Providers.GroupModel,
             group_id: group.id,
             model_id: model_.id
           )
  end

  test "link to members page is present", %{conn: conn} do
    %{group: group} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/admin/groups")

    assert has_element?(view, "#members-link-#{group.id}")
  end

  # --------------------------------------------------------------------------
  # Webhooks — managed in ObservabilityLive since the extraction
  # --------------------------------------------------------------------------

  test "webhooks badge links to observability section", %{conn: conn} do
    %{group: group} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/admin/groups")

    assert has_element?(view, "#webhooks-link-#{group.id}")
  end
end
