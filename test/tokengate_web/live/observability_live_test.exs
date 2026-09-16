defmodule TokengateWeb.ObservabilityLiveTest do
  @moduledoc """
  Tests for the Observability section (webhook destinations extracted
  from GroupsLive).
  """
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.Accounts
  alias Tokengate.Observability
  alias Tokengate.Repo

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "observability-#{u}@example.com",
        name: "Obs #{u}",
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

  defp group_fixture do
    u = unique()
    {:ok, group} = Accounts.create_group(%{name: "Group #{u}"})
    group
  end

  defp destination_fixture(group) do
    u = unique()

    {:ok, destination} =
      Observability.create_destination(%{
        name: "Datadog #{u}",
        type: "otlp_webhook",
        url: "https://example.com/otlp-#{u}",
        group_id: group.id
      })

    destination
  end

  # --------------------------------------------------------------------------
  # Access control
  # --------------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/operations/observability")
  end

  test "non-admin authenticated users are redirected to /dashboard", %{conn: conn} do
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/operations/observability")
  end

  # --------------------------------------------------------------------------
  # Listing and filtering
  # --------------------------------------------------------------------------

  test "admin sees destinations with group name", %{conn: conn} do
    group = group_fixture()
    destination = destination_fixture(group)
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/operations/observability")

    assert html =~ "Observabilidad"
    assert has_element?(view, "#edit-destination-#{destination.id}")
    assert render(view) =~ group.name
  end

  test "search filters destinations in memory", %{conn: conn} do
    group = group_fixture()
    destination = destination_fixture(group)
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/observability")

    # El binding vive en el FORM, no en el input: un `phx-change` sin <form>
    # alrededor lanza en el cliente y el evento nunca llega al servidor.
    assert has_element?(view, "#observability-search-form input[name='search']")

    # No match — destination disappears
    view
    |> element("#observability-search-form")
    |> render_change(%{"search" => "zzz-no-match"})

    refute has_element?(view, "#edit-destination-#{destination.id}")

    # Match by name — destination reappears
    view
    |> element("#observability-search-form")
    |> render_change(%{"search" => destination.name})

    assert has_element?(view, "#edit-destination-#{destination.id}")
  end

  test "group filter narrows the list", %{conn: conn} do
    group = group_fixture()
    destination = destination_fixture(group)
    other_group = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/observability")

    assert has_element?(view, "#observability-group-filter-form select#group-filter")

    view
    |> element("#observability-group-filter-form")
    |> render_change(%{"group_filter" => other_group.id})

    refute has_element?(view, "#edit-destination-#{destination.id}")

    view
    |> element("#observability-group-filter-form")
    |> render_change(%{"group_filter" => group.id})

    assert has_element?(view, "#edit-destination-#{destination.id}")
  end

  # --------------------------------------------------------------------------
  # CRUD
  # --------------------------------------------------------------------------

  test "new destination modal opens", %{conn: conn} do
    group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/observability")

    view |> element("#new-destination-btn") |> render_click()
    assert has_element?(view, "#destination-form")
  end

  test "creates a destination from the modal", %{conn: conn} do
    group = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/observability")

    view |> element("#new-destination-btn") |> render_click()

    view
    |> element("#destination-form")
    |> render_submit(%{
      destination: %{
        name: "New hook",
        group_id: group.id,
        url: "https://example.com/new",
        headers: ""
      }
    })

    assert has_element?(view, "#destinations")
    html = render(view)
    assert html =~ "New hook"
    assert Repo.get_by!(Tokengate.Observability.Destination, name: "New hook")
  end

  test "deletes a destination", %{conn: conn} do
    group = group_fixture()
    destination = destination_fixture(group)
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/observability")

    view
    |> element("#delete-destination-#{destination.id}")
    |> render_click()

    refute has_element?(view, "#edit-destination-#{destination.id}")
    refute Repo.get(Tokengate.Observability.Destination, destination.id)
  end
end
