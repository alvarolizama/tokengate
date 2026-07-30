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

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8">
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

        <.dashboard_topbar current_scope={@current_scope} />

        <main class="flex-1 p-4 sm:p-6 lg:p-8">
          {render_slot(@inner_block)}
        </main>
      </div>

      <.dashboard_sidebar current_scope={@current_scope} />

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

      <.topbar_indicators current_scope={@current_scope} />

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

  # Live ops indicators: unattended alerts (error credentials + open
  # breakers), online dashboard users (Presence) and in-flight API requests.
  # Computed at render time — all reads are cheap (ETS/Registry + one COUNT).
  attr :current_scope, :map, default: nil

  defp topbar_indicators(assigns) do
    admin? = match?(%{global_role: "admin"}, assigns.current_scope)
    my_budget = my_budget_summary(assigns.current_scope)

    assigns =
      assigns
      |> assign(:error_creds, Tokengate.Providers.count_error_credentials())
      |> assign(:open_breakers, Tokengate.Routing.CircuitBreakerManager.count_open())
      |> assign(:budget_exhausted, if(admin?, do: Tokengate.Budgets.count_exhausted(), else: 0))
      |> assign(:online, length(TokengateWeb.Presence.list_online()))
      |> assign(:inflight, Tokengate.Limits.Manager.total_inflight())
      |> assign(:admin?, admin?)
      |> assign(:my_budget, my_budget)

    ~H"""
    <div class="hidden md:flex items-center gap-2" id="topbar-indicators">
      <span
        :if={@my_budget}
        id="topbar-my-budget"
        class={["badge badge-lg gap-1.5", my_budget_chip_class(@my_budget)]}
        title={my_budget_title(@my_budget)}
      >
        <.icon name="hero-wallet" class="w-3.5 h-3.5" />

        <span id="topbar-my-budget-daily" class="flex items-center gap-1">
          <span class="text-[0.65rem] opacity-60">H</span>
          <span>{@my_budget.daily_spend |> fmt_money_compact()}{if @my_budget.daily_limit,
            do: "/#{@my_budget.daily_limit |> fmt_money_compact()}",
            else: ""}</span>
          <%= if @my_budget.daily_limit do %>
            <span class="inline-block w-8 h-1 bg-base-300 rounded-full overflow-hidden">
              <span
                class={budget_bar_class(@my_budget.daily_pct)}
                style={"width: #{budget_bar_width(@my_budget.daily_pct)}%"}
              ></span>
            </span>
          <% end %>
        </span>

        <span class="opacity-40">·</span>

        <span id="topbar-my-budget-monthly" class="flex items-center gap-1">
          <span class="text-[0.65rem] opacity-60">M</span>
          <span>{@my_budget.monthly_spend |> fmt_money_compact()}</span>
          <%= if @my_budget.monthly_limit do %>
            <span class="inline-block w-8 h-1 bg-base-300 rounded-full overflow-hidden">
              <span
                class={budget_bar_class(@my_budget.monthly_pct)}
                style={"width: #{budget_bar_width(@my_budget.monthly_pct)}%"}
              ></span>
            </span>
            <span>{@my_budget.monthly_limit |> fmt_money_compact()}</span>
          <% end %>
        </span>
      </span>

      <%= if @admin? do %>
        <.link
          navigate={~p"/dashboard/alerts"}
          id="topbar-error-creds"
          class={[
            "badge badge-lg gap-1.5",
            if(@error_creds > 0, do: "badge-error", else: "badge-ghost")
          ]}
          title="Credenciales en error"
        >
          <.icon name="hero-key" class="w-3.5 h-3.5" />
          <span id="topbar-error-creds-count">{@error_creds}</span>
        </.link>

        <.link
          navigate={~p"/dashboard/alerts"}
          id="topbar-open-breakers"
          class={[
            "badge badge-lg gap-1.5",
            if(@open_breakers > 0, do: "badge-warning", else: "badge-ghost")
          ]}
          title="Circuit breakers abiertos"
        >
          <.icon name="hero-exclamation-triangle" class="w-3.5 h-3.5" />
          <span id="topbar-open-breakers-count">{@open_breakers}</span>
        </.link>

        <.link
          navigate={~p"/dashboard/credits"}
          id="topbar-budget-exhausted"
          class={[
            "badge badge-lg gap-1.5",
            if(@budget_exhausted > 0, do: "badge-error", else: "badge-ghost")
          ]}
          title="Miembros sin crédito (presupuesto agotado)"
        >
          <.icon name="hero-banknotes" class="w-3.5 h-3.5" />
          <span id="topbar-budget-exhausted-count">{@budget_exhausted}</span>
        </.link>
      <% end %>

      <span
        id="topbar-online-users"
        class="badge badge-lg badge-ghost gap-1.5"
        title="Usuarios conectados al dashboard"
      >
        <span class="relative flex h-2 w-2">
          <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-success opacity-60"></span>
          <span class="relative inline-flex rounded-full h-2 w-2 bg-success"></span>
        </span>
        <span id="topbar-online-count">{@online}</span>
      </span>

      <.link
        navigate={~p"/dashboard/logs"}
        id="topbar-inflight"
        class="badge badge-lg badge-ghost gap-1.5"
        title="Requests simultáneos en proceso"
      >
        <.icon name="hero-bolt" class="w-3.5 h-3.5 text-accent" />
        <span id="topbar-inflight-count">{@inflight}</span>
      </.link>
    </div>
    """
  end

  defp dashboard_sidebar(assigns) do
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
              <.sidebar_link href={~p"/dashboard/logs"} label="Logs" icon="hero-document-text" />
              <.sidebar_link
                href={~p"/dashboard/alerts"}
                label="Alertas"
                icon="hero-bell-alert"
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
    </.link>
    """
  end

  defp role_label("admin"), do: "Administrador"
  defp role_label("user"), do: "Usuario"
  defp role_label(other), do: String.capitalize(other || "")

  defp admin?(%{global_role: "admin"}), do: true
  defp admin?(_), do: false

  # --- Personal budget chip -------------------------------------------------
  # Every user sees THEIR OWN daily/monthly consumption vs effective limits.
  # A user may belong to several teams: the chip surfaces the membership
  # closest to exhaustion and the tooltip notes how many more there are.

  defp my_budget_summary(nil), do: nil

  defp my_budget_summary(user) do
    case Tokengate.Budgets.list_member_budgets_for_user(user.id) do
      [] ->
        nil

      [single] ->
        budget_summary(single, 0)

      many ->
        primary = Enum.max_by(many, &budget_severity/1)
        budget_summary(primary, length(many) - 1)
    end
  end

  # Ranks memberships by worst limit utilization so the chip surfaces the
  # one closest to exhaustion; unlimited ones rank below any limited one
  # and compare by raw daily spend.
  defp budget_severity(b) do
    worst = Enum.max([b.daily_pct || -1.0, b.monthly_pct || -1.0])
    {worst, Decimal.to_float(b.daily_spend_usd)}
  end

  defp budget_summary(b, extra_count) do
    worst_pct = Enum.max([b.daily_pct || 0.0, b.monthly_pct || 0.0])

    %{
      daily_spend: b.daily_spend_usd,
      monthly_spend: b.monthly_spend_usd,
      daily_limit: b.daily_limit_usd,
      monthly_limit: b.monthly_limit_usd,
      daily_pct: b.daily_pct,
      monthly_pct: b.monthly_pct,
      exhausted?: b.exhausted?,
      warning?: worst_pct >= 80.0,
      team_name: b.member.team && b.member.team.name,
      extra_count: extra_count
    }
  end

  defp my_budget_chip_class(%{exhausted?: true}), do: "badge-error"
  defp my_budget_chip_class(%{warning?: true}), do: "badge-warning"
  defp my_budget_chip_class(_), do: "badge-ghost"

  # Compact money format for the chip: $0.0230 → $0.02, $22.0000 → $22, $1500.50 → $1.5K
  defp fmt_money_compact(%Decimal{} = d) do
    f = Decimal.to_float(d)

    cond do
      f >= 1_000 ->
        "$#{:erlang.float_to_binary(f / 1_000, decimals: 1)}K"

      f == 0.0 ->
        "$0"

      true ->
        :erlang.float_to_binary(f, decimals: 4)
        |> String.replace(~r/\.?0+$/, "")
        |> then(&"$#{&1}")
    end
  end

  # Bar color by percentage: green < 60, warning 60-80, error > 80
  defp budget_bar_class(nil), do: "bg-base-content/30"
  defp budget_bar_class(pct) when pct >= 80.0, do: "bg-error"
  defp budget_bar_class(pct) when pct >= 60.0, do: "bg-warning"
  defp budget_bar_class(_), do: "bg-success"

  # Bar width: keep one decimal for small values, clamp 0-100
  defp budget_bar_width(nil), do: 0
  defp budget_bar_width(pct) when pct > 100.0, do: 100
  defp budget_bar_width(pct) when pct < 0.0, do: 0
  defp budget_bar_width(pct), do: Float.round(pct * 1.0, 1)

  defp my_budget_title(b) do
    daily = budget_period_title("Hoy", b.daily_spend, b.daily_limit, b.daily_pct)
    monthly = budget_period_title("Mes", b.monthly_spend, b.monthly_limit, b.monthly_pct)
    team = if b.team_name, do: " — #{b.team_name}", else: ""
    extra = if b.extra_count > 0, do: " (+#{b.extra_count} más)", else: ""

    daily <> " · " <> monthly <> team <> extra
  end

  defp budget_period_title(label, spend, nil, _pct),
    do: "#{label}: $#{fmt_money(spend)} (sin límite)"

  defp budget_period_title(label, spend, limit, pct),
    do: "#{label}: $#{fmt_money(spend)} de $#{fmt_money(limit)} (#{pct}%)"

  defp fmt_money(%Decimal{} = d) do
    d
    |> Decimal.round(4)
    |> Decimal.to_string()
  end

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
