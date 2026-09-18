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

    # El idioma por defecto de la UI es inglés; este archivo fija las etiquetas
    # en español, así que el usuario arranca en español (`users.locale` es lo
    # que el `on_mount` aplica al LiveView).
    {:ok, user} = Accounts.update_user_locale(user, "es")

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, %{user: user, password: password}) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp admin_conn(conn), do: login(conn, register("admin"))

  defp user_conn(conn), do: login(conn, register("user"))

  # El sujeto del techo mensual (perfil de límites) sigue viviendo en la tabla
  # de perfiles de límites: solo se renombró la ruta y la etiqueta.
  defp profile_fixture(attrs) do
    {:ok, group} = Accounts.create_group(Map.merge(%{name: "Perfil #{unique()}"}, attrs))
    group
  end

  # Scoped descendant selectors, so each assertion pins a link to its section.
  defp in_section?(view, section, link) do
    has_element?(view, "##{section} ##{link}")
  end

  test "admin entries are grouped into four labelled sub-sections", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/providers")

    assert has_element?(view, "#sidebar-section-catalogo", "Catálogo")
    assert has_element?(view, "#sidebar-section-acceso", "Acceso")
    assert has_element?(view, "#sidebar-section-budget", "Presupuesto")
    assert has_element?(view, "#sidebar-section-operaciones", "Operaciones")

    assert in_section?(view, "sidebar-section-catalogo", "sidebar-link-catalog-providers")
    assert in_section?(view, "sidebar-section-catalogo", "sidebar-link-catalog-models")
    assert in_section?(view, "sidebar-section-catalogo", "sidebar-link-catalog-labs")
    refute in_section?(view, "sidebar-section-catalogo", "sidebar-link-budget-profiles")

    assert in_section?(view, "sidebar-section-acceso", "sidebar-link-access-users")
    assert in_section?(view, "sidebar-section-acceso", "sidebar-link-access-services")
    refute in_section?(view, "sidebar-section-acceso", "sidebar-link-catalog-models")

    # Presupuesto tiene TRES links: los perfiles de límites (el sujeto que
    # aporta el techo de gasto), los top-ups y el tope diario global (el
    # kill-switch que corta todo el gateway, con sus exclusiones).
    assert in_section?(view, "sidebar-section-budget", "sidebar-link-budget-profiles")
    assert in_section?(view, "sidebar-section-budget", "sidebar-link-budget-topups")
    assert in_section?(view, "sidebar-section-budget", "sidebar-link-budget-global")
    refute in_section?(view, "sidebar-section-budget", "sidebar-link-credit-subscriptions")
    refute in_section?(view, "sidebar-section-budget", "sidebar-link-operations-monitoring")
    refute in_section?(view, "sidebar-section-budget", "sidebar-link-access-users")
    # La URL vieja solo sobrevive como redirect: no es una entrada del sidebar.
    refute has_element?(view, "#sidebar-link-budget-months")
    refute render(view) =~ "/budget/months"

    assert in_section?(view, "sidebar-section-operaciones", "sidebar-link-operations-monitoring")

    assert in_section?(
             view,
             "sidebar-section-operaciones",
             "sidebar-link-operations-observability"
           )

    assert in_section?(view, "sidebar-section-operaciones", "sidebar-link-operations-maintenance")
    refute in_section?(view, "sidebar-section-operaciones", "sidebar-link-credit-subscriptions")
    refute in_section?(view, "sidebar-section-operaciones", "sidebar-link-budget-topups")

    # The old single "Administración" block is gone.
    refute has_element?(view, "nav p", "Administración")

    # ...and the sections render in this order.
    html = render(view)

    positions =
      Enum.map(~w(catalogo acceso budget operaciones), fn section ->
        {pos, _len} = :binary.match(html, "sidebar-section-#{section}")
        pos
      end)

    assert positions == Enum.sort(positions)

    # Inside a section the links render in this order too. Labs goes before
    # Proveedores (a lab is independent from any provider); en Presupuesto los
    # perfiles de límites van antes de los top-ups.
    for {first, second} <- [
          {"sidebar-link-catalog-labs", "sidebar-link-catalog-providers"},
          {"sidebar-link-catalog-providers", "sidebar-link-catalog-models"},
          {"sidebar-link-access-services", "sidebar-link-access-users"},
          {"sidebar-link-budget-profiles", "sidebar-link-budget-topups"},
          {"sidebar-link-budget-topups", "sidebar-link-budget-global"}
        ] do
      assert link_position(html, first) < link_position(html, second),
             "expected #{first} to render before #{second}"
    end
  end

  defp link_position(html, link_id) do
    {pos, _len} = :binary.match(html, link_id)
    pos
  end

  test "the active route is highlighted, drill-downs keep the parent lit", %{conn: conn} do
    conn = admin_conn(conn)

    {:ok, view, _html} = live(conn, ~p"/catalog/providers")
    assert has_element?(view, "#sidebar-link-catalog-providers[aria-current=page]")
    refute has_element?(view, "#sidebar-link-budget-profiles[aria-current]")
    refute has_element?(view, "#sidebar-link-dashboard[aria-current]")

    {:ok, view, _html} = live(recycle(conn), ~p"/stats/models")
    assert has_element?(view, "#sidebar-link-stats[aria-current=page]")
    refute has_element?(view, "#sidebar-link-catalog-models[aria-current]")
  end

  # El patrón de resaltado es por prefijo: la entrada de perfiles de límites se
  # enciende en su ruta y en su drill-down (y solo ahí, no en top-ups).
  test "perfiles de límites enciende su entrada en la ruta y en el drill-down", %{conn: conn} do
    conn = admin_conn(conn)

    {:ok, view, _html} = live(conn, ~p"/budget/profiles")
    assert has_element?(view, "#sidebar-link-budget-profiles[aria-current=page]")
    refute has_element?(view, "#sidebar-link-budget-topups[aria-current]")

    profile = profile_fixture(%{})

    {:ok, drill, _html} = live(recycle(conn), ~p"/budget/profiles/#{profile.id}/members")
    assert has_element?(drill, "#sidebar-link-budget-profiles[aria-current=page]")
    refute has_element?(drill, "#sidebar-link-budget-topups[aria-current]")
  end

  test "la entrada de presupuesto se llama «Perfiles de límites»", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/providers")

    assert has_element?(view, "#sidebar-section-budget", "Presupuesto")
    assert has_element?(view, "#sidebar-link-budget-profiles", "Perfiles de límites")

    # El vocabulario viejo ya no se renderiza.
    refute has_element?(view, "#sidebar-section-budget", "Presupuestos mensuales")
    refute render(view) =~ "Monthly budgets"
  end

  test "the sidebar links to the section-prefixed routes", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/providers")

    # The URL scheme is part of the sidebar contract: each entry points at
    # the English sub-section prefix, not at the retired /admin one.
    for {id, href} <- [
          {"sidebar-link-catalog-providers", "/catalog/providers"},
          {"sidebar-link-catalog-models", "/catalog/models"},
          {"sidebar-link-budget-profiles", "/budget/profiles"},
          {"sidebar-link-access-users", "/access/users"},
          {"sidebar-link-access-services", "/access/services"},
          {"sidebar-link-budget-topups", "/budget/topups"},
          {"sidebar-link-budget-global", "/budget/global"},
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
    refute has_element?(view, "#sidebar-section-budget")
  end
end
