defmodule TokengateWeb.ServiceStatsLive do
  @moduledoc """
  Admin-only consolidated stats page for a **service**, aggregating its
  request logs (services carry `service_id`, not `group_member_id`).

  Mirror of `UserStatsLive` for the service subject: aggregated stat cards
  (requests, cost, tokens, top models, status breakdown, last request) and a
  paginated stream of the service's recent logs. Real-time updates via the
  same `logs:new` PubSub as `/logs`.

  Path: `/stats/services/:service_id`

  El cuerpo de stats (selector de key, KPIs, tabla de API keys, pivote modelo ×
  key, filtros y tabla de logs) vive en `TokengateWeb.ServiceStatsBody`, que es
  también el que usa la vista supervisada: este módulo sólo se queda con el
  header, el hook de admin, el periodo por URL y el realtime.

  Admin-only by router; defense-in-depth `require_admin_hook/1` rejects event
  traffic from non-admins (a malicious client could otherwise fire events
  directly over the WebSocket).
  """

  use TokengateWeb, :live_view
  alias Tokengate.Accounts
  alias TokengateWeb.ServiceStatsBody
  alias TokengateWeb.StatsHelpers

  @page_size 50
  @summary_refresh_interval_ms 2_000

  # Selector global de periodo: maneja los KPIs, el desglose, los top models
  # y la tabla de keys — una sola ventana por consulta. El periodo viaja en la
  # URL (?period=) con el set canónico de /stats; las bounds vienen SIEMPRE de
  # Periods.period_bounds/2 (fuente única — nada de period_from local).
  @default_period "week"

  @impl true
  def mount(%{"service_id" => service_id} = params, _session, socket) do
    service = Accounts.get_service!(service_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "logs:new")
    end

    socket =
      socket
      |> assign(:page_title, gettext("Stats") <> " · #{service.name} · Tokengate")
      |> assign(:service, service)
      # Todas las keys del servicio (activas y revocadas, más recientes
      # primero) — la fuente de las filas de la tabla de API keys.
      |> assign(:service_api_keys, Accounts.list_api_keys_for_service_all(service_id))
      |> assign(:key_filter, "all")
      |> assign(:key_filter_form, to_form(%{"key_id" => "all"}, as: :key_filter))
      # El ?period= del deep-link llega a mount: respetarlo aquí evita el
      # doble service_stats (mount con el default + handle_params corrigiendo).
      |> assign(:period, parse_period(params["period"]))
      |> assign(:timezone, socket.assigns[:timezone] || "Etc/UTC")
      |> assign(:is_admin, socket.assigns[:current_user].global_role == "admin")
      |> assign(:filters, ServiceStatsBody.default_filters())
      |> assign(:form, to_form(ServiceStatsBody.default_filters(), as: :filter))
      |> assign(:cursor, nil)
      |> assign(:has_more, false)
      |> assign(:page_size, @page_size)
      |> assign(:summary, ServiceStatsBody.default_summary())
      |> assign(:key_rows, [])
      |> assign(:model_breakdown, %{rows: [], key_labels: %{}})
      |> assign(:summary_refresh_scheduled, false)
      |> require_admin_hook()
      |> ServiceStatsBody.load_stats()
      |> ServiceStatsBody.load_logs(:reset)

    {:ok, socket}
  end

  defp require_admin_hook(socket) do
    attach_hook(socket, :require_admin, :handle_event, fn _event, _params, socket ->
      if socket.assigns[:is_admin] do
        {:cont, socket}
      else
        {:halt, put_flash(socket, :error, "No autorizado.")}
      end
    end)
  end

  ## Real-time -------------------------------------------------------------

  @impl true
  def handle_info({:new_log, log}, socket) do
    if log.service_id == socket.assigns.service.id do
      timezone = socket.assigns.timezone
      filters = socket.assigns.filters

      if ServiceStatsBody.log_matches_filters?(
           log,
           filters,
           timezone,
           socket.assigns.key_filter
         ) do
        socket = stream_insert(socket, :logs, log, at: 0)

        # Coalesce summary reloads: at most one service_stats recompute per
        # interval per connected LiveView, regardless of broadcast rate.
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

  ## Events ----------------------------------------------------------------

  @impl true
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

  # Selector de key del reporte: "all" (todas, revocadas incluidas) o el id de
  # una key del servicio. Con una key específica, summary/desglose/top models
  # se scopean por `api_key_id` (Logs.service_stats/2), la tabla muestra sólo
  # esa fila y la lista de logs se refiltra. Ids que no son del servicio se
  # ignoran (payload manual por el socket).
  #
  # El form serializa anidado (as: :key_filter → name="key_filter[key_id]").
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

  # El periodo viaja en la URL (?period=): el selector (botones patch) llega
  # aquí y handle_params es el único punto de carga. Sin handle_event de
  # periodo.
  @impl true
  def handle_params(params, _uri, socket) do
    period = parse_period(params["period"])

    if period == socket.assigns.period do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:period, period)
       |> ServiceStatsBody.load_stats()
       |> ServiceStatsBody.load_logs(:reset)}
    end
  end

  defp parse_period(period) do
    if period in StatsHelpers.canonical_periods(),
      do: period,
      else: @default_period
  end

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_user}
      impersonator={@impersonator}
      current_path={@current_path}
    >
      <div class="space-y-6">
        <%!-- Header --%>
        <header class="flex flex-wrap items-start justify-between gap-6 pb-4">
          <div>
            <div class="flex items-center gap-2 text-xs text-base-content/60">
              <.link navigate={~p"/stats/services"} class="hover:underline">{gettext("Services")}</.link>
              <span>›</span>
              <span>{gettext("Detail")}</span>
            </div>
            <h1 class="text-lg font-semibold leading-8 mt-1">
              {@service.name}
            </h1>
            <p class="text-sm text-base-content/70">
              Presupuesto: {ServiceStatsBody.limit_label(@service)}
            </p>
          </div>
        </header>

        <ServiceStatsBody.panel
          service={@service}
          service_api_keys={@service_api_keys}
          key_filter_form={@key_filter_form}
          summary={@summary}
          key_rows={@key_rows}
          model_breakdown={@model_breakdown}
          period={@period}
          period_target={~p"/stats/services/#{@service.id}"}
          timezone={@timezone}
          form={@form}
          streams={@streams}
          has_more={@has_more}
        />
      </div>
    </Layouts.dashboard>
    """
  end
end
