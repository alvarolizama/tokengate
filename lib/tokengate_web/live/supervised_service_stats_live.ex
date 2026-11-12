defmodule TokengateWeb.SupervisedServiceStatsLive do
  @moduledoc """
  Full read-only stats for **one** supervised service.

  This is the drill-down of `/services/supervised`: the summary card answers
  "how is this service doing?" in one line, and this page answers "what exactly
  happened?" — the same stats body the admin sees at `/stats/services/:id`
  (API key selector, KPI strip, per-key table, model × key pivot, log filters
  and request stream), plus the read-only configuration (API key prefix,
  limits, granted models) and who else supervises it.

  El cuerpo de stats vive en `TokengateWeb.ServiceStatsBody` — una sola fuente
  de markup, carga y helpers para las dos vistas. Este módulo sólo se queda con
  el header, el badge de solo lectura, el acceso por supervisión y el realtime.

  ## Access

  Nothing but a live `service_supervisors` row for **this** service opens this
  page: neither a global role nor supervising a *different* service is enough.
  The check runs on every mount (socket reconnects included), and an open view
  navigates away the instant the row is removed — `Accounts.remove_service_supervisor/2`
  broadcasts `{:supervisor_removed, service_id}` on
  `Accounts.supervised_services_topic/1`.

  ## Read-only contract

  Same as the list view: no mutation callback exists, and the `:read_only` hook
  halts every event except the read-only allowlist (`load_more` pagination, the
  app-wide `set-timezone` selector and the two view-only filters of the shared
  body: `set_key` and `filter`). The period is switched through `patch`
  navigation, which does not go through events at all.
  """

  use TokengateWeb, :live_view

  alias Tokengate.Accounts
  alias Tokengate.Providers
  alias Tokengate.Repo
  alias TokengateWeb.ServiceStatsBody

  import TokengateWeb.StatsHelpers, only: [period_label: 1]

  @default_period "30d"
  @page_size 25
  @summary_refresh_interval_ms 2_000

  # Events that do not touch service state and stay allowed on a read-only
  # page: pagination, the app-wide timezone selector and the view-only filters
  # of the shared stats body (key scope + log filters). Everything else is
  # halted by the hook.
  @allowed_events ["load_more", "set-timezone", "set_key", "filter"]

  @impl true
  def mount(%{"service_id" => service_id}, _session, socket) do
    user = socket.assigns.current_user

    case Accounts.get_service(service_id) do
      nil ->
        {:ok, deny(socket, gettext("That service does not exist."))}

      service ->
        if Accounts.supervises_service?(user.id, service.id) do
          if connected?(socket) do
            Phoenix.PubSub.subscribe(
              Tokengate.PubSub,
              Accounts.supervised_services_topic(user.id)
            )

            # Same realtime feed as the admin view: new requests land in the
            # stream and coalesce a summary recompute.
            Phoenix.PubSub.subscribe(Tokengate.PubSub, "logs:new")
          end

          granted_models = Providers.granted_models_by_service([service.id])

          {:ok,
           socket
           |> assign(:denied?, false)
           |> assign(:page_title, "Stats · #{service.name} · Tokengate")
           |> assign(:service, Repo.preload(service, [:api_key]))
           |> assign(:granted_models, granted_models)
           |> assign(
             :models,
             granted_models |> Map.values() |> List.flatten() |> Providers.models_by_ids()
           )
           |> assign(:supervisors, Accounts.service_supervisors(service.id))
           |> assign(:period, @default_period)
           |> assign(:timezone, socket.assigns[:timezone] || "Etc/UTC")
           # Todas las keys del servicio (revocadas incluidas) — la fuente de
           # las filas de la tabla de API keys del cuerpo compartido.
           |> assign(:service_api_keys, Accounts.list_api_keys_for_service_all(service.id))
           |> assign(:key_filter, "all")
           |> assign(:key_filter_form, to_form(%{"key_id" => "all"}, as: :key_filter))
           |> assign(:summary, ServiceStatsBody.default_summary())
           |> assign(:key_rows, [])
           |> assign(:model_breakdown, %{rows: [], key_labels: %{}})
           |> assign(:filters, ServiceStatsBody.default_filters())
           |> assign(:form, to_form(ServiceStatsBody.default_filters(), as: :filter))
           |> assign(:cursor, nil)
           |> assign(:has_more, false)
           |> assign(:page_size, @page_size)
           |> assign(:summary_refresh_scheduled, false)
           |> attach_read_only_hook()}
        else
          {:ok, deny(socket, gettext("You do not supervise that service."))}
        end
    end
  end

  ## No supervisor row for this service → no detail. The page renders a denied
  ## placeholder (so the dead render is always valid) and sends the client back
  ## to the supervised list, where the hook decides whether the user still has
  ## anything to see at all.
  defp deny(socket, message) do
    socket
    |> assign(:denied?, true)
    |> assign(:page_title, gettext("No access") <> " · Tokengate")
    |> put_flash(:error, message)
    |> push_navigate(to: ~p"/services/supervised")
  end

  defp attach_read_only_hook(socket) do
    attach_hook(socket, :read_only, :handle_event, fn event, _params, socket ->
      if event in @allowed_events do
        {:cont, socket}
      else
        {:halt, put_flash(socket, :error, gettext("This view is read-only."))}
      end
    end)
  end

  ## Params / period ------------------------------------------------------

  @impl true
  def handle_params(params, _uri, socket) do
    if socket.assigns.denied? do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:period, parse_period(params["period"]))
       |> load_bundle()}
    end
  end

  defp parse_period(period) do
    if period in TokengateWeb.StatsHelpers.canonical_periods(), do: period, else: @default_period
  end

  ## Revocation -----------------------------------------------------------

  ## Removing the user as supervisor of this service closes the page: the
  ## detail exists only while the row does.
  @impl true
  def handle_info({:supervisor_removed, service_id}, socket) do
    if socket.assigns.service.id == service_id do
      {:noreply,
       socket
       |> put_flash(:error, gettext("You no longer supervise this service."))
       |> push_navigate(to: ~p"/services/supervised")}
    else
      {:noreply, socket}
    end
  end

  ## Real-time -------------------------------------------------------------

  ## Same feed and coalescing as the admin view: only logs of THIS service that
  ## pass the active filters/key scope enter the stream, and at most one
  ## summary recompute per interval per connected LiveView.
  def handle_info({:new_log, log}, socket) do
    if log.service_id == socket.assigns.service.id and
         ServiceStatsBody.log_matches_filters?(
           log,
           socket.assigns.filters,
           socket.assigns.timezone,
           socket.assigns.key_filter
         ) do
      socket = stream_insert(socket, :logs, log, at: 0)

      socket =
        if socket.assigns[:summary_refresh_scheduled] do
          socket
        else
          Process.send_after(self(), :refresh_summary, @summary_refresh_interval_ms)
          assign(socket, :summary_refresh_scheduled, true)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_summary, socket) do
    {:noreply,
     socket
     |> assign(:summary_refresh_scheduled, false)
     |> ServiceStatsBody.load_stats()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events ---------------------------------------------------------------

  @impl true
  def handle_event("set_key", %{"key_filter" => %{"key_id" => key_id}}, socket) do
    known_ids = MapSet.new(socket.assigns.service_api_keys, & &1.id)

    if key_id == "all" or MapSet.member?(known_ids, key_id) do
      {:noreply,
       socket
       |> assign(:key_filter, key_id)
       |> assign(:key_filter_form, to_form(%{"key_id" => key_id}, as: :key_filter))
       |> ServiceStatsBody.load_stats()
       |> ServiceStatsBody.load_logs(:reset)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_key", _params, socket), do: {:noreply, socket}

  def handle_event("filter", params, socket) do
    filter_params =
      params
      |> Map.get("filter", %{})
      |> then(&Map.merge(ServiceStatsBody.default_filters(), &1))

    socket =
      socket
      |> assign(:filters, filter_params)
      |> assign(:form, to_form(filter_params, as: :filter))
      |> assign(:cursor, nil)
      |> ServiceStatsBody.load_logs(:reset)

    {:noreply, socket}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more do
      {:noreply, ServiceStatsBody.load_logs(socket, :more)}
    else
      {:noreply, socket}
    end
  end

  ## Data loading ---------------------------------------------------------

  defp load_bundle(socket) do
    socket
    |> ServiceStatsBody.load_stats()
    |> ServiceStatsBody.load_logs(:reset)
  end

  ## Template helpers -----------------------------------------------------

  defp limit_label(%{unlimited_spend: true}), do: gettext("Unlimited credit")

  defp limit_label(%{monthly_spend_limit_usd: %Decimal{} = limit}),
    do: gettext("Cap $%{amount}/month", amount: Decimal.to_string(limit))

  defp limit_label(_service), do: gettext("No budget") <> " " <> gettext("(top-ups only)")

  defp supervisor_label(%{user: %{name: name, email: email}}) when is_binary(name),
    do: "#{name} · #{email}"

  defp supervisor_label(%{user: %{email: email}}), do: email
  defp supervisor_label(_), do: "—"

  ## Render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_user}
      impersonator={@impersonator}
      current_path={@current_path}
    >
      <div
        :if={@denied?}
        id="supervised-service-denied"
        class="card bg-base-100 border border-base-300"
      >
        <div class="card-body items-center text-center py-12">
          <.icon name="hero-lock-closed" class="w-12 h-12 text-base-content/30" />
          <h3 class="text-lg font-semibold mt-2">{gettext("No access to this service.")}</h3>
        </div>
      </div>

      <div :if={not @denied?} class="space-y-6">
        <header class="flex flex-wrap items-start justify-between gap-4 pb-4">
          <div>
            <div class="flex items-center gap-2 text-xs text-base-content/60">
              <.link navigate={~p"/services/supervised"} class="hover:underline">
                {gettext("Supervised services")}
              </.link>
              <span>›</span>
              <span>{gettext("Full stats")}</span>
            </div>
            <h1 class="text-lg font-semibold leading-8 mt-1 flex items-center gap-2">
              {@service.name}
              <span class="badge badge-ghost badge-sm" id="supervised-service-readonly">
                <.icon name="hero-eye" class="w-3 h-3 mr-1" /> Solo lectura
              </span>
            </h1>
            <p class="text-sm text-base-content/70">
              Presupuesto: {limit_label(@service)} · {period_label(@period)}
            </p>
          </div>
        </header>

        <%!-- Stats body shared with the admin view: key selector, KPIs, per-key
        table, model × key pivot, log filters and the request stream. --%>
        <ServiceStatsBody.panel
          service={@service}
          service_api_keys={@service_api_keys}
          key_filter_form={@key_filter_form}
          summary={@summary}
          key_rows={@key_rows}
          model_breakdown={@model_breakdown}
          period={@period}
          period_target={~p"/services/supervised/#{@service.id}"}
          timezone={@timezone}
          form={@form}
          streams={@streams}
          has_more={@has_more}
          logs_id="supervised-service-logs"
          logs_empty_text={gettext("This service has no requests yet.")}
          load_more_id="load-more-supervised-logs"
          show_service_summary={false}
          compact_numbers={true}
        />

        <%!-- Read-only configuration --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm" id="service-config">
          <div class="card-body p-4 gap-3">
            <h2 class="card-title text-base">
              <.icon name="hero-wrench-screwdriver" class="w-5 h-5 text-base-content/60" />
              {gettext("Configuration (read-only)")}
            </h2>

            <dl class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 text-sm">
              <div class="rounded-xl border border-base-300 px-3 py-2">
                <dt class="text-[10px] uppercase tracking-wide text-base-content/60">API key</dt>
                <dd class="mt-1 flex items-center gap-2">
                  <%= if @service.api_key do %>
                    <span class="font-mono">{@service.api_key.key_prefix}…</span>
                    <span class={[
                      "badge badge-xs",
                      if(@service.api_key.status == "active",
                        do: "badge-success",
                        else: "badge-error"
                      )
                    ]}>
                      {@service.api_key.status}
                    </span>
                  <% else %>
                    <span class="text-base-content/40">{gettext("No key")}</span>
                  <% end %>
                </dd>
              </div>

              <div class="rounded-xl border border-base-300 px-3 py-2">
                <dt class="text-[10px] uppercase tracking-wide text-base-content/60">
                  {gettext("Concurrency")}
                </dt>
                <dd class="mt-1 font-mono">{@service.concurrency_limit || 5}</dd>
              </div>

              <div class="rounded-xl border border-base-300 px-3 py-2">
                <dt class="text-[10px] uppercase tracking-wide text-base-content/60">
                  {gettext("RPM")}
                </dt>
                <dd class="mt-1 font-mono">{@service.rpm_limit || 60}</dd>
              </div>

              <div class="rounded-xl border border-base-300 px-3 py-2">
                <dt class="text-[10px] uppercase tracking-wide text-base-content/60">
                  {gettext("Credit")}
                </dt>
                <dd class="mt-1">{limit_label(@service)}</dd>
              </div>
            </dl>

            <div class="flex flex-wrap items-center gap-2">
              <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                {gettext("Allowed models")}
              </span>
              <div class="flex flex-wrap gap-2" id={"models-#{@service.id}"}>
                <%= if model_names_for(@granted_models, @service.id, @models) == [] do %>
                  <span class="text-xs text-base-content/40">
                    {gettext("This service has no models assigned.")}
                  </span>
                <% else %>
                  <span
                    :for={model <- model_names_for(@granted_models, @service.id, @models)}
                    id={"model-badge-#{@service.id}-#{model.id}"}
                    class="badge badge-primary badge-sm"
                  >
                    {model.name}
                  </span>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <%!-- Who else supervises it --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm" id="service-supervisors">
          <div class="card-body p-4 gap-2">
            <h3 class="card-title text-sm">{gettext("Service supervisors")}</h3>
            <ul class="space-y-1">
              <li
                :for={supervisor <- @supervisors}
                id={"service-supervisor-#{supervisor.user_id}"}
                class="flex items-center gap-2 text-sm"
              >
                <.icon name="hero-user" class="w-4 h-4 text-base-content/40" />
                <span class="truncate">{supervisor_label(supervisor)}</span>
              </li>
            </ul>
            <p class="text-xs text-base-content/40">
              {gettext("The assignment is managed by an administrator from Services.")}
            </p>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end

  defp model_names_for(granted_models, service_id, all_models) do
    Map.get(granted_models, service_id, [])
    |> Enum.map(&Enum.find(all_models, fn a -> a.id == &1 end))
    |> Enum.reject(&is_nil/1)
  end
end
