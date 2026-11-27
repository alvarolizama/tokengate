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
    * `:agents`   — coding-agent ranking (identity normalized in read)
    * `:provider` — one provider's hub: metrics, models served, who uses it
    * `:users`   — per-user consolidated breakdown (all memberships)
    * `:finops`  — spend economics: users vs services, anatomy, capabilities

  Periods: Hoy, Ayer, Esta semana, 30d (all but :live) — the canonical
  set in `Tokengate.Periods`; a legacy `?period=month|last_month|7d` bookmark
  degrades to the default instead of resolving to another window.

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
  alias Tokengate.SmartRouter.Analytics
  import TokengateWeb.StatsLive.Agent, only: [agent: 1]
  import TokengateWeb.StatsLive.Agents, only: [agents: 1]
  import TokengateWeb.StatsLive.Index, only: [index: 1]
  import TokengateWeb.StatsLive.Models, only: [models: 1]
  import TokengateWeb.StatsLive.Model, only: [model: 1]
  import TokengateWeb.StatsLive.Groups, only: [groups: 1]
  import TokengateWeb.StatsLive.Group, only: [group: 1]
  import TokengateWeb.StatsLive.Services, only: [services: 1]
  import TokengateWeb.StatsLive.Users, only: [users: 1]
  import TokengateWeb.StatsLive.Providers, only: [providers: 1]
  import TokengateWeb.StatsLive.Provider, only: [provider: 1]
  import TokengateWeb.StatsLive.Router, only: [router: 1]
  import TokengateWeb.StatsLive.LiveSection, only: [live: 1]
  import TokengateWeb.StatsLive.Finops, only: [finops: 1]

  import TokengateWeb.StatsHelpers, only: [period_selector: 1, sort_rows: 3]

  alias TokengateWeb.StatsHelpers, as: Stats

  # Breakdown assigns whose tables have sortable column headers. The "sort"
  # event re-orders these in memory — see resort_breakdowns/3.
  #
  # Resumen: cadencia de recarga de los contadores tras un broadcast
  # `logs:new` (son los únicos que el tráfico nuevo invalida).
  @reload_interval_ms 3_000

  # "En vivo" tab: cadence of the periodic realtime refresh (matching
  # MonitoringLive's inflight cadence).
  @live_refresh_interval_ms 3_000

  # TTL of the shared realtime-pulse entry (global, sin scope). Tiene que
  # sobrevivir al intervalo del tick (3s): con un TTL menor la entrada caduca
  # ENTRE ticks y cada visor vuelve a calcular el suyo. 3.5s mantiene un
  # cálculo por ventana para todos los visores (staleness máx. 3.5s, por
  # debajo del bundle de 5s que lo servía antes).
  @pulse_cache_ttl_ms 3_500

  # "En vivo" feed: how many recent requests to show.
  @live_feed_size 20

  @allowed_sort_fields %{
    "request_count" => :request_count,
    "cost_usd" => :cost_usd,
    "prompt_tokens" => :prompt_tokens,
    "completion_tokens" => :completion_tokens,
    "avg_tps" => :avg_tps,
    "avg_latency_ms" => :avg_latency_ms,
    "p95_latency_ms" => :p95_latency_ms,
    "avg_ttft_ms" => :avg_ttft_ms,
    "score" => :score,
    "error_rate" => :error_rate,
    "error_count" => :error_count,
    "cache_read_tokens" => :cache_read_tokens,
    "share" => :share,
    "label" => :label,
    "model_name" => :model_name,
    "provider_name" => :provider_name,
    "group_name" => :group_name,
    "user_email" => :user_email,
    "service_name" => :service_name
  }

  @sortable_breakdowns [
    :breakdown_model,
    :breakdown_member,
    :breakdown_group,
    :breakdown_provider,
    :breakdown_service,
    :breakdown_agent,
    :breakdown_user,
    :agent_ranking,
    :provider_ranking
  ]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, gettext("Statistics") <> " · Tokengate")
      |> assign(:period, "today")
      |> assign(:model_filter, nil)
      |> assign(:group_filter, nil)
      |> assign(:scope_label, scope_label_for(user))
      |> assign(:scope_member_ids, Accounts.scope_member_ids(user))
      |> assign(:group_id, nil)
      |> assign(:agent_key, nil)
      |> assign(:shadow_config_id, nil)
      |> assign(:sort_field, :cost_usd)
      |> assign(:sort_direction, :desc)
      |> assign(:chart_metric, "requests")
      |> assign(:overview_metric, "cost")
      |> assign(:finops_metric, "cost")
      |> assign(:finops_scatter_y, "cpr")
      |> assign(:finops_entity, "models")
      |> assign(:finops_entity_metric, "cpr")
      |> assign(:list_search, "")
      |> assign(:stats_loading, true)
      |> assign(:load_error, false)
      |> assign(:counters_error, false)
      |> assign(:per_page, 10)
      |> assign(:shown_counts, %{})
      |> assign(:reload_scheduled, false)
      |> assign(:pulse_scheduled, false)
      |> assign(:live_drivers, %{
        window_minutes: 15,
        top_models: [],
        top_consumers: [],
        top_agents: []
      })
      |> assign(:yesterday_pace, nil)
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
      send(self(), :live_tick)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period = parse_period(params["period"])
    model_filter = cast_uuid(params["model_id"])
    group_filter = cast_uuid(params["group_id"])
    # :group action carries the group in the URL path (/stats/profiles/:id);
    # :groups keeps ?group_id= as an alias of the detail, matching :models/:model.
    group_id =
      case socket.assigns.live_action do
        :group -> cast_uuid(params["group_id"])
        :groups -> group_filter
        _ -> nil
      end

    # :provider carries the provider in the URL path (/stats/providers/:id);
    # :finops lo usa como FILTRO en query string.
    provider_id =
      case socket.assigns.live_action do
        :provider -> cast_uuid(params["provider_id"])
        :finops -> cast_uuid(params["provider_id"])
        _ -> nil
      end

    # Filtros propios de FinOps: permiten bajar del mapa de modelos/proveedores
    # a "quién gastó en esto" sin salir de la sección.
    {finops_user_id, finops_service_id} =
      case socket.assigns.live_action do
        :finops ->
          {cast_uuid(params["user_id"]), cast_uuid(params["service_id"])}

        _ ->
          {nil, nil}
      end

    agent_key =
      case socket.assigns.live_action do
        :agent -> params["agent_key"]
        _ -> nil
      end

    # `?shadow_config_id=` picks WHICH shadow version the /stats/router
    # migration breakdown inspects. It lives in the URL for the same reason the
    # period does: a shared link opens the same comparison, and the selector
    # patches it without dropping `?period=`.
    shadow_config_id =
      case socket.assigns.live_action do
        :router -> cast_uuid(params["shadow_config_id"])
        _ -> nil
      end

    socket =
      socket
      |> assign(:period, period)
      |> assign(:model_filter, model_filter)
      |> assign(:group_filter, group_filter)
      |> assign(:group_id, group_id)
      |> assign(:provider_id, provider_id)
      |> assign(:finops_user_id, finops_user_id)
      |> assign(:finops_service_id, finops_service_id)
      |> assign(:agent_key, agent_key)
      |> assign(:shadow_config_id, shadow_config_id)

    # Cada sección tiene su propio listado: el filtro de la anterior no
    # aplica y escondería filas sin que se vea por qué. Pero cambiar de
    # PERIODO (patch dentro de la misma sección) no debe borrarlo.
    entering? = socket.assigns[:last_live_action] != socket.assigns.live_action

    socket =
      if entering? do
        assign(socket, :list_search, "")
      else
        socket
      end
      |> assign(:last_live_action, socket.assigns.live_action)

    # Cada sección entra ordenada por impacto en dinero (`cost_usd` desc),
    # salvo Providers que prioriza confiabilidad (`score` desc). Cambiar de
    # período dentro de la misma pestaña respeta el orden elegido por el usuario.
    socket =
      cond do
        entering? and socket.assigns.live_action == :providers ->
          assign(socket, sort_field: :score, sort_direction: :desc)

        entering? ->
          assign(socket, sort_field: :cost_usd, sort_direction: :desc)

        true ->
          socket
      end

    socket =
      case socket.assigns.live_action do
        :live -> load_live_data(socket)
        _ -> start_data_load(socket)
      end

    {:noreply, socket}
  end

  # El periodo vive en la URL (?period=): el selector hace patch y
  # handle_params es el único punto de carga. Sin handle_event de periodo.
  #
  # Target del selector según la pestaña/detalle actual: los botones patchean
  # la MISMA vista con el nuevo periodo, conservando el id en los detalles.
  def period_target(%{live_action: :provider, provider_id: id}) when is_binary(id),
    do: "/stats/providers/#{id}"

  def period_target(%{live_action: :model, model_filter: id}) when is_binary(id),
    do: "/stats/models/#{id}"

  def period_target(%{live_action: :group, group_id: id}) when is_binary(id),
    do: "/stats/profiles/#{id}"

  # Query-param drills (p.ej. /stats/models?model_id=x desde los detalles de
  # perfil/proveedor) mantienen live_action :models con el filtro en assigns:
  # sin estas cláusulas el cambio de periodo tiraría el drilldown en silencio.
  def period_target(%{live_action: :models, model_filter: id}) when is_binary(id),
    do: "/stats/models/#{id}"

  def period_target(%{live_action: :groups, group_id: id}) when is_binary(id),
    do: "/stats/profiles/#{id}"

  def period_target(%{live_action: :providers}), do: "/stats/providers"
  def period_target(%{live_action: :agents}), do: "/stats/agents"

  def period_target(%{live_action: :agent, agent_key: key}) when is_binary(key),
    do: ~p"/stats/agents/#{key}"

  def period_target(%{live_action: :models}), do: "/stats/models"
  def period_target(%{live_action: :router}), do: "/stats/router"
  def period_target(%{live_action: :groups}), do: "/stats/profiles"
  def period_target(%{live_action: :services}), do: "/stats/services"
  def period_target(%{live_action: :users}), do: "/stats/users"

  def period_target(%{live_action: :finops}), do: "/stats/finops"

  def period_target(_), do: "/stats/overview"

  # Filtros activos de FinOps como sufijo de query (`&model_id=…`), para que el
  # selector de período los conserve al cambiar de ventana. Vacío en el resto
  # de las pestañas: ahí un filtro de la sección anterior no aplica.
  def finops_extra_query(%{live_action: :finops} = assigns) do
    [
      {"model_id", Map.get(assigns, :model_filter)},
      {"provider_id", Map.get(assigns, :provider_id)},
      {"user_id", Map.get(assigns, :finops_user_id)},
      {"service_id", Map.get(assigns, :finops_service_id)}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map_join("", fn {key, value} -> "&#{key}=#{value}" end)
  end

  def finops_extra_query(_assigns), do: ""

  # Buscador de los listados rankeados (Users, Models, Providers). El texto
  # vive en el socket y las secciones filtran sus propias filas en el render:
  # no toca la DB ni las claves del DashboardCache.
  @impl true
  def handle_event("filter_list", %{"value" => query}, socket) do
    {:noreply, assign(socket, :list_search, query || "")}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    case Map.fetch(@allowed_sort_fields, field) do
      {:ok, field} ->
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

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("sort", _params, socket), do: {:noreply, socket}

  def handle_event("refresh", _params, socket) do
    {:noreply, start_data_load(socket)}
  end

  def handle_event("set_chart_metric", %{"metric" => metric}, socket)
      when metric in ~w(requests cost) do
    {:noreply, assign(socket, :chart_metric, metric)}
  end

  def handle_event("set_chart_metric", _params, socket), do: {:noreply, socket}

  def handle_event("set_overview_metric", %{"metric" => metric}, socket)
      when metric in ~w(cost requests) do
    {:noreply, assign(socket, :overview_metric, metric)}
  end

  def handle_event("set_overview_metric", _params, socket), do: {:noreply, socket}

  # FinOps: métrica de la tendencia (costo / requests / $/req) y eje Y de la
  # dispersión ($/req / caché). Todo es de presentación: las filas ya están
  # cargadas en el socket y el render se recalcula sin tocar la DB.
  def handle_event("set_finops_metric", %{"metric" => metric}, socket)
      when metric in ~w(cost requests cpr) do
    {:noreply, assign(socket, :finops_metric, metric)}
  end

  def handle_event("set_finops_metric", _params, socket), do: {:noreply, socket}

  def handle_event("set_finops_scatter_y", %{"metric" => metric}, socket)
      when metric in ~w(cpr cache) do
    {:noreply, assign(socket, :finops_scatter_y, metric)}
  end

  def handle_event("set_finops_scatter_y", _params, socket), do: {:noreply, socket}

  # Mapa de eficiencia de modelos/proveedores: qué entidad se cambia y con qué
  # eje (costo unitario o cuánto de su gasto fue razonamiento).
  def handle_event("set_finops_entity", %{"entity" => entity}, socket)
      when entity in ~w(models providers) do
    {:noreply, assign(socket, :finops_entity, entity)}
  end

  def handle_event("set_finops_entity", _params, socket), do: {:noreply, socket}

  def handle_event("set_finops_entity_metric", %{"metric" => metric}, socket)
      when metric in ~w(cpr think) do
    {:noreply, assign(socket, :finops_entity_metric, metric)}
  end

  def handle_event("set_finops_entity_metric", _params, socket), do: {:noreply, socket}

  # Filtros de FinOps desde los selects: arma el patch conservando el período y
  # descartando los vacíos. La URL manda: un link filtrado se puede compartir.
  def handle_event("finops_filter", params, socket) do
    query =
      [{"period", socket.assigns.period}] ++
        for key <- ~w(model_id provider_id user_id service_id),
            value = params[key],
            is_binary(value) and value != "" do
          {key, value}
        end

    {:noreply, push_patch(socket, to: "/stats/finops?" <> URI.encode_query(query))}
  end

  # "Ver más" de los listados largos: los detalles de proveedor y modelo (una
  # clave por tabla). El conteo desplegado vive en `shown_counts`, así que cada
  # listado se despliega por su cuenta sin recargar ni volver a consultar: las
  # filas ya están en memoria.
  def handle_event("show_more", %{"key" => key}, socket) do
    {:noreply, show_more(socket, key)}
  end

  def handle_event("show_more", %{"group-id" => group_id}, socket) do
    {:noreply, show_more(socket, group_id)}
  end

  # /stats/router: qué versión Shadow inspecciona la tabla de migraciones.
  # Patch (no navigate) para conservar `?period=`: el cambio vuelve por
  # `handle_params` y reusa el mismo cargador asíncrono de la pestaña.
  def handle_event("select_shadow_version", %{"shadow_config_id" => shadow_id}, socket) do
    case socket.assigns.live_action do
      :router ->
        query =
          case cast_uuid(shadow_id) do
            nil -> %{"period" => socket.assigns.period}
            id -> %{"period" => socket.assigns.period, "shadow_config_id" => id}
          end

        {:noreply, push_patch(socket, to: "/stats/router?" <> URI.encode_query(query))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("select_shadow_version", _params, socket), do: {:noreply, socket}

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

  # TTL of the structural bundle of a stats tab: it describes the period, not
  # the traffic of the instant (the KPIs of the Resumen live in the counters
  # load, which has its own, shorter TTL). 60s ≈ what a cold long-window
  # query takes; past the TTL the next viewer repopulates the cache.
  #
  # In tests the cache is off (config :stats_structural_cache): specs share
  # the app's ETS table and would hand each other bundles.
  @structural_cache_ttl 60_000

  # TTL of the Resumen counters (current-window summary + the previous one).
  # Must outlive `@reload_interval_ms` (3s) so a viewer's next tick reads the
  # entry the previous tick published instead of computing its own — with N
  # viewers that is one aggregate per window instead of N every 3s. Same
  # rationale as the 3.5s realtime pulse.
  @counters_cache_ttl 3_500

  defp structural_cache_enabled?,
    do: Application.get_env(:tokengate, :stats_structural_cache, enabled: true)[:enabled] != false

  # La llave describe TODO lo que cambia el bundle: pestaña, período,
  # timezone (horas locales), drilldown activo y scope (`nil` = admin global).
  # El orden de las tablas NO entra: se aplica al asignar
  # (ver `apply_sorting/2`), así dos visores con distinto sort comparten el
  # mismo cálculo.
  defp structural_cache_key(%{live_action: :router} = params) do
    {:stats_structural, :router, params.period, params.timezone, params.model_filter,
     params.group_filter, params.group_id, params.provider_id, params[:agent_key],
     params[:shadow_config_id], cache_scope(params)}
  end

  defp structural_cache_key(params) do
    {:stats_structural, params.live_action, params.period, params.timezone, params.model_filter,
     params.group_filter, params.group_id, params.provider_id, params[:agent_key],
     params[:finops_user_id], params[:finops_service_id], cache_scope(params)}
  end

  # Lectura/escritura del cache con el flag de tests: deshabilitado, ambos
  # lados son pass-through (compute directo, fetch siempre miss).
  defp cached_structural_bundle(key) do
    if structural_cache_enabled?(), do: DashboardCache.fetch(key), else: :miss
  end

  defp cached_structural_bundle(key, compute_fn) do
    if structural_cache_enabled?() do
      DashboardCache.fetch_or_compute(key, compute_fn, ttl: @structural_cache_ttl)
    else
      compute_fn.()
    end
  end

  # Kick off an async data load. The socket renders right away with the
  # previous period's data (or empty values on first mount) plus an inline
  # loading indicator; when every query finishes, the new data lands in one
  # diff via handle_info/2. Switching periods quickly cancels the in-flight
  # load automatically.
  defp start_data_load(socket) do
    params = data_params(socket.assigns)
    key = structural_cache_key(params)

    case params.live_action do
      # El Resumen se parte en dos cargas: los contadores (resumen del
      # período + el anterior → deltas) y los agregados estructurales
      # (perfil horario, modelo×proveedor, picos y el sweep de
      # concurrencia). Sólo los contadores se recargan con `logs:new`;
      # lo estructural espera a un cambio de período, un refresh o un
      # cambio de pestaña.
      #
      # Las dos mitades van por `DashboardCache` con single-flight: un
      # bundle estructural que tarda decenas de segundos se calcula UNA vez
      # por scope/pestaña/período y los contadores se comparten entre
      # visores dentro de su TTL corto.
      :index ->
        socket =
          case cached_structural_bundle(key) do
            {:ok, bundle} ->
              # HIT: the structural data lands synchronously and no :stats_data
              # task runs, so nothing else would clear the spinner (the counters
              # task never touches stats_loading). Clear it here, otherwise the
              # overview wedges "loading" on every cached period switch.
              socket
              |> assign(bundle)
              |> assign(:stats_loading, false)
              |> assign(:load_error, false)

            :miss ->
              socket
              |> start_async(:stats_data, fn ->
                cached_structural_bundle(key, fn -> compute_structural_assigns(params) end)
              end)
              |> assign(:stats_loading, true)
          end

        start_async(socket, :stats_counters, fn -> compute_counter_assigns(params) end)

      # La vista Router: un bundle propio (analítica del SmartRouter sobre
      # `request_logs`), con el mismo cache estructural que el resto de tabs.
      :router ->
        case cached_structural_bundle(key) do
          {:ok, bundle} ->
            socket
            |> assign(:stats_loading, false)
            |> assign(:load_error, false)
            |> assign(empty_structural_assigns(:router))
            |> assign(bundle)

          :miss ->
            socket
            |> start_async(:stats_data, fn ->
              cached_structural_bundle(key, fn -> compute_router_assigns(params) end)
            end)
            |> assign(:stats_loading, true)
        end

      # El resto de las pestañas: el mismo bundle único de siempre, ahora
      # bajo la clave estructural (rankings con percentile_cont, picos,
      # presupuestos de perfiles/servicios/usuarios: un cálculo por minuto
      # y scope en vez de uno por clic y visor). El hit responde ya, sin
      # spinner: el bundle no describe el instante.
      _ ->
        case cached_structural_bundle(key) do
          {:ok, bundle} ->
            socket
            |> assign(:stats_loading, false)
            |> assign(:load_error, false)
            |> assign(empty_structural_assigns(params.live_action))
            |> assign(apply_sorting(bundle, params))

          :miss ->
            socket
            |> start_async(:stats_data, fn ->
              cached_structural_bundle(key, fn -> compute_data_assigns(params) end)
            end)
            |> assign(:stats_loading, true)
        end
    end
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
      group_id: assigns.group_id,
      provider_id: assigns[:provider_id],
      finops_user_id: assigns[:finops_user_id],
      finops_service_id: assigns[:finops_service_id],
      agent_key: assigns[:agent_key],
      shadow_config_id: assigns[:shadow_config_id],
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
      |> assign(:load_error, false)
      |> assign(empty_structural_assigns(socket.assigns.live_action))
      |> assign(apply_sorting(data, data_params(socket.assigns)))

    {:noreply, socket}
  end

  # La tarea murió con una query real explotada: el motivo original ya está
  # en el log (run_parallel lo re-eleva). En la UI no se finge éxito: se
  # declara el fallo y se dice que lo visible es el periodo anterior.
  def handle_async(:stats_data, {:exit, reason}, socket) do
    require Logger
    Logger.warning("stats data load failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:stats_loading, false)
     |> assign(:load_error, true)}
  end

  # Los contadores del Resumen llegan en su propia tarea y se aplican solos:
  # no tocan `stats_loading` (quien la apaga es la parte estructural, que es
  # la pesada) ni pisan el resto de los assigns.
  def handle_async(:stats_counters, {:ok, data}, socket) do
    {:noreply, socket |> assign(data) |> assign(counters_error: false)}
  end

  # Los KPIs reventaron: el usuario veía ceros sin explicación. Mismo trato
  # honesto que el bundle estructural.
  def handle_async(:stats_counters, {:exit, reason}, socket) do
    require Logger
    Logger.warning("stats counters load failed: #{inspect(reason)}")

    {:noreply, assign(socket, counters_error: true)}
  end

  # `logs:new` broadcast — route by tab:
  #   * live: prepend to the feed + refresh the pulse
  #   * overview: coalesce into a counters-only reload (KPIs y deltas);
  #     los agregados estructurales NO se re-ejecutan acá
  @impl true
  def handle_info({:new_log, log}, socket) do
    case socket.assigns.live_action do
      :live ->
        # El evento NO recalcula el pulso: bajo carga esto corría
        # `realtime_summary/1` una vez por request y por visor conectado. Se
        # marca sucio y se programa UN :reload_pulse por intervalo; el valor
        # sale del DashboardCache (clave global, TTL 3.5s), así que N visores
        # comparten un solo cálculo.
        socket =
          socket
          |> stream_insert(:live_feed, log, at: 0, limit: @live_feed_size)
          |> assign(:last_sync_at, DateTime.utc_now())

        {:noreply, schedule_pulse_refresh(socket)}

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

  # Pulso coalescido del feed. Llega como mucho una vez por
  # @live_refresh_interval_ms aunque el proxy emita cientos de `logs:new`.
  def handle_info(:reload_pulse, socket) do
    socket = assign(socket, :pulse_scheduled, false)

    if socket.assigns.live_action == :live do
      {:noreply,
       socket
       |> assign(:pulse, live_pulse())
       |> assign(:live_drivers, live_drivers())}
    else
      {:noreply, socket}
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

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Pure orchestration: no socket, no assigns — everything runs off plain
  # values so it can execute inside an async task (queries in parallel).
  # Bundle completo de las pestañas de datos (Modelos, Perfiles de límites, Servicios,
  # Usuarios, Proveedores): contadores (sólo si el template los lee) + desgloses.
  defp compute_data_assigns(params) do
    opts = period_opts(params)

    (metric_task_if_read(params, opts) ++ breakdown_tasks(params, opts))
    |> run_parallel()
    |> Map.new()
    |> derive_series_labels()
  end

  # Only the views whose template renders `@metrics` ask for the period
  # summary; the rest used to compute it (behind the rollup coverage guard)
  # and drop it in the render. These views don't render deltas either, so
  # they need the CURRENT window only — not the previous one.
  defp metric_task_if_read(%{live_action: :model} = params, opts), do: metric_task(params, opts)

  defp metric_task_if_read(%{live_action: :models, model_filter: id} = params, opts)
       when is_binary(id),
       do: metric_task(params, opts)

  defp metric_task_if_read(%{live_action: :group} = params, opts), do: metric_task(params, opts)

  defp metric_task_if_read(%{live_action: :groups, group_filter: id} = params, opts)
       when is_binary(id),
       do: metric_task(params, opts)

  defp metric_task_if_read(_params, _opts), do: []

  defp metric_task(params, opts) do
    [fn -> {:metrics, summary_to_metrics(fetch_current_summary(params, opts))} end]
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
    |> derive_series_labels()
  end

  # Bundle de la vista Router. Todo sale de `SmartRouter.Analytics` sobre la
  # MISMA ventana canónica del selector de período; la página no recalcula
  # ningún ahorro por su cuenta.
  #
  # Los insights NO son una consulta más: se derivan en memoria del resumen,
  # del semáforo de falsos ahorros y del mix de casos de uso que esta misma
  # carga ya pidió. Volver a llamar a `decision_insights/1` repetía esos tres
  # escaneos (los más caros del módulo) para tirar el resultado.
  defp compute_router_assigns(params) do
    filters = router_filters(params)

    bundle =
      [
        fn -> {:router_summary, Analytics.summary(filters)} end,
        fn -> {:router_use_cases, Analytics.use_case_breakdown(filters)} end,
        fn -> {:router_model_perf, Analytics.model_performance(filters)} end,
        fn -> {:router_vs_direct, Analytics.router_vs_direct_by_subject(filters)} end,
        fn -> {:router_attribution, Analytics.who_spent_on_what(filters)} end,
        fn -> {:router_signals, Analytics.false_savings_signals(filters)} end,
        fn -> {:router_sources, Analytics.decision_source_breakdown(filters)} end,
        fn -> {:router_shadow_comparison, Analytics.shadow_comparison(filters)} end
      ]
      |> run_parallel()
      |> Map.new()

    bundle
    |> Map.put(
      :router_insights,
      Analytics.decision_insights_from(
        bundle.router_summary,
        bundle.router_signals,
        bundle.router_use_cases
      )
    )
    |> put_shadow_migrations(filters, params[:shadow_config_id])
  end

  # The migration breakdown is only ever rendered for ONE version (the table is
  # per migration, not per version), so loading it is a second read — and only
  # when there is something to select. The version the operator asked for in
  # `?shadow_config_id=` wins; it falls back to the busiest version when the
  # param is absent or points at a version with no evaluations in the window.
  defp put_shadow_migrations(%{router_shadow_comparison: []} = bundle, _filters, _requested_id) do
    bundle
    |> Map.put(:router_shadow_migrations, [])
    |> Map.put(:router_shadow_selected_id, nil)
  end

  defp put_shadow_migrations(bundle, filters, requested_id) do
    rows = bundle.router_shadow_comparison

    selected = Enum.find(rows, &(&1.shadow_config_id == requested_id)) || hd(rows)

    Map.merge(bundle, %{
      router_shadow_migrations: Analytics.shadow_migrations(selected.shadow_config_id, filters),
      router_shadow_selected_id: selected.shadow_config_id
    })
  end

  defp router_filters(params) do
    %{from: from, to: to} = Periods.period_bounds(params.period, params.timezone)
    [from: from, to: to]
  end

  # drilldown_series_labels se deriva EN MEMORIA de la daily series que ya se
  # calculó — no de una segunda ejecución de la misma query.
  defp derive_series_labels(%{drilldown_series: series} = assigns) when is_list(series) do
    Map.put(
      assigns,
      :drilldown_series_labels,
      series |> Enum.map(& &1.label) |> Enum.uniq() |> Enum.sort()
    )
  end

  defp derive_series_labels(assigns), do: assigns

  defp period_opts(params) do
    %{from: from, to: to} = Periods.period_bounds(params.period, params.timezone)
    [from: from, to: to, timezone: params.timezone]
  end

  defp counter_tasks(params, opts) do
    [
      fn -> {:metrics, summary_to_metrics(fetch_current_summary(params, opts))} end,
      fn ->
        {:prev_metrics,
         summary_to_metrics(previous_summary(params, params.period, params.timezone))}
      end
    ]
  end

  # Both halves of the Resumen counters are shared between viewers: the
  # previous window for 60s (closed and immutable) and the current one for
  # `@counters_cache_ttl` (long enough to outlive the per-viewer 3s reload).
  # With N open overviews, the 3s tick used to run N pairs of hybrid
  # summaries — each with its rollup coverage guard — against the same pool
  # the proxy is using. Now it runs one pair per window.
  defp fetch_current_summary(params, opts) do
    if structural_cache_enabled?() do
      DashboardCache.fetch_or_compute(
        {:stats_current_summary, params.model_filter, params.group_filter, params.period,
         params.timezone, cache_scope(params)},
        fn -> fetch_summary(params, opts) end,
        ttl: @counters_cache_ttl
      )
    else
      fetch_summary(params, opts)
    end
  end

  # Cache-scope element. Admins share one global entry (`nil`); every other
  # role sees its own numbers, so the key carries the USER id — not the
  # membership ids: a user with no live membership has `[]`, the same list a
  # manager has, and both would collide with each other's answer.
  defp cache_scope(%{user: %{global_role: "admin"}}), do: nil
  defp cache_scope(%{user: %{id: id}}), do: {:user, id}
  defp cache_scope(_params), do: :anonymous

  # Fetch the previous period's summary for delta comparison.
  # `previous_period_bounds` handles the whole canonical set (today, yesterday,
  # week, 30d) plus the legacy builders; every one of them stays inside the
  # retention window.
  defp previous_summary(params, period, timezone) do
    cached_prev_summary(params, period, timezone)
  end

  defp do_previous_summary(params, period, timezone) do
    %{from: prev_from, to: prev_to} = Periods.previous_period_bounds(period, timezone)
    prev_opts = [from: prev_from, to: prev_to, timezone: timezone]
    fetch_summary(params, prev_opts)
  end

  # La ventana ANTERIOR está cerrada e inmutable: su resumen no cambia entre
  # recargas, pero el Resumen se recarga cada 3 s por visor (`logs:new`) y
  # cada uno re-ejecutaba este agregado. Va por DashboardCache con TTL de
  # 60 s —la misma ventana que el bundle estructural— y llave que lleva TODO
  # lo que cambia el resultado: filtros, período, timezone y scope. El
  # contador del período actual sigue sin caché (un KPI viejo se lee como
  # número roto).
  @prev_summary_cache_ttl 60_000

  defp cached_prev_summary(params, period, timezone) do
    if structural_cache_enabled?() do
      DashboardCache.fetch_or_compute(
        prev_summary_cache_key(params, period, timezone),
        fn -> do_previous_summary(params, period, timezone) end,
        ttl: @prev_summary_cache_ttl
      )
    else
      do_previous_summary(params, period, timezone)
    end
  end

  defp prev_summary_cache_key(params, period, timezone) do
    {:stats_prev_summary, params.model_filter, params.group_filter, period, timezone,
     cache_scope(params)}
  end

  # Merge prev_metrics into the :metrics map as delta percentages.
  defp merge_prev_metrics(%{metrics: metrics, prev_metrics: prev} = data) do
    deltas =
      metrics
      |> compute_deltas(prev)
      |> Map.put(:cost_per_req, cost_per_req_delta(metrics, prev))
      |> Map.put(:cache_hit_pp, cache_hit_delta(metrics, prev))

    Map.put(data, :metrics, Map.put(metrics, :deltas, deltas))
  end

  defp merge_prev_metrics(data), do: data

  defp cost_per_req_delta(%{requests_total: cur_n, cost_usd: cur_c}, %{
         requests_total: prev_n,
         cost_usd: prev_c
       })
       when cur_n > 0 and prev_n > 0 do
    cur_avg = Decimal.div(cur_c, Decimal.new(cur_n))
    prev_avg = Decimal.div(prev_c, Decimal.new(prev_n))
    decimal_pct_delta(cur_avg, prev_avg)
  end

  defp cost_per_req_delta(_, _), do: nil

  # Diferencia en puntos porcentuales del cache hit. Es un 0.0 REAL cuando las
  # dos ventanas tienen entrada y ningún acierto — `Stats.cache_hit_pct/2`
  # devuelve "0.0%" en ese caso, no "—" —, así que el delta sólo es nil cuando
  # falta denominador en alguna de las dos ventanas.
  defp cache_hit_delta(
         %{prompt_tokens: cur_p} = cur,
         %{prompt_tokens: prev_p} = prev
       )
       when cur_p > 0 and prev_p > 0 do
    cur_r = Map.get(cur, :cache_read_tokens, 0)
    prev_r = Map.get(prev, :cache_read_tokens, 0)
    cur_pct = cur_r / cur_p * 100
    prev_pct = prev_r / prev_p * 100
    Float.round(cur_pct - prev_pct, 1)
  end

  defp cache_hit_delta(_, _), do: nil

  # Run every query function concurrently and collect results in order.
  # Queries share the Repo pool, so wall time is pool rounds, not the sum of
  # every query — this is what makes period switching feel fast.
  #
  # Si una query explota (timeout de los scans crudos de 30d, DST, lo que
  # sea), se RE-ELEVA el motivo original: antes el {:exit, ...} no matcheaba
  # `{:ok, result}` y moría con FunctionClauseError — el log enmascaraba el
  # error real. handle_async ya sabe manejar {:exit, ...}: lo loguea y deja
  # los datos del periodo anterior visibles.
  defp run_parallel(fun_list) do
    fun_list
    # max_concurrency: 3 — lanzar 5+ escaneos fríos en paralelo contra un
    # pool de 10 los hace competir por conexiones y page cache: el 15s de
    # DBConnection incluye la espera en cola, no solo la ejecución.
    |> Task.async_stream(fn fun -> fun.() end,
      timeout: :infinity,
      max_concurrency: 3
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> exit({:stats_query_failed, reason})
    end)
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
        # Tampoco carga el card del gasto del día UTC: ese card vive en En vivo
        # (`live-org-budget`); con período "hoy" era el mismo card duplicado
        # con la misma query.
        # Con el período "Hoy" la gráfica de perfil horario mide el día UTC en
        # curso — la misma ventana que los KPI — y sale del agregado del día
        # (ver hour_usage_tasks/2), no del perfil del período.
        index_admin_tasks(admin?, params, opts) ++
          hour_usage_tasks(params, opts) ++
          [
            fn ->
              {:model_provider_stacked,
               StatsQueries.usage_by_model_provider_stacked(Keyword.put(opts, :limit, nil))}
            end,
            fn -> {:busiest_hours, StatsQueries.busiest_hours(nil, opts)} end,
            fn ->
              {:busiest_cost_hours,
               StatsQueries.busiest_hours(nil, Keyword.put(opts, :metric, :cost))}
            end,
            fn -> {:busiest_minutes, Rollup.busiest_minutes(nil, opts)} end,
            fn ->
              {:busiest_cost_minutes,
               Rollup.busiest_minutes(nil, Keyword.put(opts, :metric, :cost))}
            end
          ]

      :models ->
        # La pestaña es la tabla de consumo por modelo. El drill-down por query
        # string (?model_id=) sigue vivo como ALIAS del detalle: los enlaces que
        # ya existen (proveedor, perfil de límites, servicio) entran por ahí y renderizan la
        # misma vista que `/stats/models/:id`, con las mismas queries.
        case params.model_filter do
          nil ->
            # Sin ranking: la tabla muestra el consumo, y el tier/score (que sale
            # del ranking) vive en la cabecera del detalle, que sí la carga.
            # Lectura híbrida: el rollup responde los buckets de hora completos
            # y sólo la cola (≤3h) va cruda — con el guard de cobertura de
            # StatsQueries, que reconcilia conteos y cae al crudo completo de la
            # ventana si el rollup no cubre el tramo cerrado.
            [fn -> {:breakdown_model, StatsQueries.breakdown_by_model(nil, opts)} end]

          model_id ->
            model_detail_tasks(model_id, params.user, opts)
        end

      :model ->
        # Interior de la tabla de modelos: métricas del modelo, los proveedores
        # que lo sirven y quién lo usa (perfiles de límites y miembros).
        model_detail_tasks(params.model_filter, params.user, opts)

      :providers ->
        # Sección Infra nueva: destino del ranking de proveedores.
        [fn -> {:provider_ranking, Rollup.provider_ranking(nil, opts)} end]

      :agents ->
        # Identidad del agente normalizada en LECTURA (sin migración ni
        # backfill): la query devuelve los buckets crudos y acá se mergean
        # por agente canónico. Un solo scan del período por bundle cacheado.
        [fn -> {:agent_ranking, TokengateWeb.StatsLive.Agents.build_ranking(opts)} end]

      :agent ->
        [fn -> {:agent_detail, Rollup.agent_detail(params.agent_key, opts)} end]

      :provider ->
        # Interior de la tabla de proveedores: métricas del proveedor, los
        # modelos que sirve y quién lo usa (usuarios, servicios, perfiles de límites).
        provider_id = params.provider_id
        admin? = params.user.global_role == "admin"

        if is_nil(provider_id) do
          [fn -> {:provider, nil} end]
        else
          [
            fn -> {:provider, Tokengate.Providers.get_provider(provider_id)} end,
            # El ranking completo entra para tomar de ahí tier/score/p95/fallos:
            # la fila de la tabla y el detalle no pueden decir cosas distintas.
            fn -> {:provider_ranking, Rollup.provider_ranking(nil, opts)} end,
            fn -> {:provider_metrics, provider_metrics(provider_id, opts)} end,
            fn ->
              {:drilldown_series, Rollup.daily_series_by_model_for_provider(provider_id, opts)}
            end,
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
        end

      :groups ->
        admin? = params.user.global_role == "admin"

        case params.group_filter do
          nil ->
            [
              fn -> {:breakdown_group, breakdown_by_group_if_admin(admin?, opts)} end
            ] ++
              if admin? do
                [fn -> {:group_budgets, Budgets.list_group_budgets(params.timezone)} end]
              else
                []
              end

          group_id ->
            group_detail_tasks(group_id, params.user, params.timezone, opts)
        end

      :group ->
        group_detail_tasks(params.group_id, params.user, params.timezone, opts)

      :users ->
        [
          # Híbrido por identidad durable (`user_id` del bucket): el histórico
          # de una membresía rotada sigue apareciendo bajo su usuario.
          fn -> {:breakdown_user, StatsQueries.breakdown_by_user(opts)} end,
          fn -> {:budgets_by_user, Budgets.spend_by_user(params.timezone)} end
        ]

      :services ->
        admin? = params.user.global_role == "admin"

        # Services have a dedicated service_id column. El detalle completo
        # vive en /stats/services/:service_id (navegación, no drilldown).
        [fn -> {:service_budgets, Budgets.list_service_budgets()} end] ++
          [fn -> {:breakdown_service, breakdown_by_service_if_admin(admin?, opts)} end]

      :finops ->
        # Economía del período en cuatro lecturas acotadas (overview, serie,
        # capabilities y dispersión), todas de la misma ventana canónica. La
        # ruta es admin-only; el guard mantiene el bundle coherente si la
        # acción se reusara desde una vista con scope.
        if params.user.global_role == "admin" do
          # "Hoy"/"Ayer" se leen por hora: en el día, un punto por día no dice
          # nada. El resto, por día.
          granularity = if params.period in ["today", "yesterday"], do: :hour, else: :day

          # Filtros de la sección: bajar de una burbuja (modelo, proveedor,
          # usuario o servicio) a "quién gastó en esto" sin salir de FinOps.
          opts =
            opts
            |> put_finops_filter(:model_id, params.model_filter)
            |> put_finops_filter(:provider_id, params[:provider_id])
            |> put_finops_filter(:user_id, params[:finops_user_id])
            |> put_finops_filter(:service_id, params[:finops_service_id])

          [
            fn -> {:finops_overview, Rollup.finops_overview(opts)} end,
            fn ->
              {:finops_series,
               Rollup.finops_subject_series(
                 Keyword.merge(opts, granularity: granularity, timezone: params.timezone)
               )}
            end,
            fn -> {:finops_request_types, Rollup.finops_request_type_breakdown(opts)} end,
            fn -> {:finops_scatter, Rollup.finops_subject_scatter(opts)} end,
            fn -> {:finops_models, Rollup.finops_entity_scatter(:model, opts)} end,
            fn -> {:finops_providers, Rollup.finops_entity_scatter(:provider, opts)} end
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
  # perfiles de límites/miembros que lo usan son los MISMOS tres desgloses que ya tenía el
  # drill-down: acá sólo cambia de dónde entran.
  defp model_detail_tasks(nil, _user, _opts), do: [fn -> {:model, nil} end]

  defp model_detail_tasks(model_id, user, opts) do
    admin? = user.global_role == "admin"

    [
      fn -> {:model, Tokengate.Providers.get_model(model_id)} end,
      # El ranking completo entra para tomar de ahí tier/score/p95/fallos: la
      # fila de la tabla y el detalle no pueden decir cosas distintas (mismo
      # criterio que el detalle de proveedor).
      fn -> {:model_ranking, Rollup.model_ranking(nil, opts)} end,
      fn -> {:breakdown_provider, Rollup.breakdown_by_provider_for_model(model_id, opts)} end,
      fn -> {:breakdown_group, breakdown_group_for_model(user, model_id, opts)} end,
      fn -> {:breakdown_member, Rollup.breakdown_by_member_for_model(model_id, opts)} end,
      fn ->
        {:breakdown_service,
         if(admin?, do: Rollup.breakdown_by_service_for_model(model_id, opts), else: [])}
      end,
      fn -> {:breakdown_agent, Rollup.breakdown_by_agent_for_model(model_id, opts)} end,
      fn -> {:drilldown_series, Rollup.daily_series_by_provider_for_model(model_id, opts)} end
    ]
  end

  # Detalle de un perfil de límites: mismo bundle tanto para la ruta propia
  # (`/stats/profiles/:id`, action `:group`) como para el alias `?group_id=`
  # de la pestaña Perfiles de límites.
  defp group_detail_tasks(nil, _user, _timezone, _opts), do: [fn -> {:group, nil} end]

  defp group_detail_tasks(group_id, user, timezone, opts) do
    if group_drilldown_allowed?(user, group_id) do
      [
        fn -> {:group, Accounts.get_group(group_id)} end,
        fn ->
          {:group_budget, Budgets.list_group_budgets(timezone) |> find_group_budget(group_id)}
        end,
        fn -> {:breakdown_member, Rollup.breakdown_by_member(group_id, opts)} end,
        fn -> {:breakdown_model, Rollup.breakdown_by_model(group_id, opts)} end,
        # Una sola ejecución: drilldown_series_labels se deriva en memoria
        # del mismo resultado (la query era idéntica y corría dos veces).
        fn -> {:drilldown_series, Rollup.daily_series_by_model_for_group(group_id, opts)} end
      ]
    else
      [fn -> {:group, nil} end]
    end
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
    [fn -> {:hour_usage_by_provider, StatsQueries.usage_by_hour_of_day_by_provider(opts)} end]
  end

  # Admin-only infra/org-wide queries on the index view. Ahora el Resumen solo
  # conserva el pico de concurrencia (admin): rankings y tiers viven en las
  # secciones models / groups / providers.
  # Filtro opcional de FinOps: `nil`/`"all"` no filtran; un uuid sí.
  defp put_finops_filter(opts, _key, nil), do: opts
  defp put_finops_filter(opts, _key, "all"), do: opts
  defp put_finops_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp index_admin_tasks(true, params, opts) do
    [
      fn -> {:peak_concurrency, Rollup.peak_concurrency(nil, opts)} end,
      daily_series_task(params, opts),
      fn ->
        {:top_agents,
         opts
         |> TokengateWeb.StatsLive.Agents.build_ranking()
         |> Enum.take(5)}
      end,
      fn -> {:top_consumers, compute_top_consumers(opts)} end
    ]
  end

  defp index_admin_tasks(false, _params, _opts), do: []

  # La serie diaria sólo la pinta la tarjeta "Tendencia diaria por proveedor",
  # que únicamente aparece en ventanas de varios días (week / 30d). Con
  # "Hoy"/"Ayer" el Resumen dibuja el perfil horario, así que escanear el
  # período por día era trabajo que el render tiraba en cada carga.
  defp daily_series_task(%{period: period}, opts) when period in ["week", "30d"],
    do: fn -> {:daily_series, StatsQueries.daily_series_by_provider(opts)} end

  defp daily_series_task(_params, _opts), do: fn -> {:daily_series, []} end

  defp compute_top_consumers(opts) do
    users =
      StatsQueries.breakdown_by_user(opts)
      |> Enum.map(fn u ->
        %{
          subject_type: "user",
          subject_id: u.user_id,
          label: u.user_name || u.user_email,
          sublabel: if(u.user_name, do: u.user_email, else: nil),
          request_count: u.request_count,
          error_count: Map.get(u, :error_count, 0),
          cost_usd: u.cost_usd
        }
      end)

    services =
      Rollup.breakdown_by_service(opts)
      |> Enum.map(fn s ->
        %{
          subject_type: "service",
          subject_id: s.service_id,
          label: s.service_name,
          sublabel: nil,
          request_count: s.request_count,
          error_count: Map.get(s, :error_count, 0),
          cost_usd: s.cost_usd
        }
      end)

    (users ++ services)
    |> Enum.sort(fn a, b ->
      case Decimal.compare(a.cost_usd, b.cost_usd) do
        :eq -> a.request_count >= b.request_count
        :gt -> true
        :lt -> false
      end
    end)
    |> Enum.take(8)
  end

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
      breakdown_agent: [],
      breakdown_user: [],
      agent_ranking: [],
      agent_detail: nil,
      provider_ranking: [],
      provider: nil,
      provider_metrics: empty_provider_metrics(),
      model_ranking: [],
      group: nil,
      hour_usage_by_provider: [],
      model_provider_stacked: [],
      daily_series: [],
      top_agents: [],
      top_consumers: [],
      busiest_hours: [],
      busiest_cost_hours: [],
      busiest_minutes: [],
      busiest_cost_minutes: [],
      peak_concurrency: nil,
      model: nil,
      drilldown_series: [],
      drilldown_series_labels: [],
      org_budget: nil,
      budgets_by_user: %{},
      service_budgets: [],
      group_budgets: [],
      group_budget: nil,
      router_summary: nil,
      router_use_cases: [],
      router_model_perf: [],
      router_vs_direct: [],
      router_attribution: [],
      router_signals: nil,
      router_insights: [],
      router_sources: [],
      router_shadow_comparison: [],
      router_shadow_migrations: [],
      router_shadow_selected_id: nil,
      finops_overview: nil,
      finops_series: [],
      finops_request_types: [],
      finops_scatter: [],
      finops_models: [],
      finops_providers: []
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

  # Mismo criterio de scoping para los perfiles de límites que usan un proveedor.
  defp breakdown_by_group_for_provider(user, provider_id, opts) do
    case Accounts.scope_group_ids(user) do
      nil -> Rollup.breakdown_by_group(Keyword.put(opts, :provider_id, provider_id))
      [] -> []
    end
  end

  # Costo y tokens del proveedor en el período. La confiabilidad (tier, score,
  # p95, fallos) NO se recalcula acá: sale de la fila del ranking, que es la
  # misma que pinta la tabla de proveedores.
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

  defp breakdown_by_group_if_admin(true, opts), do: StatsQueries.breakdown_by_group(opts)
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
    # Durable identity, NOT the current memberships: a rotated membership
    # (key/member re-created for the same user) must keep its historical spend
    # in the KPI. `request_logs.user_id` / the rollup's `user_id` column carry
    # it; `group_member_ids` would silently drop everything logged under the
    # old membership. A user with no live membership still answers (their
    # rotated history), so no empty-list short-circuit here.
    opts
    |> Map.new()
    |> Map.put(:user_ids, [user.id])
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

      true ->
        base
    end
  end

  ## "En vivo" data ---------------------------------------------------------

  # Coalesce: un :reload_pulse pendiente absorbe todos los `logs:new` que
  # lleguen mientras tanto (flag por visor, cadencia la del tab).
  defp schedule_pulse_refresh(socket) do
    if socket.assigns[:pulse_scheduled] do
      socket
    else
      Process.send_after(self(), :reload_pulse, @live_refresh_interval_ms)
      assign(socket, :pulse_scheduled, true)
    end
  end

  # El pulso es global (sin filtros de usuario): una entrada compartida sirve
  # a todos los visores del tab. El TTL (3.5s) sobrevive al tick de 3s, así
  # que todos los visores de una ventana leen el MISMO cálculo en vez de
  # re-escanear la ventana cada uno.
  defp live_pulse do
    DashboardCache.fetch_or_compute(
      {:stats_live_pulse},
      fn -> Logs.realtime_summary(%{}) end,
      ttl: @pulse_cache_ttl_ms
    )
  end

  defp live_drivers do
    DashboardCache.fetch_or_compute(
      {:stats_live_drivers},
      fn -> Logs.live_cost_drivers(15, 5) end,
      ttl: @pulse_cache_ttl_ms
    )
  end

  defp yesterday_pace do
    DashboardCache.fetch_or_compute(
      {:stats_live_yesterday_pace},
      fn -> Logs.yesterday_same_elapsed_summary() end,
      ttl: 60_000
    )
  end

  # One bundled realtime refresh. The day partition is scanned ONCE per
  # cache cycle (flat KPI totals + hour × provider profile + budget spend
  # all come out of `Logs.today_live_bundle/0`; it used to be three scans)
  # and shared across connected live tabs via the DashboardCache TTL so a
  # busy proxy doesn't multiply Postgres load.
  defp load_live_data(socket) do
    # El p95 del día ordena TODA la partición del día (y crece con ella):
    # fuera del camino de 5s, con TTL propio de 60s.
    p95_latency_ms =
      DashboardCache.fetch_or_compute(
        {:stats_live_p95},
        fn -> Logs.today_p95_latency_ms("Etc/UTC") end,
        ttl: 60_000
      )

    bundle =
      DashboardCache.fetch_or_compute({:stats_live}, fn ->
        # KPIs "Hoy" = día UTC (misma ventana que el kill-switch y que el
        # card de tope de arriba) — no el día local del usuario. UN solo
        # scan del día alimenta los totales planos, el perfil hora ×
        # proveedor y el gasto del tope.
        live = Logs.today_live_bundle()

        # Gasto real del día UTC — el mismo número que muestra Mantenimiento
        # y que el card de arriba. Día UTC y no local: el KPI de costo y el
        # histórico del día se leen sobre la misma ventana. Nada de contador
        # ETS (holds): el spend sale del scan del día (`cost_usd` del bundle).
        org_budget = %{daily_spend_usd: live.today.cost_usd}

        %{
          today_metrics: live.today,
          minute_series: Logs.requests_per_minute(60),
          day_by_hour: live.day_by_hour,
          org_budget: org_budget
        }
      end)

    # El feed inicial se monta UNA vez por proceso: los refrescos
    # (:reload_live, :live_tick) ya no re-traen list_logs — el broadcast
    # {:new_log, log} inserta cada request nueva en el stream en tiempo
    # real, y refrescar los KPIs no cambia el contenido del feed.
    socket =
      if socket.assigns[:live_feed_loaded] do
        socket
      else
        feed_logs = Logs.list_feed(%{limit: @live_feed_size})

        socket
        |> stream(:live_feed, feed_logs, reset: true)
        |> assign(:live_feed_loaded, true)
      end

    minute_series = bundle.minute_series

    socket
    |> assign(:stats_loading, false)
    |> assign(:pulse, live_pulse())
    |> assign(:live_drivers, live_drivers())
    |> assign(:yesterday_pace, yesterday_pace())
    # El p95 va aparte del bundle: vive en su propio cache de 60s y no se
    # congela dentro del bundle de 5s.
    |> assign(:today_metrics, Map.put(bundle.today_metrics, :p95_latency_ms, p95_latency_ms))
    |> assign(:minute_series, minute_series)
    |> assign(:minute_series_max, minute_requests_max(minute_series))
    |> assign(:minute_tokens_max, minute_tokens_max(minute_series))
    |> assign(:minute_cost_max, minute_cost_max(minute_series))
    |> assign(:org_budget, bundle.org_budget)
    |> assign(:inflight_count, Inflight.count())
    |> assign(:day_by_hour, bundle.day_by_hour)
    |> assign(:last_sync_at, DateTime.utc_now())
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

  # The period lives in the URL; anything outside the canonical vocabulary
  # (`?period=month`, `last_month`, `7d`, a forged value) degrades to the
  # canonical default (week) instead of being reinterpreted as another window.
  # A missing param keeps the page's own default (today).
  defp cast_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp cast_uuid(_), do: nil

  defp parse_period(nil), do: "today"
  defp parse_period(period), do: Periods.normalize_period(period)

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

  defp scope_label_for(%{global_role: "admin"}), do: gettext("Whole organization")

  defp scope_label_for(%{global_role: "user"}), do: gettext("Your usage")

  defp scope_label_for(_), do: "—"
end
