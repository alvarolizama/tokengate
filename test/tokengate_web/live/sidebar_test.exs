defmodule TokengateWeb.SidebarTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.Accounts

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "sidebar-#{u}@example.com",
        name: "Sidebar #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, %{user: user, password: password}) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp admin_conn(conn), do: login(conn, register("admin"))

  defp user_conn(conn), do: login(conn, register("user"))

  # Scoped descendant selectors, so each assertion pins a link to its section.
  defp in_section?(view, section, link) do
    has_element?(view, "##{section} ##{link}")
  end

  test "admin entries are grouped into four labelled sub-sections", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/providers")

    assert has_element?(view, "#sidebar-section-catalogo", "Catálogo")
    assert has_element?(view, "#sidebar-section-acceso", "Acceso")
    assert has_element?(view, "#sidebar-section-credito", "Crédito")
    assert has_element?(view, "#sidebar-section-operaciones", "Operaciones")

    assert in_section?(view, "sidebar-section-catalogo", "sidebar-link-catalog-providers")
    assert in_section?(view, "sidebar-section-catalogo", "sidebar-link-catalog-models")
    refute in_section?(view, "sidebar-section-catalogo", "sidebar-link-access-groups")

    assert in_section?(view, "sidebar-section-acceso", "sidebar-link-access-groups")
    assert in_section?(view, "sidebar-section-acceso", "sidebar-link-access-users")
    assert in_section?(view, "sidebar-section-acceso", "sidebar-link-access-services")
    refute in_section?(view, "sidebar-section-acceso", "sidebar-link-catalog-models")

    assert in_section?(view, "sidebar-section-credito", "sidebar-link-credit-subscriptions")
    assert in_section?(view, "sidebar-section-credito", "sidebar-link-credit-topups")
    refute in_section?(view, "sidebar-section-credito", "sidebar-link-operations-monitoring")

    assert in_section?(view, "sidebar-section-operaciones", "sidebar-link-operations-monitoring")

    assert in_section?(
             view,
             "sidebar-section-operaciones",
             "sidebar-link-operations-observability"
           )

    assert in_section?(view, "sidebar-section-operaciones", "sidebar-link-operations-maintenance")
    refute in_section?(view, "sidebar-section-operaciones", "sidebar-link-credit-subscriptions")

    # The old single "Administración" block is gone.
    refute has_element?(view, "nav p", "Administración")

    # ...and the sections render in this order.
    html = render(view)

    positions =
      Enum.map(~w(catalogo acceso credito operaciones), fn section ->
        {pos, _len} = :binary.match(html, "sidebar-section-#{section}")
        pos
      end)

    assert positions == Enum.sort(positions)
  end

  test "the active route is highlighted, drill-downs keep the parent lit", %{conn: conn} do
    conn = admin_conn(conn)

    {:ok, view, _html} = live(conn, ~p"/catalog/providers")
    assert has_element?(view, "#sidebar-link-catalog-providers[aria-current=page]")
    refute has_element?(view, "#sidebar-link-access-groups[aria-current]")
    refute has_element?(view, "#sidebar-link-dashboard[aria-current]")

    {:ok, view, _html} = live(recycle(conn), ~p"/stats/models")
    assert has_element?(view, "#sidebar-link-stats[aria-current=page]")
    refute has_element?(view, "#sidebar-link-catalog-models[aria-current]")
  end

  test "the sidebar links to the section-prefixed routes", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/providers")

    # The URL scheme is part of the sidebar contract: each entry points at
    # the English sub-section prefix, not at the retired /admin one.
    for {id, href} <- [
          {"sidebar-link-catalog-providers", "/catalog/providers"},
          {"sidebar-link-catalog-models", "/catalog/models"},
          {"sidebar-link-access-groups", "/access/groups"},
          {"sidebar-link-access-users", "/access/users"},
          {"sidebar-link-access-services", "/access/services"},
          {"sidebar-link-credit-subscriptions", "/credit/subscriptions"},
          {"sidebar-link-credit-topups", "/credit/topups"},
          {"sidebar-link-operations-monitoring", "/operations/monitoring"},
          {"sidebar-link-operations-observability", "/operations/observability"},
          {"sidebar-link-operations-maintenance", "/operations/maintenance"}
        ] do
      assert has_element?(view, ~s(##{id}[href="#{href}"]))
    end

    refute render(view) =~ "/admin/"
  end

  test "non-admins see no admin sub-sections", %{conn: conn} do
    {:ok, view, _html} = live(user_conn(conn), ~p"/dashboard")

    assert has_element?(view, "#sidebar-link-dashboard[aria-current=page]")
    refute has_element?(view, "#sidebar-section-catalogo")
    refute has_element?(view, "#sidebar-section-operaciones")
  end
end
