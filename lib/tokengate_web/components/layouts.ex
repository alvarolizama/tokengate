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
            <.theme_toggle />
          </li>
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
  Renders the dashboard (ops console) layout — a dark, premium sidebar +
  topbar shell used by authenticated LiveViews (DashboardLive, future
  admin LiveViews).

  ## Examples

      <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
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

      <.dashboard_sidebar current_scope={@current_scope} alert_count={@alert_count} />

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

        <div class="avatar avatar-placeholder">
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

  defp dashboard_sidebar(assigns) do
    assigns =
      if admin?(assigns.current_scope) do
        timezone = "Etc/UTC"
        creds = Tokengate.Providers.count_error_credentials()
        breakers = Tokengate.Routing.CircuitBreakerManager.count_open()
        budgets = Tokengate.Budgets.count_exhausted(timezone)
        assign(assigns, :alert_count, creds + breakers + budgets)
      else
        assigns
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
          <.sidebar_link href={~p"/dashboard"} label="Dashboard" icon="hero-chart-bar-square" />

          <%= if admin?(@current_scope) do %>
            <.sidebar_link href={~p"/dashboard/stats"} label="Estadísticas" icon="hero-chart-pie" />

            <div class="space-y-1">
              <p class="px-3 text-xs font-semibold uppercase tracking-wide text-base-content/40">
                Configuración
              </p>
              <.sidebar_link
                href={~p"/dashboard/providers"}
                label="Proveedores"
                icon="hero-server-stack"
              />
              <.sidebar_link
                href={~p"/dashboard/models"}
                label="Modelos"
                icon="hero-rectangle-stack"
              />
              <.sidebar_link href={~p"/dashboard/teams"} label="Equipos" icon="hero-user-group" />
              <.sidebar_link
                href={~p"/dashboard/services"}
                label="Servicios"
                icon="hero-wrench-screwdriver"
              />
            </div>

            <div class="space-y-1">
              <p class="px-3 text-xs font-semibold uppercase tracking-wide text-base-content/40">
                Acceso
              </p>
              <.sidebar_link href={~p"/dashboard/users"} label="Usuarios" icon="hero-users" />
            </div>

            <div class="space-y-1">
              <p class="px-3 text-xs font-semibold uppercase tracking-wide text-base-content/40">
                Monitoreo
              </p>
              <.sidebar_link
                href={~p"/dashboard/credits"}
                label="Créditos"
                icon="hero-banknotes"
              />
              <.sidebar_link
                href={~p"/dashboard/logs"}
                label="Logs"
                icon="hero-document-text"
                badge={@alert_count}
              />
            </div>

            <div class="space-y-1">
              <p class="px-3 text-xs font-semibold uppercase tracking-wide text-base-content/40">
                Sistema
              </p>
              <.sidebar_link
                href={~p"/dashboard/settings"}
                label="Configuración"
                icon="hero-cog-6-tooth"
              />
            </div>
          <% end %>
        </nav>

        <.timezone_selector current_scope={@current_scope} />

        <div class="p-3 border-t border-base-300">
          <p class="text-xs text-base-content/40 px-3">
            v{Application.spec(:tokengate, :vsn) |> to_string()}
          </p>
        </div>
      </div>
    </aside>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :disabled, :boolean, default: false
  attr :badge, :integer, default: 0

  defp sidebar_link(assigns) do
    ~H"""
    <.link
      href={@href}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded-lg text-sm font-medium transition-colors",
        @disabled && "text-base-content/30 cursor-not-allowed pointer-events-none",
        not @disabled && "text-base-content/70 hover:bg-base-200 hover:text-base-content"
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

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
