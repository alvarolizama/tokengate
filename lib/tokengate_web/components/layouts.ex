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
  Renders the dashboard (ops console) layout — a premium, theme-driven sidebar +
  topbar shell used by authenticated LiveViews (DashboardLive and the
  admin LiveViews under the `:admin` live_session).

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
    <div class="drawer lg:drawer-open min-h-screen bg-base-200">
      <input id="dashboard-drawer" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content flex flex-col">
        <div
          :if={@impersonator}
          id="impersonation-banner"
          class="bg-warning text-warning-content px-4 py-2 flex items-center justify-center gap-3 text-sm"
        >
          <.icon name="hero-eye" class="w-4 h-4" />
          <span>
            Viendo como <strong>{@current_scope && @current_scope.email}</strong>
            — sesión de {@impersonator.email}
          </span>
          <.link
            href={~p"/impersonate"}
            method="delete"
            class="btn btn-xs btn-neutral"
            id="stop-impersonating"
          >
            Volver a mi cuenta
          </.link>
        </div>

        <.dashboard_topbar
          current_scope={@current_scope}
          timezone={(@current_scope && @current_scope.timezone) || assigns[:timezone] || "Etc/UTC"}
        />

        <main class="flex-1 p-4 sm:p-6 lg:p-8">
          {render_slot(@inner_block)}
        </main>
      </div>

      <.dashboard_sidebar
        current_scope={@current_scope}
        alert_count={@alert_count}
        current_path={@current_path}
      />

      <.flash_group flash={@flash} />
    </div>
    """
  end

  defp dashboard_topbar(assigns) do
    ~H"""
    <header class="sticky top-0 z-30 flex items-center gap-3 px-4 sm:px-6 lg:px-8 h-16 bg-base-100/80 backdrop-blur border-b border-base-300">
      <label
        for="dashboard-drawer"
        class="btn btn-ghost btn-square btn-sm lg:hidden"
        aria-label="Abrir menú"
      >
        <.icon name="hero-bars-3" class="w-5 h-5" />
      </label>

      <div class="flex-1" />

      <div class="flex items-center gap-3">
        <div class="hidden sm:flex flex-col items-end leading-tight">
          <span class="text-sm font-medium text-base-content">{@current_scope && @current_scope.email}</span>
          <span :if={@current_scope} class="text-xs text-base-content/50 uppercase tracking-wide">
            {role_label(@current_scope.global_role)}
          </span>
        </div>

        <%!-- El avatar abre en un modal la cuenta y el cambio de contraseña
             (la página /profile se retiró). --%>
        <.live_component
          :if={@current_scope}
          module={TokengateWeb.ProfileModal}
          id="profile-modal"
          user={@current_scope}
          initials={initials(@current_scope)}
        />

        <div :if={is_nil(@current_scope)} class="avatar avatar-placeholder">
          <div class="bg-primary text-primary-content w-9 rounded-full">
            <span class="text-sm font-semibold">{initials(@current_scope)}</span>
          </div>
        </div>

        <.link
          href={~p"/logout"}
          method="delete"
          class="btn btn-ghost btn-sm"
          data-confirm="¿Cerrar sesión?"
          id="logout-button"
        >
          <.icon name="hero-arrow-right-on-rectangle" class="w-5 h-5" />
          <span class="hidden sm:inline">Salir</span>
        </.link>
      </div>
    </header>
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
    <aside class="drawer-side z-40">
      <label for="dashboard-drawer" class="drawer-overlay" aria-label="Cerrar menú" />

      <div class="min-h-full w-64 bg-base-100 border-r border-base-300 flex flex-col">
        <div class="h-16 flex items-center gap-2 px-6 border-b border-base-300">
          <a href={~p"/"} class="flex items-center gap-2">
            <img src={~p"/images/logo.svg"} width="32" />
            <span class="text-lg font-bold">Tokengate</span>
          </a>
        </div>

        <nav class="flex-1 p-3 space-y-4">
          <div class="space-y-1">
            <.sidebar_link
              current_path={@current_path}
              href={~p"/dashboard"}
              label="Dashboard"
              icon="hero-chart-bar-square"
            />

            <%!-- Los no-admins que supervisan servicios entran a su vista de
                 solo lectura desde aquí (para admins el enlace es /access/services). --%>
            <%= if not admin?(@current_scope) and @supervised_count > 0 do %>
              <.sidebar_link
                current_path={@current_path}
                href={~p"/services/supervised"}
                label="Servicios supervisados"
                icon="hero-eye"
              />
            <% end %>

            <%= if admin?(@current_scope) do %>
              <.sidebar_link
                current_path={@current_path}
                href={~p"/stats"}
                label="Estadísticas"
                icon="hero-chart-pie"
              />
              <.sidebar_link
                current_path={@current_path}
                href={~p"/calculator"}
                label="Calculadora"
                icon="hero-calculator"
              />
            <% end %>
          </div>

          <%= if admin?(@current_scope) do %>
            <.sidebar_section id="sidebar-section-catalogo" label="Catálogo">
              <.sidebar_link
                current_path={@current_path}
                href={~p"/catalog/providers"}
                label="Proveedores"
                icon="hero-server-stack"
                badge={@alert_count}
              />
              <.sidebar_link
                current_path={@current_path}
                href={~p"/catalog/models"}
                label="Modelos"
                icon="hero-rectangle-stack"
              />
            </.sidebar_section>

            <.sidebar_section id="sidebar-section-acceso" label="Acceso">
              <.sidebar_link
                current_path={@current_path}
                href={~p"/access/groups"}
                label="Grupos"
                icon="hero-user-group"
              />
              <.sidebar_link
                current_path={@current_path}
                href={~p"/access/users"}
                label="Usuarios"
                icon="hero-users"
              />
              <.sidebar_link
                current_path={@current_path}
                href={~p"/access/services"}
                label="Servicios"
                icon="hero-wrench-screwdriver"
              />
            </.sidebar_section>

            <.sidebar_section id="sidebar-section-credito" label="Crédito">
              <.sidebar_link
                current_path={@current_path}
                href={~p"/credit/subscriptions"}
                label="Suscripciones"
                icon="hero-banknotes"
              />
              <.sidebar_link
                current_path={@current_path}
                href={~p"/credit/topups"}
                label="Top-ups"
                icon="hero-arrow-up-circle"
              />
            </.sidebar_section>

            <.sidebar_section id="sidebar-section-operaciones" label="Operaciones">
              <.sidebar_link
                current_path={@current_path}
                href={~p"/operations/monitoring"}
                label="Monitoring"
                icon="hero-signal"
              />
              <.sidebar_link
                current_path={@current_path}
                href={~p"/operations/observability"}
                label="Observabilidad"
                icon="hero-bell-alert"
              />
              <.sidebar_link
                current_path={@current_path}
                href={~p"/operations/maintenance"}
                label="Mantenimiento"
                icon="hero-cog-6-tooth"
              />
            </.sidebar_section>
          <% end %>
        </nav>

        <.timezone_selector current_scope={@current_scope} />
      </div>
    </aside>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp sidebar_section(assigns) do
    ~H"""
    <div class="space-y-1" id={@id}>
      <p class="px-3 text-xs font-semibold uppercase tracking-wide text-base-content/40">
        {@label}
      </p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :disabled, :boolean, default: false
  attr :badge, :integer, default: 0
  attr :current_path, :string, default: nil

  defp sidebar_link(assigns) do
    assigns =
      assigns
      |> assign(:active, active_path?(assigns.current_path, assigns.href))
      |> assign(:dom_id, "sidebar-link-" <> sidebar_link_id(assigns.href))

    ~H"""
    <.link
      href={@href}
      id={@dom_id}
      aria-current={if @active, do: "page", else: nil}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded-lg text-sm font-medium transition-colors",
        @disabled && "text-base-content/30 cursor-not-allowed pointer-events-none",
        not @disabled && @active && "bg-primary/10 text-primary",
        not @disabled && not @active &&
          "text-base-content/70 hover:bg-base-200 hover:text-base-content"
      ]}
    >
      <.icon name={@icon} class="w-5 h-5 shrink-0" />
      {@label}
      <span
        :if={@badge > 0}
        class="ml-auto badge badge-sm badge-error"
      >
        {@badge}
      </span>
    </.link>
    """
  end

  # A link is active on its own route and on any of its sub-routes, so
  # drill-downs keep the parent entry lit (e.g. /access/groups/42/members
  # highlights Grupos).
  defp active_path?(nil, _href), do: false

  defp active_path?(path, href) when is_binary(path) and is_binary(href) do
    path == href or String.starts_with?(path, href <> "/")
  end

  defp active_path?(_path, _href), do: false

  defp sidebar_link_id(href) do
    href
    |> String.trim_leading("/")
    |> String.replace("/", "-")
  end

  attr :current_scope, :map, default: nil

  defp timezone_selector(assigns) do
    tz = assigns.current_scope && assigns.current_scope.timezone

    assigns = Phoenix.Component.assign(assigns, :current_timezone, tz || "Etc/UTC")

    ~H"""
    <div class="px-3 pb-3 border-t border-base-300 pt-3" id="timezone-selector">
      <.form for={%{}} phx-change="set-timezone" id="tz-form">
        <label
          for="tz-select"
          class="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-base-content/40 mb-1.5"
        >
          <.icon name="hero-clock" class="w-4 h-4" /> Zona horaria
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

  defp role_label("admin"), do: "Administrador"
  defp role_label("user"), do: "Usuario"
  defp role_label(other), do: String.capitalize(other || "")

  defp admin?(%{global_role: "admin"}), do: true
  defp admin?(_), do: false

  # Solo importa "¿supervisa algo?": un count ligero evita cargar los
  # servicios (con su api_key) en cada render del sidebar.
  defp supervised_services_count(%{id: id}),
    do: Tokengate.Accounts.count_services_for_supervisor(id)

  defp supervised_services_count(_), do: 0

  defp initials(nil), do: "—"

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
