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

    # Presupuesto tiene DOS links: los perfiles de límites (el sujeto que
    # aporta el techo de gasto) y los top-ups (crédito de un solo uso).
    assert in_section?(view, "sidebar-section-budget", "sidebar-link-budget-profiles")
    assert in_section?(view, "sidebar-section-budget", "sidebar-link-budget-topups")
    refute has_element?(view, "#sidebar-link-budget-global")
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

    # Inside a section the links render in this order too. In Catalog:
    # Models -> Providers -> Labs; en Presupuesto los perfiles van antes de los top-ups.
    for {first, second} <- [
          {"sidebar-link-catalog-models", "sidebar-link-catalog-providers"},
          {"sidebar-link-catalog-providers", "sidebar-link-catalog-labs"},
          {"sidebar-link-access-services", "sidebar-link-access-users"},
          {"sidebar-link-budget-profiles", "sidebar-link-budget-topups"}
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

  test "la entrada de presupuesto se llama «Perfiles»", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/providers")

    assert has_element?(view, "#sidebar-section-budget", "Presupuesto")
    assert has_element?(view, "#sidebar-link-budget-profiles", "Perfiles")
    refute has_element?(view, "#sidebar-link-budget-profiles", "Perfiles de límites")

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

  # El shell scrollea por dentro, no la página. La fila del grid del drawer
  # (`lg:grid-rows-1`) la acota a la altura del shell para que el `h-full` de la
  # barra de contenido y el `flex-1 overflow-y-auto` del `main` tengan techo.
  # Sin esa clase la fila crecía con el contenido: con tablas largas scrolleaba
  # el documento entero y la sidebar (100vh) se iba con el scroll, dejando su
  # pie flotando a media página sobre una columna vacía.
  test "el shell acota la fila del drawer desde lg y el scroll vive en el main", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/providers")

    assert has_element?(view, ~s(.drawer[class~="lg:grid-rows-1"]))
    assert has_element?(view, ".drawer-content.h-full")
    assert has_element?(view, "main.overflow-y-auto")
    assert has_element?(view, ".shell-sidebar.h-full")
  end

  # El panel móvil flota fixed sobre el contenido: un fondo translúcido ahí
  # deja leer el texto de atrás (regresión de 5f2802d). Opaco bajo `lg` —
  # el MISMO breakpoint donde el drawer deja de flotar — y el tinte `…/50`
  # sobrevive solo en desktop, donde el aside es sticky sobre base-100.
  test "el sidebar móvil no depende de un fondo translúcido", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/providers")

    assert has_element?(view, ~s(.shell-sidebar[class~="bg-base-200"]))
    refute has_element?(view, ~s(.shell-sidebar[class~="bg-base-200/50"]))
  end

  # F23: el filtro del nav vive en el cliente, pero los patches del servidor
  # (timers de 2-3s) reescriben el `class` de cada enlace desde el HTML del
  # servidor: el hook .NavFilter vuelve a aplicar lo tecleado tras cada
  # `phx:update`. El markup que el hook necesita para encontrarlos es contrato.
  test "el filtro del sidebar tiene su input y su nav", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/providers")

    assert has_element?(view, "#sidebar-search")
    # El hook (namespaceado al compilar) es el que re-aplica el filtro tras
    # cada `phx:update`.
    assert render(view) =~ ~s(phx-hook="TokengateWeb.Layouts.NavFilter")
    assert has_element?(view, "#sidebar-nav .nav-link")
    # El campo de filtro se oculta con el rail, pero nunca se duplica.
    assert length(Regex.scan(~r/id="sidebar-search"/, render(view))) == 1
  end

  # F23: cambiar de idioma remonta el LiveView en la MISMA URL, query string
  # incluida — `?period=` / `?new=1` / un filtro no se pierden al cambiar de
  # idioma (antes se hacía push_navigate solo con el path).
  test "cambiar de idioma preserva el query string", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, %{user: admin, password: password})

    {:ok, view, _html} = live(conn, ~p"/calculator?period=today")

    assert {:error, {:live_redirect, %{kind: :push, to: to}}} =
             render_change(view, "set-locale", %{"locale" => "es"})

    # Misma ruta Y mismo periodo: el remonte por idioma no es una navegación.
    assert to == "/calculator?period=today"

    # Y sin query string sigue yendo a la ruta limpia (no "…?").
    {:ok, view_plain, _html} = live(conn, ~p"/calculator")

    assert {:error, {:live_redirect, %{to: "/calculator"}}} =
             render_change(view_plain, "set-locale", %{"locale" => "es"})
  end

  # F24/P16: `put_flash(socket, :warning, …)` (alta de usuario con presupuesto
  # fallido) se guardaba y nunca se pintaba: `<.flash>` de core_components solo
  # acepta :info/:error.
  test "el flash :warning se renderiza en el shell", %{conn: _conn} do
    html =
      render_component(&TokengateWeb.Layouts.flash_group/1, %{
        flash: %{"warning" => "Usuario creado sin presupuesto"}
      })

    assert html =~ "flash-warning"
    assert html =~ "Usuario creado sin presupuesto"

    # Sin warning en el flash no se pinta el contenedor.
    html = render_component(&TokengateWeb.Layouts.flash_group/1, %{flash: %{}})
    refute html =~ "flash-warning"
  end

  test "sidebar nav links use live navigation (data-phx-link=redirect)", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/catalog/providers")

    assert has_element?(view, "#sidebar-link-catalog-models[data-phx-link='redirect']")
    assert has_element?(view, "#sidebar-link-budget-topups[data-phx-link='redirect']")
  end

  describe "S1 foundation primitives" do
    test "CoreComponents.header/1 includes flex-wrap when actions are present" do
      html =
        render_component(&TokengateWeb.CoreComponents.header/1, %{
          inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "Title" end}],
          actions: [%{__slot__: :actions, inner_block: fn _, _ -> "Action" end}]
        })

      assert html =~ "flex-wrap"
      assert html =~ "Title"
      assert html =~ "Action"
    end

    test "KpiHelpers.kpi_cards/1 uses mobile-first grid and wraps #kpi-tokens" do
      html =
        render_component(&TokengateWeb.KpiHelpers.kpi_cards/1, %{
          metrics: TokengateWeb.KpiHelpers.empty_metrics()
        })

      assert html =~ "grid-cols-1 sm:grid-cols-2 lg:grid-cols-4"
      assert html =~ ~r/id="kpi-tokens"[\s\S]*flex-wrap/
    end

    test "StatsHelpers.list_search/1 renders form wrapper with debounce and no phx-keyup" do
      html =
        render_component(&TokengateWeb.StatsHelpers.list_search/1, %{
          id: "test-list-search",
          value: "abc",
          placeholder: "Filter..."
        })

      assert html =~ ~s(<form)
      assert html =~ ~s(id="test-list-search-form")
      assert html =~ ~s(phx-change="filter_list")
      assert html =~ ~s(phx-submit="filter_list")
      assert html =~ ~s(id="test-list-search")
      assert html =~ ~s(name="value")
      assert html =~ ~s(phx-debounce="250")
      refute html =~ "phx-keyup"
    end

    test "StatsHelpers.show_more/1 translates via gettext (EN and ES)" do
      TokengateWeb.Gettext.put_locale("en")

      html_en =
        render_component(&TokengateWeb.StatsHelpers.show_more/1, %{
          key: "models",
          id: "models-more",
          top: 10,
          total: 15
        })

      assert html_en =~ "Show more (5 remaining)"

      TokengateWeb.Gettext.put_locale("es")

      html_es =
        render_component(&TokengateWeb.StatsHelpers.show_more/1, %{
          key: "models",
          id: "models-more",
          top: 10,
          total: 15
        })

      assert html_es =~ "Ver más (5 restantes)"
    end

    test "AdminComponents.admin_pagination/1 translates range via gettext (EN and ES)" do
      TokengateWeb.Gettext.put_locale("en")

      html_en =
        render_component(&TokengateWeb.AdminComponents.admin_pagination/1, %{
          id: "users-pagination",
          page: 1,
          per_page: 10,
          total: 25,
          total_pages: 3
        })

      assert html_en =~ "1–10 of 25"

      TokengateWeb.Gettext.put_locale("es")

      html_es =
        render_component(&TokengateWeb.AdminComponents.admin_pagination/1, %{
          id: "users-pagination",
          page: 1,
          per_page: 10,
          total: 25,
          total_pages: 3
        })

      assert html_es =~ "1–10 de 25"
    end
  end
end
