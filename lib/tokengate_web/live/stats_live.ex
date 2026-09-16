defmodule TokengateWeb.StatsLive do
  @moduledoc """
  Analytics dashboard with drill-down by model, user and group.

  Views via `live_action`:
    * `:live`    — real-time overview (no period selector)
    * `:index`   — period overview: contadores del período (con deltas) +
      perfil horario / modelo × proveedor
    * `:models`  — per-model breakdown + drill-down (provider, user, group)
    * `:model`   — one model's hub: metrics, who serves it, who uses it
    * `:services` — per-service breakdown + drill-down (models)
    * `:groups`  — per-group list
    * `:group`   — one group's hub: members, models, daily series
    * `:providers` — provider ranking table
    * `:provider` — one provider's hub: metrics, models served, who uses it
    * `:users`   — per-user consolidated breakdown (all memberships)
    * `:credits` — budgets (calendar counters, no period)

  Periods: Hoy, Esta semana, Este mes, 30d, 90d (all but :live/:credits).

  Scoping by role:
    * admin   — org-wide
    * manager — only groups they manage
    * user    — only their own consumption

  CSV export available via `/stats/export` controller.
  """
  use TokengateWeb, :live_view

  alias Tokengate.Accounts
  alias Tokengate.Budgets
  alias Tokengate.Logs
  alias Tokengate.Logs.Inflight
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Metrics.StatsQueries
  alias Tokengate.Periods
  import TokengateWeb.StatsLive.Index, only: [index: 1]
  import TokengateWeb.StatsLive.Models, only: [models: 1]
  import TokengateWeb.StatsLive.Model, only: [model: 1]
  import TokengateWeb.StatsLive.Groups, only: [groups: 1]
  import TokengateWeb.StatsLive.Services, only: [services: 1]
  import TokengateWeb.StatsLive.Users, only: [users: 1]
  import TokengateWeb.StatsLive.Providers, only: [providers: 1]
  import TokengateWeb.StatsLive.Provider, only: [provider: 1]
  import TokengateWeb.StatsLive.LiveSection, only: [live: 1]

  import TokengateWeb.StatsHelpers,
    only: [period_label: 1, period_active?: 2, sort_rows: 3]

  alias TokengateWeb.StatsHelpers, as: Stats

  # Breakdown assigns whose tables have sortable column headers. The "sort"
  # event re-orders these in memory — see resort_breakdowns/3.
  # Credits tab: budgets reload cadence after a `logs:new` broadcast (same
  # rationale as the old CreditsLive — see its comment block).
  @reload_interval_ms 3_000

  # "En vivo" tab: cadence of the periodic realtime refresh (matching
  # MonitoringLive's inflight cadence).
  @live_refresh_interval_ms 3_000

  # "En vivo" feed: how many recent requests to show.
  @live_feed_size 20

  @sortable_breakdowns [
    :breakdown_model,
    :breakdown_member,
    :breakdown_group,
    :breakdown_provider,
    :breakdown_service,
    :breakdown_user,
    :member_models
  ]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Estadísticas · Tokengate")
      |> assign(:period, "today")
      |> assign(:model_filter, nil)
      |> assign(:group_filter, nil)
      |> assign(:service_filter, nil)
      |> assign(:scope_label, scope_label_for(user))
      |> assign(:scope_member_ids, Accounts.scope_member_ids(user))
      |> assign(:group_id, nil)
      |> assign(:sort_field, :request_count)
      |> assign(:sort_direction, :desc)
      |> assign(:list_search, "")
      |> assign(:stats_loading, true)
      |> assign(:per_page, 10)
      |> assign(:shown_counts, %{})
      |> assign(:reload_scheduled, false)
      |> assign_budget_reset()
      |> assign(empty_data_assigns())

    socket =
      if connected?(socket) do
        socket
      else
        # The "En vivo" template reads @streams.live_feed; register the
        # stream so the static (pre-connect) render has the assign.
        stream(socket, :live_feed, [], reset: true)
      end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "logs:new")
      # Realtime pulse for the "En vivo" tab (broadcast per proxied request
      # by Metrics.Collector) + periodic tick so the page ages gracefully.
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "metrics:updated")
      schedule_clock_tick()
      send(self(), :live_tick)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period = parse_period(params["period"])
    model_filter = params["model_id"]
    group_filter = params["group_id"]
    service_filter = params["service_id"]
    # :group action carries the group in the URL path; the other actions
    # clear it (drill-downs keep using ?group_id=).
    group_id =
      case socket.assigns.live_action do
        :group -> params["group_id"] || socket.assigns[:group_id]
        _ -> params["group_id"]
      end

    # :provider carries the provider in the URL path (/stats/providers/:id).
    provider_id =
      case socket.assigns.live_action do
        :provider -> params["provider_id"]
        _ -> nil
      end

    socket =
      socket
      |> assign(:period, period)
      |> assign(:model_filter, model_filter)
      |> assign(:group_filter, group_filter)
      |> assign(:service_filter, service_filter)
      |> assign(:group_id, group_id)
      |> assign(:provider_id, provider_id)
      # Cada sección tiene su propio listado: el filtro de la anterior no
      # aplica y escondería filas sin que se vea por qué.
      |> assign(:list_search, "")

    socket =
      case socket.assigns.live_action do
        :live -> load_live_data(socket)
        _ -> start_data_load(socket)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_period", %{"period" => period}, socket)
      when period in ~w(today week month 30d 90d) do
    {:noreply, socket |> assign(:period, period) |> start_data_load()}
  end

  # Buscador de los listados rankeados (Users, Models, Providers). El texto
  # vive en el socket y las secciones filtran sus propias filas en el render:
  # no toca la DB ni las claves del DashboardCache.
  def handle_event("filter_list", %{"value" => query}, socket) do
    {:noreply, assign(socket, :list_search, query || "")}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    field = String.to_existing_atom(field)

    {sort_field, sort_direction} =
      if socket.assigns.sort_field == field do
        {field, toggle_direction(socket.assigns.sort_direction)}
      else
        {field, :desc}
      end

    {:noreply,
     socket
     |> assign(:sort_field, sort_field)
     |> assign(:sort_direction, sort_direction)
     |> resort_breakdowns(sort_field, sort_direction)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, start_data_load(socket)}
  end

  # "Ver más" de los listados largos: Créditos (una clave por grupo) y los
  # detalles de proveedor y modelo (una clave por tabla). El conteo desplegado
  # vive en `shown_counts`, así que cada listado se despliega por su cuenta sin
  # recargar ni volver a consultar: las filas ya están en memoria.
  def handle_event("show_more", %{"key" => key}, socket) do
    {:noreply, show_more(socket, key)}
  end

  def handle_event("show_more", %{"group-id" => group_id}, socket) do
    {:noreply, show_more(socket, group_id)}
  end

  defp show_more(socket, key) do
    shown = Map.get(socket.assigns.shown_counts, key, socket.assigns.per_page)

    assign(
      socket,
      :shown_counts,
      Map.put(socket.assigns.shown_counts, key, shown + socket.assigns.per_page)
    )
  end

  defp toggle_direction(:asc), do: :desc
  defp toggle_direction(:desc), do: :asc

  # Re-apply sort_rows to every breakdown list already loaded in the socket.
  # Sorting is client-side over the current period's rows — no need to hit the
  # DB again. Only assigns that exist are touched (each live_action loads a
  # different subset).
  defp resort_breakdowns(socket, field, direction) do
    Enum.reduce(@sortable_breakdowns, socket, fn key, acc ->
      case acc.assigns[key] do
        nil -> acc
        rows -> assign(acc, key, sort_rows(rows, field, direction))
      end
    end)
  end

  ## Data loading ---------------------------------------------------------

  # Kick off an async data load. The socket renders right away with the
  # previous period's data (or empty values on first mount) plus an inline
  # loading indicator; when every query finishes, the new data lands in one
  # diff via handle_info/2. Switching periods quickly cancels the in-flight
  # load automatically.
  defp start_data_load(socket) do
    params = data_params(socket.assigns)

    socket =
      case params.live_action do
        :index ->
          # El Resumen se parte en dos cargas: los contadores (resumen del
          # período + el anterior → deltas) y los agregados estructurales
          # (perfil horario, modelo×proveedor, picos y el sweep de
          # concurrencia). Sólo los contadores se recargan con `logs:new`;
          # lo estructural espera a un cambio de período, un refresh o un
          # cambio de pestaña. Las demás pestañas conservan su bundle único.
          socket
          |> start_async(:stats_counters, fn -> compute_counter_assigns(params) end)
          |> start_async(:stats_data, fn -> compute_structural_assigns(params) end)

        _ ->
          start_async(socket, :stats_data, fn -> compute_data_assigns(params) end)
      end

    assign(socket, :stats_loading, true)
  end

  # Recarga de contadores del Resumen, sin la parte estructural: la usa el
  # broadcast `logs:new` (ver handle_info/2).
  defp start_counters_load(socket) do
    params = data_params(socket.assigns)

    start_async(socket, :stats_counters, fn -> compute_counter_assigns(params) end)
  end

  # Params de una carga: el socket ya trae todo lo que los loaders necesitan.
  defp data_params(assigns) do
    %{
      user: assigns.current_user,
      period: assigns.period,
      model_filter: assigns.model_filter,
      group_filter: assigns.group_filter,
      service_filter: assigns.service_filter,
      group_id: assigns.group_id,
      provider_id: assigns[:provider_id],
      scope_member_ids: assigns.scope_member_ids,
      live_action: assigns.live_action,
      timezone: assigns[:timezone] || "Etc/UTC",
      sort_field: assigns.sort_field,
      sort_direction: assigns.sort_direction
    }
  end

  @impl true
  def handle_async(:stats_data, {:ok, data}, socket) do
    socket =
      socket
      |> assign(:stats_loading, false)
      |> assign(empty_structural_assigns(socket.assigns.live_action))
      |> assign(data)

    {:noreply, socket}
  end

  def handle_async(:stats_data, {:exit, reason}, socket) do
    require Logger
    Logger.warning("stats data load failed: #{inspect(reason)}")

    {:noreply, assign(socket, :stats_loading, false)}
  end

  # Los contadores del Resumen llegan en su propia tarea y se aplican solos:
  # no tocan `stats_loading` (quien la apaga es la parte estructural, que es
  # la pesada) ni pisan el resto de los assigns.
  def handle_async(:stats_counters, {:ok, data}, socket) do
    {:noreply, assign(socket, data)}
  end

  def handle_async(:stats_counters, {:exit, reason}, socket) do
    require Logger
    Logger.warning("stats counters load failed: #{inspect(reason)}")

    {:noreply, socket}
  end

  # `logs:new` broadcast — route by tab:
  #   * live: prepend to the feed + refresh the pulse
  #   * overview: coalesce into a counters-only reload (KPIs y deltas);
  #     los agregados estructurales NO se re-ejecutan acá
  @impl true
  def handle_info({:new_log, log}, socket) do
    case socket.assigns.live_action do
      :live ->
        {:noreply,
         socket
         |> stream_insert(:live_feed, log, at: 0, limit: @live_feed_size)
         |> assign(:pulse, Logs.realtime_summary(%{}))
         |> assign(:last_sync_at, DateTime.utc_now())}

      :index ->
        if not socket.assigns.reload_scheduled do
          Process.send_after(self(), :reload_counters, @reload_interval_ms)
          {:noreply, assign(socket, :reload_scheduled, true)}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # Recarga coalescida del Resumen: sólo los contadores que el broadcast
  # invalida. Los agregados estructurales — perfil horario, modelo×proveedor,
  # minutos/horas pico y el sweep de concurrencia — son scans crudos de toda
  # la ventana y el tráfico nuevo no cambia el perfil del período, así que no
  # entran en este camino: se recalculan al cambiar de período, con el
  # refresh o al volver a la pestaña.
  def handle_info(:reload_counters, socket) do
    {:noreply,
     socket
     |> assign(:reload_scheduled, false)
     |> start_counters_load()}
  end

  ## "En vivo" tab ----------------------------------------------------------

  # Realtime refresh: metrics_updated is broadcast on every proxied request;
  # coalesce into one reload per @live_refresh_interval_ms. The periodic
  # :live_tick keeps the page moving even with zero traffic (chart shifts,
  # "hace Ns" ages).
  def handle_info({:metrics_updated, _lite}, socket) do
    if socket.assigns.live_action == :live and not socket.assigns.reload_scheduled do
      Process.send_after(self(), :reload_live, @live_refresh_interval_ms)
      {:noreply, assign(socket, :reload_scheduled, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:reload_live, socket) do
    if socket.assigns.live_action == :live do
      {:noreply,
       socket
       |> assign(:reload_scheduled, false)
       |> load_live_data()}
    else
      {:noreply, assign(socket, :reload_scheduled, false)}
    end
  end

  def handle_info(:live_tick, socket) do
    if socket.assigns.live_action == :live do
      Process.send_after(self(), :live_tick, @live_refresh_interval_ms)

      {:noreply, assign(socket, :inflight_count, Inflight.count())}
    else
      {:noreply, socket}
    end
  end

  # Minute-aligned clock tick for the budget-reset countdown. The countdown
  # is the only thing on /stats that has to move with zero traffic (the
  # "En vivo" 3s tick and the Resumen's `logs:new` reload both stall when the
  # proxy is idle), and it only changes once a minute, so we wake on the
  # minute boundary instead of polling. Re-assigning an unchanged value is a
  # no-op in `assign/3`, so this costs a re-render only when the label
  # actually changes (or on the midnight rollover).
  def handle_info(:clock_tick, socket) do
    schedule_clock_tick()
    {:noreply, assign_budget_reset(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Pure orchestration: no socket, no assigns — everything runs off plain
  # values so it can execute inside an async task (queries in parallel).
  # Bundle completo de las pestañas de datos (Modelos, Grupos, Servicios,
  # Usuarios, Proveedores): contadores + desgloses.
  defp compute_data_assigns(params) do
    opts = period_opts(params)

    (counter_tasks(params, opts) ++ breakdown_tasks(params, opts))
    |> run_parallel()
    |> Map.new()
    |> apply_sorting(params)
    |> merge_prev_metrics()
  end

  # Contadores del Resumen (:index): resumen del período + del anterior (los
  # deltas de los KPI). Son los dos agregados livianos del bundle y lo único
  # que se re-ejecuta en cada recarga por `logs:new`.
  defp compute_counter_assigns(params) do
    params
    |> counter_tasks(period_opts(params))
    |> run_parallel()
    |> Map.new()
    |> merge_prev_metrics()
  end

  # Agregados estructurales del Resumen: describen el período, no el tráfico
  # del momento (perfil horario, modelo×proveedor, horas/minutos pico y el
  # pico de concurrencia). Se recalculan al cambiar de período, con el
  # refresh o al volver a la pestaña — no en cada broadcast.
  defp compute_structural_assigns(params) do
    params
    |> breakdown_tasks(period_opts(params))
    |> run_parallel()
    |> Map.new()
    |> apply_sorting(params)
  end

  defp period_opts(params) do
    %{from: from, to: to} = Periods.period_bounds(params.period, params.timezone)
    [from: from, to: to, timezone: params.timezone]
  end

  defp counter_tasks(params, opts) do
    [
      fn -> {:metrics, summary_to_metrics(fetch_summary(params, opts))} end,
      fn ->
        {:prev_metrics,
         summary_to_metrics(previous_summary(params, params.period, params.timezone))}
      end
    ]
  end

  # Fetch the previous period's summary for delta comparison.
  defp previous_summary(params, period, timezone) do
    %{from: prev_from, to: prev_to} = Periods.previous_period_bounds(period, timezone)
    prev_opts = [from: prev_from, to: prev_to, timezone: timezone]
    fetch_summary(params, prev_opts)
  end

  # Merge prev_metrics into the :metrics map as delta percentages.
  defp merge_prev_metrics(%{metrics: metrics, prev_metrics: prev} = data) do
    Map.put(data, :metrics, Map.put(metrics, :deltas, compute_deltas(metrics, prev)))
  end

  defp merge_prev_metrics(data), do: data

  # Run every query function concurrently and collect results in order.
  # Queries share the Repo pool, so wall time is pool rounds, not the sum of
  # every query — this is what makes period switching feel fast.
  defp run_parallel(fun_list) do
    fun_list
    |> Task.async_stream(fn fun -> fun.() end, timeout: :infinity, zip_input_on_exit: true)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp summary_to_metrics(summary) do
    %{
      requests_total: summary.request_count,
      cost_usd: summary.total_cost_usd,
      prompt_tokens: summary.total_prompt_tokens,
      completion_tokens: summary.total_completion_tokens,
      cache_read_tokens: Map.get(summary, :total_cache_read_tokens, 0),
      cache_creation_tokens: Map.get(summary, :total_cache_creation_tokens, 0),
      avg_tps: Map.get(summary, :avg_tps)
    }
  end

  # Delta percentages for KPI comparison vs the previous period.
  # Returns nil when the previous value was zero (can't compute % change).
  defp compute_deltas(current, prev) do
    %{
      requests_total: pct_delta(current.requests_total, prev.requests_total),
      cost_usd: decimal_pct_delta(current.cost_usd, prev.cost_usd),
      prompt_tokens: pct_delta(current.prompt_tokens, prev.prompt_tokens),
      completion_tokens: pct_delta(current.completion_tokens, prev.completion_tokens)
    }
  end

  defp pct_delta(_current, 0), do: nil
  defp pct_delta(_current, nil), do: nil

  defp pct_delta(current, prev) when is_number(prev) and prev != 0 do
    Float.round((current - prev) / abs(prev) * 100, 1)
  end

  defp decimal_pct_delta(_current, %Decimal{coef: 0}), do: nil
  defp decimal_pct_delta(_current, nil), do: nil

  defp decimal_pct_delta(current, prev) do
    if Decimal.equal?(prev, Decimal.new(0)) do
      nil
    else
      current
      |> Decimal.sub(prev)
      |> Decimal.div(Decimal.abs(prev))
      |> Decimal.mult(Decimal.from_float(100.0))
      |> Decimal.round(1)
      |> Decimal.to_float()
    end
  end

  # Each task returns {assign_key, rows} so results can be applied without
  # caring about completion order.
  defp breakdown_tasks(params, opts) do
    opts = Keyword.put(opts, :member_ids, params.scope_member_ids)

    case params.live_action do
      :index ->
        admin? = params.user.global_role == "admin"

        # El Resumen ya NO carga tops/rankings/tiers: se movieron a las stats
        # de cada sección (models/groups/providers) para no recomputar los
        # agregados caros (percentile_cont, sweep de concurrencia) en cada
        # recarga del broadcast `logs:new`, que re-lanza el bundle completo.
        #
        # Tampoco carga el tope diario global: ese card mide el kill-switch y
        # vive en En vivo (`live-org-budget`), la pestaña que declaró esa
        # responsabilidad; con período "hoy" era el mismo card duplicado con
        # la misma query.
        # Con el período "Hoy" la gráfica de perfil horario mide el día UTC en
        # curso — la misma ventana que los KPI y el tope — y sale del agregado
        # del día (ver hour_usage_tasks/2), no del perfil del período.
        index_admin_tasks(admin?, opts) ++
          hour_usage_tasks(params, opts) ++
          [
            fn -> {:model_provider_stacked, Rollup.usage_by_model_provider_stacked(opts)} end,
            fn -> {:busiest_hours, Rollup.busiest_hours(nil, opts)} end,
            fn -> {:busiest_minutes, Rollup.busiest_minutes(nil, opts)} end
          ]

      :models ->
        # La pestaña es la tabla de consumo por modelo. El drill-down por query
        # string (?model_id=) sigue vivo como ALIAS del detalle: los enlaces que
        # ya existen (proveedor, grupo, servicio) entran por ahí y renderizan la
        # misma vista que `/stats/models/:id`, con las mismas queries.
        case params.model_filter do
          nil ->
            # Sin ranking: la tabla muestra el consumo, y el tier/score (que sale
            # del ranking) vive en la cabecera del detalle, que sí lo carga.
            [fn -> {:breakdown_model, Rollup.breakdown_by_model(nil, opts)} end]

          model_id ->
            model_detail_tasks(model_id, params.user, opts)
        end

      :model ->
        # Interior de la tabla de modelos: métricas del modelo, los proveedores
        # que lo sirven y quién lo usa (grupos y miembros).
        model_detail_tasks(params.model_filter, params.user, opts)

      :providers ->
        # Sección Infra nueva: destino del ranking de proveedores.
        [fn -> {:provider_ranking, Rollup.provider_ranking(nil, opts)} end]

      :provider ->
        # Interior de la tabla de proveedores: métricas del proveedor, los
        # modelos que sirve y quién lo usa (usuarios, servicios, grupos).
        provider_id = params.provider_id
        admin? = params.user.global_role == "admin"

        [
          fn -> {:provider, Tokengate.Providers.get_provider(provider_id)} end,
          # El ranking completo entra para tomar de ahí tier/score/p95/fallos:
          # la fila de la tabla y el detalle no pueden decir cosas distintas.
          fn -> {:provider_ranking, Rollup.provider_ranking(nil, opts)} end,
          fn -> {:provider_metrics, provider_metrics(provider_id, opts)} end,
          fn ->
            {:breakdown_model,
             Rollup.breakdown_by_model(nil, Keyword.put(opts, :provider_id, provider_id))}
          end,
          fn ->
            {:breakdown_user,
             Rollup.breakdown_by_user(Keyword.put(opts, :provider_id, provider_id))}
          end,
          fn ->
            {:breakdown_service,
             if admin? do
               Rollup.breakdown_by_service(Keyword.put(opts, :provider_id, provider_id))
             else
               []
             end}
          end,
          fn ->
            {:breakdown_group, breakdown_by_group_for_provider(params.user, provider_id, opts)}
          end
        ]

      :groups ->
        admin? = params.user.global_role == "admin"

        base =
          [
            fn -> {:breakdown_group, breakdown_by_group_if_admin(admin?, opts)} end
          ] ++
            if admin? do
              [fn -> {:group_budgets, Budgets.list_group_budgets(params.timezone)} end]
            else
              []
            end

        # Drill-down (?group_id=) shares the template with :group and
        # needs the group record for the breadcrumb.
        case params.group_filter do
          nil ->
            base

          group_id ->
            if group_drilldown_allowed?(params.user, group_id) do
              [fn -> {:group, Accounts.get_group!(group_id)} end | base]
            else
              base
            end
        end

      :group ->
        group_id = params.group_id
        allowed? = group_drilldown_allowed?(params.user, group_id)

        if allowed? do
          [
            fn -> {:group, Accounts.get_group!(group_id)} end,
            fn ->
              {:group_budget,
               Budgets.list_group_budgets(params.timezone) |> find_group_budget(group_id)}
            end,
            fn -> {:breakdown_member, Rollup.breakdown_by_member(group_id, opts)} end,
            fn -> {:breakdown_model, Rollup.breakdown_by_model(group_id, opts)} end,
            fn -> {:drilldown_series, Rollup.daily_series_by_model_for_group(group_id, opts)} end,
            fn ->
              {:drilldown_series_labels,
               Rollup.daily_series_by_model_for_group(group_id, opts)
               |> Enum.map(& &1.label)
               |> Enum.uniq()
               |> Enum.sort()}
            end
          ]
        else
          []
        end

      :users ->
        [
          fn -> {:breakdown_user, Rollup.breakdown_by_user(opts)} end,
          fn -> {:budgets_by_user, Budgets.spend_by_user(params.timezone)} end
        ]

      :services ->
        service_id = params.service_filter
        admin? = params.user.global_role == "admin"

        # Services have a dedicated service_id column.
        [fn -> {:service_budgets, Budgets.list_service_budgets()} end] ++
          [fn -> {:breakdown_service, breakdown_by_service_if_admin(admin?, opts)} end] ++
          if service_id && admin? do
            [
              fn ->
                {:breakdown_model,
                 Rollup.breakdown_by_model(nil, Keyword.put(opts, :service_id, service_id))}
              end,
              fn ->
                {:drilldown_series, Rollup.daily_series_by_model_for_service(service_id, opts)}
              end,
              fn ->
                {:drilldown_series_labels,
                 Rollup.daily_series_by_model_for_service(service_id, opts)
                 |> Enum.map(& &1.label)
                 |> Enum.uniq()
                 |> Enum.sort()}
              end
            ]
          else
            []
          end

      _ ->
        []
    end
  end

  # Detalle de un modelo: el bundle que alimenta la vista de detalle, tanto por
  # la ruta propia (`/stats/models/:id`, action `:model`) como por el alias
  # `?model_id=` de la pestaña Modelos. Los proveedores que lo sirven y los
  # grupos/miembros que lo usan son los MISMOS tres desgloses que ya tenía el
  # drill-down: acá sólo cambia de dónde entran.
  defp model_detail_tasks(model_id, user, opts) do
    [
      fn -> {:model, Tokengate.Providers.get_model(model_id)} end,
      # El ranking completo entra para tomar de ahí tier/score/p95/fallos: la
      # fila de la tabla y la cabecera del detalle no pueden decir cosas
      # distintas (mismo criterio que el detalle de proveedor).
      fn -> {:model_ranking, Rollup.model_ranking(nil, opts)} end,
      fn -> {:breakdown_provider, Rollup.breakdown_by_provider_for_model(model_id, opts)} end,
      fn -> {:breakdown_group, breakdown_group_for_model(user, model_id, opts)} end,
      fn -> {:breakdown_member, Rollup.breakdown_by_member_for_model(model_id, opts)} end,
      fn -> {:drilldown_series, Rollup.daily_series_by_provider_for_model(model_id, opts)} end,
      fn ->
        {:drilldown_series_labels,
         Rollup.daily_series_by_provider_for_model(model_id, opts)
         |> Enum.map(& &1.label)
         |> Enum.uniq()
         |> Enum.sort()}
      end
    ]
  end

  # Perfil horario (gráfica "Uso por hora del día"). Con ventanas de más de un
  # día es el perfil del período en la hora local del usuario (rollup); con
  # "Hoy" es el día UTC en curso — la misma ventana que los KPI y el tope, y la
  # MISMA consulta del día que ya alimenta la tarjeta de En vivo, así que las
  # dos pestañas dibujan el mismo día con las mismas horas. Las dos fuentes
  # devuelven la forma que espera la tarjeta (`StatsLive.DayHourChart`).
  defp hour_usage_tasks(%{period: "today"}, _opts) do
    [fn -> {:hour_usage_by_provider, Logs.today_usage_by_hour_provider()} end]
  end

  defp hour_usage_tasks(_params, opts) do
    [fn -> {:hour_usage_by_provider, Rollup.usage_by_hour_of_day_by_provider(opts)} end]
  end

  # Admin-only infra/org-wide queries on the index view. Ahora el Resumen solo
  # conserva el pico de concurrencia (admin): rankings y tiers viven en las
  # secciones models / groups / providers.
  defp index_admin_tasks(true, opts) do
    [fn -> {:peak_concurrency, Rollup.peak_concurrency(nil, opts)} end]
  end

  defp index_admin_tasks(false, _opts), do: []

  # Picks a single group's budget row out of the group rollup.
  defp find_group_budget(rows, group_id) do
    Enum.find(rows, fn row -> row.group.id == group_id end)
  end

  defp apply_sorting(data, %{sort_field: field, sort_direction: direction}) do
    Enum.reduce(@sortable_breakdowns, data, fn key, acc ->
      case acc do
        %{^key => rows} -> Map.put(acc, key, sort_rows(rows, field, direction))
        _ -> acc
      end
    end)
  end

  # Empty values for the structural assigns of a load. The Resumen (:index)
  # keeps `:metrics` out of this wipe: those counters travel in their own
  # async task (`:stats_counters`) and clearing them here would blank the KPI
  # row whenever the structural half lands last.
  defp empty_structural_assigns(:index), do: Map.delete(empty_data_assigns(), :metrics)

  defp empty_structural_assigns(_live_action), do: empty_data_assigns()

  # Empty values for every data assign — used on mount so the first render
  # (while the async load runs) shows empty states instead of stale assigns.
  defp empty_data_assigns do
    %{
      metrics: empty_metrics(),
      breakdown_model: [],
      breakdown_member: [],
      breakdown_group: [],
      breakdown_provider: [],
      breakdown_service: [],
      breakdown_user: [],
      provider_ranking: [],
      provider: nil,
      provider_metrics: empty_provider_metrics(),
      model_ranking: [],
      group: nil,
      member: nil,
      member_models: [],
      hour_usage_by_provider: [],
      model_provider_stacked: [],
      busiest_hours: [],
      busiest_minutes: [],
      peak_concurrency: nil,
      model: nil,
      drilldown_series: [],
      drilldown_series_labels: [],
      org_budget: nil,
      budgets_by_user: %{},
      service_budgets: [],
      group_budgets: [],
      group_budget: nil
    }
  end

  ## Scoping helpers ------------------------------------------------------

  defp group_drilldown_allowed?(user, group_id) do
    case Accounts.scope_group_ids(user) do
      nil -> true
      group_ids -> group_id in group_ids
    end
  end

  # Group table for a model drill-down: admins see every group; managers only
  # groups they manage; regular users don't see group-level data at all.
  defp breakdown_group_for_model(user, model_id, opts) do
    case Accounts.scope_group_ids(user) do
      nil -> Rollup.breakdown_by_group_for_model(model_id, opts)
      [] -> []
    end
  end

  # Mismo criterio de scoping para los grupos que usan un proveedor.
  defp breakdown_by_group_for_provider(user, provider_id, opts) do
    case Accounts.scope_group_ids(user) do
      nil -> Rollup.breakdown_by_group(Keyword.put(opts, :provider_id, provider_id))
      [] -> []
    end
  end

  # Costo y tokens del proveedor en el período. La confiabilidad (tier, score,
  # p95, fallos) NO se recalcula acá: sale de la fila del ranking, que es la
  # misma que pinta la tabla de proveedores.
  defp provider_metrics(nil, _opts), do: empty_provider_metrics()

  defp provider_metrics(provider_id, opts) do
    Logs.cost_summary(%{provider_id: provider_id, from: opts[:from], to: opts[:to]})
  end

  defp empty_provider_metrics do
    %{
      total_cost_usd: Decimal.new(0),
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_cache_read_tokens: 0,
      total_cache_creation_tokens: 0,
      request_count: 0,
      avg_latency_ms: nil,
      avg_ttft_ms: nil,
      avg_tps: nil
    }
  end

  defp breakdown_by_group_if_admin(true, opts), do: Rollup.breakdown_by_group(opts)
  defp breakdown_by_group_if_admin(false, _opts), do: []

  defp breakdown_by_service_if_admin(true, opts), do: Rollup.breakdown_by_service(opts)
  defp breakdown_by_service_if_admin(false, _opts), do: []

  defp fetch_summary(%{user: %{global_role: "admin"}} = params, opts) do
    # Hybrid read: rollup for the bulk of the window + raw tail (last 3h)
    # — see Tokengate.Metrics.StatsQueries. Falls back to raw when the
    # window is recent-only or the rollup flag is off.
    opts
    |> apply_stats_filters(params)
    |> StatsQueries.summary()
  end

  defp fetch_summary(%{user: %{global_role: "user"} = user}, opts) do
    memberships = Accounts.list_group_members_for_user(user.id)
    member_ids = Enum.map(memberships, & &1.id)

    opts
    |> Map.new()
    |> Map.put(:group_member_ids, member_ids)
    |> StatsQueries.summary()
  end

  defp fetch_summary(_params, _opts), do: empty_summary()

  # Build a filter map from the active stats page filter so cost_summary
  # returns data scoped to the selected model / group / service.
  defp apply_stats_filters(opts, params) do
    base = Map.new(opts)

    cond do
      params.model_filter ->
        Map.put(base, :model_id, params.model_filter)

      params.group_filter ->
        Map.put(base, :group_id, params.group_filter)

      params.service_filter ->
        Map.put(base, :service_id, params.service_filter)

      true ->
        base
    end
  end

  ## "En vivo" data ---------------------------------------------------------

  # Countdown to the global kill-switch reset, split into hours/minutes so the
  # template can render the `:` as its own blinking element. Minute-granular,
  # so a per-minute wall-clock tick almost always reassigns identical values
  # and `assign/3` no-ops — the diff goes out only when the label actually
  # changes, not on every tick.
  #
  # The countdown is a plain duration (timezone-independent); `reset_at` is the
  # same instant, which the label renders in the selected zone so the user
  # reads the reset on their own clock.
  defp assign_budget_reset(socket) do
    reset_at = Periods.next_utc_day_start(Periods.now_utc())
    {hours, minutes} = Stats.countdown_parts(reset_at)

    socket
    |> assign(:budget_reset_hours, hours)
    |> assign(:budget_reset_minutes, minutes)
    |> assign(:budget_reset_at, reset_at)
  end

  # Wakes just after the wall-clock minute turns, so the countdown label is
  # never more than a second stale. Skew between the BEAM and the browser
  # clock would otherwise drift the label off the minute boundary.
  defp schedule_clock_tick do
    ms = 60_000 - rem(System.system_time(:millisecond), 60_000)
    Process.send_after(self(), :clock_tick, ms)
  end

  # One bundled realtime refresh. All queries are cheap (index range scans
  # over the last hour/day) and shared across connected live tabs via the
  # DashboardCache TTL so a busy proxy doesn't multiply Postgres load.
  defp load_live_data(socket) do
    timezone = socket.assigns[:timezone] || "Etc/UTC"

    bundle =
      DashboardCache.fetch_or_compute({:stats_live, timezone}, fn ->
        # KPIs "Hoy" = día UTC (misma ventana que el kill-switch y que el
        # card de tope de arriba) — no el día local del usuario.
        today_metrics = Logs.today_summary("Etc/UTC")

        %{
          pulse: Logs.realtime_summary(%{}),
          today_metrics: today_metrics,
          minute_series: Logs.requests_per_minute(60),
          # "Hoy por hora · por proveedor": un solo agregado (hora ×
          # proveedor) sobre la partición del día UTC, sin joins.
          day_by_hour: Logs.today_usage_by_hour_provider(),
          # Gasto real del día UTC — el mismo número que muestra Mantenimiento
          # — más cap y exentos del kill-switch. Día UTC y no local: el cap
          # resetea a las 00:00 UTC, así que barra, % y countdown tienen que
          # medir la misma ventana. Nada de contador ETS (holds).
          org_budget: Budgets.global_daily_budget_summary()
        }
      end)

    feed_logs = Logs.list_logs(%{limit: @live_feed_size})

    minute_series = bundle.minute_series

    socket
    |> assign(:stats_loading, false)
    |> assign(:pulse, bundle.pulse)
    |> assign(:today_metrics, bundle.today_metrics)
    |> assign(:minute_series, minute_series)
    |> assign(:minute_series_max, minute_requests_max(minute_series))
    |> assign(:minute_tokens_max, minute_tokens_max(minute_series))
    |> assign(:minute_cost_max, minute_cost_max(minute_series))
    |> assign(:org_budget, bundle.org_budget)
    |> assign(:inflight_count, Inflight.count())
    |> assign(:day_by_hour, bundle.day_by_hour)
    |> assign(:last_sync_at, DateTime.utc_now())
    |> stream(:live_feed, feed_logs, reset: true)
  end

  # Per-series maxima for the three "En vivo" bar charts. All three read the
  # same 60-bucket series already in hand — no extra query.
  defp minute_requests_max(series), do: series |> Enum.map(& &1.request_count) |> max_or_zero()

  defp minute_tokens_max(series) do
    series
    |> Enum.map(&(&1.prompt_tokens + &1.completion_tokens))
    |> max_or_zero()
  end

  defp minute_cost_max(series) do
    series
    |> Enum.map(&Decimal.to_float(&1.cost_usd))
    |> Enum.max(fn -> 0.0 end)
  end

  defp max_or_zero([]), do: 0
  defp max_or_zero(list), do: Enum.max(list)

  ## Helpers --------------------------------------------------------------

  defp parse_period(nil), do: "today"
  defp parse_period(period) when period in ~w(today week month 30d 90d), do: period
  defp parse_period(_), do: "today"

  defp empty_metrics do
    %{
      requests_total: 0,
      cost_usd: Decimal.new(0),
      prompt_tokens: 0,
      completion_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      avg_tps: nil,
      deltas: %{
        requests_total: nil,
        cost_usd: nil,
        prompt_tokens: nil,
        completion_tokens: nil
      }
    }
  end

  defp empty_summary do
    %{
      total_cost_usd: Decimal.new(0),
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      request_count: 0,
      avg_tps: nil
    }
  end

  defp scope_label_for(%{global_role: "admin"}), do: "Organización completa"

  defp scope_label_for(%{global_role: "user"}), do: "Tus consumos"

  defp scope_label_for(_), do: "—"
end
