defmodule TokengateWeb.ObservabilityLiveTest do
  @moduledoc """
  Tests for the Observability section (global OTLP webhook destinations).

  La observabilidad es de toda la instalación: los destinos ya no pertenecen a
  una sub mensual ni se filtran por ella.
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

  defp destination_fixture do
    u = unique()

    {:ok, destination} =
      Observability.create_destination(%{
        name: "Datadog #{u}",
        type: "otlp_webhook",
        url: "https://example.com/otlp-#{u}"
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

  test "admin sees destinations", %{conn: conn} do
    destination = destination_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/operations/observability")

    assert html =~ "Observabilidad"
    assert has_element?(view, "#edit-destination-#{destination.id}")
    assert render(view) =~ destination.name
  end

  test "search filters destinations in memory", %{conn: conn} do
    destination = destination_fixture()
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

  # Los webhooks ya no cuelgan de una sub mensual: no hay filtro por grupo.
  test "no group filter is rendered", %{conn: conn} do
    destination_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/observability")

    refute has_element?(view, "#observability-group-filter-form")
    refute has_element?(view, "#group-filter")
  end

  # --------------------------------------------------------------------------
  # CRUD
  # --------------------------------------------------------------------------

  test "new destination modal opens", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/observability")

    view |> element("#new-destination-btn") |> render_click()
    assert has_element?(view, "#destination-form")
  end

  test "creates a destination from the modal", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/observability")

    view |> element("#new-destination-btn") |> render_click()

    view
    |> element("#destination-form")
    |> render_submit(%{
      destination: %{
        name: "New hook",
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
    destination = destination_fixture()
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
