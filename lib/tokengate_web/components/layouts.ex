defmodule TokengateWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use TokengateWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Optional assigns

    * `hide_navbar` — when `true`, the top navbar is not rendered. Useful
      for login / register pages that provide their own self-contained
      centered design.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

      <Layouts.app flash={@flash} hide_navbar>
        <.live_component module={LoginLive} id="login" />
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :hide_navbar, :boolean, default: false

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header :if={not @hide_navbar} class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex-1 flex w-fit items-center gap-2">
          <img src={~p"/images/logo.svg"} width="36" alt="TokenGate" />
          <span class="text-lg font-bold">TokenGate</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column px-1 space-x-4 items-center">
          <li>
            <.link href={~p"/login"} class="btn btn-primary gap-2">
              Iniciar sesión <span aria-hidden="true">&rarr;</span>
            </.link>
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Renders the dashboard (ops console) layout — the family shell (Commons §C12):
  sidebar + barra de contenido, sin topbar de identidad. Lo usan las LiveViews
  autenticadas (DashboardLive y las admin bajo el `live_session :admin`).

  - Raíz `h-screen` + `drawer lg:drawer-open`; barra de contenido `h-14` con el
    **único** toggle de navegación (gaveta en móvil, rail en desktop).
  - Sidebar colapsable a rail de iconos (`#sidebar-collapse` + `.shell-hide`).
  - Pie del sidebar: identidad + menú de usuario (`#user-menu`).

  ## Examples

      <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator} current_path={@current_path}>
        <h1>Dashboard</h1>
      </Layouts.dashboard>

  `current_scope` should be the signed-in `%Tokengate.Accounts.User{}` (or
  `nil` when unauthenticated — but authenticated live_sessions guard
  against that, so we render defensively either way).
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the signed-in user (Tokengate.Accounts.User)"

  attr :impersonator, :map,
    default: nil,
    doc: "the original admin user while an impersonation session is active"

  attr :alert_count, :integer, default: 0

  attr :current_path, :string,
    default: nil,
    doc: "request path used to highlight the active sidebar link"

  slot :inner_block, required: true

  def dashboard(assigns) do
    ~H"""
    <div class="h-screen bg-base-100 text-base-content">
      <%!-- Shell colapsable (desktop): el checkbox ES el estado y el CSS de
           app.css lo aplica sobre .shell-sidebar / .shell-hide. Vive acá
           —fuera del drawer— para que las reglas funcionen por hermandad. --%>
      <input id="sidebar-collapse" type="checkbox" class="hidden" phx-hook=".SidebarRail" />

      <%!-- `lg:grid-rows-1` declara la fila del grid del drawer acotada a la altura
           del shell (`h-full` → 100vh). Sin ella la fila es implícita y `auto`, así
           que crecía con el contenido: el `h-full` del `drawer-content` se resolvía
           contra una fila indefinida y el `flex-1 overflow-y-auto` del `main` no
           acotaba nada — con contenido largo scrolleaba el DOCUMENTO y la sidebar
           (100vh) se iba con el scroll, dejando su pie flotando a media página.
           Solo desde `lg`: en móvil el drawer es un overlay `position: fixed` y el
           scroll de página es el comportamiento deseado. --%>
      <div class="drawer lg:drawer-open h-full lg:grid-rows-1">
        <%!-- Móvil: el drawer-toggle abre/cierra la gaveta con overlay --%>
        <input id="app-drawer" type="checkbox" class="drawer-toggle" />

        <div class="drawer-content flex flex-col min-w-0 h-full">
          <div
            :if={@impersonator}
            id="impersonation-banner"
            class="bg-warning text-warning-content px-4 py-2 flex items-center justify-center gap-3 text-sm"
          >
            <.icon name="hero-eye" class="size-4" />
            <span>
              {gettext("Viewing as")} <strong>{@current_scope && @current_scope.email}</strong>
              — {gettext("session of")} {@impersonator.email}
            </span>
            <.link
              href={~p"/impersonate"}
              method="delete"
              class="btn btn-xs btn-neutral"
              id="stop-impersonating"
            >
              {gettext("Back to my account")}
            </.link>
          </div>

          <%!-- Barra del contenido: SIEMPRE visible y con el ÚNICO toggle de la
               navegación, en el mismo sitio en todos los anchos. En móvil abre
               la gaveta; en desktop colapsa la sidebar a rail. --%>
          <header class="flex h-14 shrink-0 items-center gap-2 border-b border-base-300 bg-base-100/80 px-3 backdrop-blur">
            <label
              for="app-drawer"
              class="btn btn-ghost btn-sm btn-square lg:hidden"
              title={gettext("Menu")}
            >
              <.icon name="hero-bars-3" class="size-5" />
            </label>
            <label
              for="sidebar-collapse"
              class="hidden btn btn-ghost btn-sm btn-square lg:inline-flex"
              title={gettext("Collapse or expand the sidebar")}
            >
              <.icon name="hero-bars-3" class="size-5" />
            </label>
            <a
              href={~p"/"}
              class="flex shrink-0 items-center gap-2 rounded transition-colors duration-150 hover:opacity-80 lg:hidden"
            >
              <img src={~p"/images/logo.svg"} class="size-6 shrink-0" alt="TokenGate" />
              <span class="text-lg font-bold tracking-tight">TokenGate</span>
            </a>
          </header>

          <main class="flex min-h-0 flex-1 flex-col overflow-y-auto">
            <div class="w-full p-4 pb-16 sm:p-6">
              {render_slot(@inner_block)}
            </div>
          </main>
        </div>

        <.dashboard_sidebar
          current_scope={@current_scope}
          alert_count={@alert_count}
          current_path={@current_path}
        />

        <.flash_group flash={@flash} />
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SidebarRail">
        // El checkbox del rail vive en el DOM del shell, que se re-monta en cada
        // navegación: sin persistir, el rail se expandiría solo en cada clic.
        // Guarda el estado en el navegador y lo repone al montar.
        export default {
          mounted() {
            const key = "tokengate:sidebar-collapsed"
            if (localStorage.getItem(key) === "true") this.el.checked = true
            this.el.addEventListener("change", () => {
              localStorage.setItem(key, this.el.checked ? "true" : "false")
            })
          }
        }
      </script>
    </div>
    """
  end

  attr :current_scope, :map, default: nil
  attr :alert_count, :integer, default: 0
  attr :current_path, :string, default: nil
  attr :supervised_count, :integer, default: 0

  defp dashboard_sidebar(assigns) do
    assigns =
      if admin?(assigns.current_scope) do
        creds = Tokengate.Providers.count_error_credentials()
        breakers = Tokengate.Routing.CircuitBreakerManager.count_open()

        assigns
        |> assign(:alert_count, creds + breakers)
        # The supervised-services entry is for non-admins only: an admin
        # already reaches every service from /access/services.
        |> assign(:supervised_count, 0)
      else
        assign(assigns, :supervised_count, supervised_services_count(assigns.current_scope))
      end

    ~H"""
    <div class="drawer-side z-40">
      <label for="app-drawer" class="drawer-overlay" aria-label={gettext("Close menu")} />

      <aside class="shell-sidebar flex h-full w-60 shrink-0 flex-col border-r border-base-300 bg-base-200/50">
        <div class="border-b border-base-300 p-3">
          <div class="shell-sidebar-header flex items-center gap-2">
            <a
              href={~p"/"}
              class="flex shrink-0 items-center gap-2 rounded transition-colors duration-150 hover:opacity-80"
            >
              <img src={~p"/images/logo.svg"} class="size-6 shrink-0" alt="TokenGate" />
              <span class="shell-hide text-lg font-bold tracking-tight">TokenGate</span>
            </a>
          </div>
        </div>

        <%!-- Filtro del nav. TokenGate no tiene buscador global: el campo filtra
             en el cliente los enlaces del sidebar (y ⌘K / Ctrl+K lo enfoca). --%>
        <div class="shell-hide border-b border-base-300 p-3">
          <div class="relative">
            <.icon
              name="hero-magnifying-glass"
              class="absolute left-2.5 top-2.5 size-4 text-base-content/50"
            />
            <input
              type="text"
              id="sidebar-search"
              phx-hook=".NavFilter"
              placeholder={gettext("Filter navigation…")}
              autocomplete="off"
              class="w-full rounded-lg border border-base-300 bg-base-100 py-1.5 pl-8 pr-12 text-sm transition-colors duration-150 focus:ring-1 focus:ring-primary focus:outline-none"
            />
            <kbd class="absolute right-2.5 top-2 rounded border border-base-300 px-1 font-mono text-[10px] text-base-content/40">
              ⌘K
            </kbd>
          </div>
        </div>

        <nav id="sidebar-nav" class="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto p-2">
          <div class="flex flex-col gap-1">
            <.nav_link
              label={gettext("Dashboard")}
              icon="hero-chart-bar-square"
              path={~p"/dashboard"}
              active={active_path?(@current_path, ~p"/dashboard")}
            />

            <%!-- Los no-admins que supervisan servicios entran a su vista de
                 solo lectura desde aquí (para admins el enlace es /access/services). --%>
            <%= if not admin?(@current_scope) and @supervised_count > 0 do %>
              <.nav_link
                label={gettext("Supervised services")}
                icon="hero-eye"
                path={~p"/services/supervised"}
                active={active_path?(@current_path, ~p"/services/supervised")}
              />
            <% end %>

            <%= if admin?(@current_scope) do %>
              <.nav_link
                label={gettext("Stats")}
                icon="hero-chart-pie"
                path={~p"/stats"}
                active={active_path?(@current_path, ~p"/stats")}
              />
              <.nav_link
                label={gettext("Calculator")}
                icon="hero-calculator"
                path={~p"/calculator"}
                active={active_path?(@current_path, ~p"/calculator")}
              />
            <% end %>
          </div>

          <%= if admin?(@current_scope) do %>
            <.nav_group label={gettext("Catalog")} id="sidebar-section-catalogo">
              <%!-- Labs (quién construyó cada modelo) va antes de Proveedores:
                   el lab es el nivel más alto y no depende del proveedor. --%>
              <.nav_link
                label={gettext("Labs")}
                icon="hero-beaker"
                path={~p"/catalog/labs"}
                active={active_path?(@current_path, ~p"/catalog/labs")}
              />
              <.nav_link
                label={gettext("Providers")}
                icon="hero-server-stack"
                path={~p"/catalog/providers"}
                active={active_path?(@current_path, ~p"/catalog/providers")}
                badge={@alert_count}
                badge_kind="badge-error"
              />
              <.nav_link
                label={gettext("Models")}
                icon="hero-rectangle-stack"
                path={~p"/catalog/models"}
                active={active_path?(@current_path, ~p"/catalog/models")}
              />
            </.nav_group>

            <.nav_group label={gettext("Access")} id="sidebar-section-acceso">
              <%!-- Servicios va antes de Usuarios: un servicio no depende de
                   una sub mensual, así que se lista primero. --%>
              <.nav_link
                label={gettext("Services")}
                icon="hero-wrench-screwdriver"
                path={~p"/access/services"}
                active={active_path?(@current_path, ~p"/access/services")}
              />
              <.nav_link
                label={gettext("Users")}
                icon="hero-users"
                path={~p"/access/users"}
                active={active_path?(@current_path, ~p"/access/users")}
              />
            </.nav_group>

            <.nav_group label={gettext("Budget")} id="sidebar-section-budget">
              <%!-- Los perfiles de límites son el sujeto del que cada usuario
                   hereda su techo de gasto; los top-ups son crédito extra de un
                   solo uso, y el tope diario global es el kill-switch que corta
                   TODO el gateway (con sus exclusiones). Por eso la sección es
                   Presupuesto, no Acceso ni Operaciones. --%>
              <.nav_link
                label={gettext("Limit profiles")}
                icon="hero-user-group"
                path={~p"/budget/profiles"}
                active={active_path?(@current_path, ~p"/budget/profiles")}
              />
              <.nav_link
                label={gettext("Top-ups")}
                icon="hero-arrow-up-circle"
                path={~p"/budget/topups"}
                active={active_path?(@current_path, ~p"/budget/topups")}
              />
              <.nav_link
                label={gettext("Global daily cap")}
                icon="hero-globe-americas"
                path={~p"/budget/global"}
                active={active_path?(@current_path, ~p"/budget/global")}
              />
            </.nav_group>

            <.nav_group label={gettext("Operations")} id="sidebar-section-operaciones">
              <.nav_link
                label={gettext("Monitoring")}
                icon="hero-signal"
                path={~p"/operations/monitoring"}
                active={active_path?(@current_path, ~p"/operations/monitoring")}
              />
              <.nav_link
                label={gettext("Audit")}
                icon="hero-clipboard-document-list"
                path={~p"/operations/audit"}
                active={active_path?(@current_path, ~p"/operations/audit")}
              />
              <.nav_link
                label={gettext("Observability")}
                icon="hero-bell-alert"
                path={~p"/operations/observability"}
                active={active_path?(@current_path, ~p"/operations/observability")}
              />
              <.nav_link
                label={gettext("Notifications")}
                icon="hero-paper-airplane"
                path={~p"/operations/notifications"}
                active={active_path?(@current_path, ~p"/operations/notifications")}
              />
              <.nav_link
                label={gettext("Maintenance")}
                icon="hero-cog-6-tooth"
                path={~p"/operations/maintenance"}
                active={active_path?(@current_path, ~p"/operations/maintenance")}
              />
            </.nav_group>
          <% end %>
        </nav>

        <div class="border-t border-base-300 p-3">
          <.user_footer current_scope={@current_scope} />
        </div>
      </aside>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".NavFilter">
        // Filtro client-side del nav: lo escrito esconde los enlaces que no
        // coinciden (y los grupos que se quedan sin ninguno); ⌘K / Ctrl+K
        // enfoca el campo y Escape lo limpia. Sin round-trip: el nav del
        // sidebar es estático por página.
        export default {
          mounted() {
            this.links = [...this.el.closest("aside").querySelectorAll("#sidebar-nav .nav-link")]
            this.groups = [...this.el.closest("aside").querySelectorAll("[id^='sidebar-section-']")]

            this.el.addEventListener("input", () => this.filter())
            this.el.addEventListener("keydown", (e) => {
              if (e.key === "Escape") {
                this.el.value = ""
                this.filter()
              }
            })

            this.onKey = (e) => {
              if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
                e.preventDefault()
                this.el.focus()
                this.el.select()
              }
            }

            window.addEventListener("keydown", this.onKey)
          },
          destroyed() {
            window.removeEventListener("keydown", this.onKey)
          },
          filter() {
            const q = this.el.value.trim().toLowerCase()

            this.links.forEach((el) => {
              el.classList.toggle("hidden", q !== "" && !el.textContent.toLowerCase().includes(q))
            })

            this.groups.forEach((group) => {
              const any = group.querySelector(".nav-link:not(.hidden)")
              group.classList.toggle("hidden", !any)
            })
          }
        }
      </script>
    </div>
    """
  end

  # Pie del sidebar (Commons §C12.2): identidad + menú de usuario. El menú es
  # la vuelta desde cualquier URL: cuenta (Profile · API keys) + preferencias
  # (idioma y zona horaria) + salida.
  attr :current_scope, :map, default: nil

  defp user_footer(assigns) do
    ~H"""
    <div
      :if={@current_scope}
      id="user-footer"
      class="shell-user-footer relative flex items-center gap-2.5 rounded-lg p-2 transition-colors duration-150 hover:bg-base-200"
    >
      <%!-- El avatar es el disparador del modal de cuenta (ProfileModal): abrir
           limpio el diálogo es su evento `open_profile`, y el item "Profile"
           del menú lo dispara con un click sintético sobre el mismo botón. --%>
      <.live_component
        module={TokengateWeb.ProfileModal}
        id="profile-modal"
        user={@current_scope}
        initials={initials(@current_scope)}
      />

      <span class="shell-hide min-w-0 flex-1 leading-tight">
        <span class="block truncate text-sm font-medium">{@current_scope.name}</span>
        <span
          class="block truncate text-xs text-base-content/50 mt-0.5"
          title={@current_scope.email}
        >
          {@current_scope.email}
        </span>
      </span>

      <%!-- El panel se ancla al FOOTER (relative), no al chevron: anclado al
           chevron un w-64 sobresalía del sidebar de 240px y el `drawer-side`
           de daisyUI (overflow hidden) lo recortaba por la izquierda. Con
           `left-0 w-full` mide exactamente el ancho del sidebar. --%>
      <details class="shrink-0" id="user-menu">
        <summary
          class="btn btn-ghost btn-xs btn-circle list-none"
          aria-label={gettext("Account menu")}
        >
          <.icon name="hero-chevron-up" class="size-3" />
        </summary>
        <div class="absolute bottom-full left-0 z-50 mb-1 w-full rounded-lg border border-base-300 bg-base-100 py-1 shadow-lg">
          <.menu_item
            label={gettext("Profile")}
            icon="hero-user"
            on_click={
              JS.dispatch("click", to: "#profile-avatar-button")
              |> JS.dispatch("click", to: "#user-menu > summary")
            }
          />
          <.menu_item label={gettext("API keys")} icon="hero-key" href={~p"/dashboard"} />

          <div class="my-1 border-t border-base-300"></div>
          <div class="px-3 py-1.5">
            <.locale_selector current_scope={@current_scope} />
          </div>
          <div class="px-3 py-1.5">
            <.timezone_selector current_scope={@current_scope} />
          </div>

          <div class="my-1 border-t border-base-300"></div>
          <.link
            href={~p"/logout"}
            method="delete"
            id="logout-button"
            data-confirm={gettext("Sign out?")}
            class="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm text-error transition-colors hover:bg-base-200"
          >
            <.icon name="hero-arrow-right-on-rectangle" class="size-4" />
            {gettext("Log out")}
          </.link>
        </div>
      </details>
    </div>
    """
  end

  # A link is active on its own route and on any of its sub-routes, so
  # drill-downs keep the parent entry lit (e.g. /budget/profiles/42/members
  # highlights Perfiles de límites).
  defp active_path?(nil, _href), do: false

  defp active_path?(path, href) when is_binary(path) and is_binary(href) do
    path == href or String.starts_with?(path, href <> "/")
  end

  defp active_path?(_path, _href), do: false

  attr :current_scope, :map, default: nil

  defp timezone_selector(assigns) do
    tz = assigns.current_scope && assigns.current_scope.timezone

    assigns = Phoenix.Component.assign(assigns, :current_timezone, tz || "Etc/UTC")

    ~H"""
    <div id="timezone-selector">
      <.form for={%{}} phx-change="set-timezone" id="tz-form">
        <label
          for="tz-select"
          class="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-base-content/40 mb-1.5"
        >
          <.icon name="hero-clock" class="w-4 h-4" /> {gettext("Timezone")}
        </label>
        <select
          id="tz-select"
          name="timezone"
          class="select select-bordered select-sm w-full text-xs"
        >
          <%= for {region, zones} <- timezone_options() do %>
            <optgroup label={region}>
              <%= for {label, value} <- zones do %>
                <option value={value} selected={value == @current_timezone}>
                  {label}
                </option>
              <% end %>
            </optgroup>
          <% end %>
        </select>
      </.form>
    </div>
    """
  end

  # Idioma de la UI. Cada opción sale de `TokengateWeb.Gettext.ui_locales/0`
  # (la config), así que agregar un idioma no toca esta plantilla; el nombre
  # visible sí es un msgid propio.
  #
  # El idioma activo se lee del usuario (`current_scope.locale`), igual que la
  # zona horaria: es la verdad durable y sobrevive al evento porque el hook
  # reasigna `:current_user`.
  attr :current_scope, :map, default: nil

  defp locale_selector(assigns) do
    assigns =
      Phoenix.Component.assign(
        assigns,
        :current_locale,
        TokengateWeb.Gettext.locale_of(assigns.current_scope)
      )

    ~H"""
    <div id="locale-selector">
      <.form for={%{}} phx-change="set-locale" id="locale-form">
        <label
          for="locale-select"
          class="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-base-content/40 mb-1.5"
        >
          <.icon name="hero-language" class="w-4 h-4" /> {gettext("Language")}
        </label>
        <select
          id="locale-select"
          name="locale"
          class="select select-bordered select-sm w-full text-xs"
        >
          <%= for locale <- TokengateWeb.Gettext.ui_locales() do %>
            <option value={locale} selected={locale == @current_locale}>
              {locale_label(locale)}
            </option>
          <% end %>
        </select>
      </.form>
    </div>
    """
  end

  # Banderas + código ISO: el `<select>` queda estrecho (el ancho lo marcaba el
  # texto "English") y el texto no necesita traducción — el nombre de un idioma
  # se escribe en su propio idioma, así que no es un msgid.
  defp locale_label("en"), do: "🇬🇧 EN"
  defp locale_label("es"), do: "🇪🇸 ES"
  defp locale_label(other), do: String.upcase(other)

  defp admin?(%{global_role: "admin"}), do: true
  defp admin?(_), do: false

  # Solo importa "¿supervisa algo?": un count ligero evita cargar los
  # servicios (con su api_key) en cada render del sidebar.
  defp supervised_services_count(%{id: id}),
    do: Tokengate.Accounts.count_services_for_supervisor(id)

  defp supervised_services_count(_), do: 0

  defp initials(%{email: email}) when is_binary(email) do
    case String.split(email, "@") do
      [name | _] ->
        name
        |> String.slice(0, 2)
        |> String.upcase()

      _ ->
        "—"
    end
  end

  defp initials(_), do: "—"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
