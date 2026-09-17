defmodule TokengateWeb.DashboardLive do
  @moduledoc """
  Real-time metrics dashboard — personal overview only.

  Scope is always personal: every user sees only their own consumption,
  regardless of global role. Data comes from durable Postgres rollups.

  All metrics are fetched from Postgres (`request_logs`) via
  `Tokengate.Logs` and `Tokengate.Metrics.Rollup`. Results are cached in
  the `Tokengate.Metrics.DashboardCache` ETS table (5s TTL) so that
  multiple connected dashboards for the same user share one set of
  Postgres queries instead of re-querying on every PubSub broadcast.

  Real-time updates come from `Phoenix.PubSub` on the `"metrics:updated"`
  topic (broadcast by `Tokengate.Metrics.Collector.record_request/1`).
  On `{:metrics_updated, _}` the LiveView debounces and re-reads from
  cache — a cache hit skips all Postgres queries.

  A period selector lets the user choose: Hoy (24h), 7d, 30d, 90d.
  All UI strings are in Spanish (the app's UI language).
  """

  use TokengateWeb, :live_view

  import TokengateWeb.AdminComponents
  import TokengateWeb.KpiHelpers, only: [kpi_cards: 1]
  import TokengateWeb.KeysPanel

  alias Tokengate.Accounts
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Periods
  alias Tokengate.Providers
  alias Tokengate.Providers.Model
  alias TokengateWeb.KpiHelpers
  alias TokengateWeb.StatsHelpers, as: Stats

  @pubsub Tokengate.PubSub
  @metrics_topic "metrics:updated"
  @reload_interval_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, "Dashboard · Tokengate")
      |> assign(:is_admin, user.global_role == "admin")
      |> assign(:loading, true)
      |> assign(:displayed_period, nil)
      |> assign(:reload_scheduled, false)
      |> assign(:period, "today")
      |> assign(:metrics, empty_metrics())
      |> assign(:cost_series, [])
      |> assign(:requests_series, [])
      |> assign(:tokens_series, [])
      |> assign(:tps_series, [])
      |> assign(:top_models, [])
      |> assign(:top_groups, [])
      |> assign(:top_members, [])
      |> assign(:breakdown_model, [])
      |> assign(:breakdown_member, [])
      |> assign(:breakdown_group, [])
      |> assign(:active_breakdown, "model")
      |> assign(:scope_label, "Personal")
      |> assign(:scope_member_ids, user_member_ids(user))
      |> assign(:new_token, nil)
      |> assign(:new_token_group, nil)
      |> assign(:supervised_services_count, count_supervised_services(user))
      |> assign(:model_marks, %{})
      |> assign(:keys_modal_open, false)
      |> assign(:keys, [])
      |> assign(:keys_spend, %{})
      |> assign(:new_key_token, nil)
      |> load_personal_data(user)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @metrics_topic)

      # Countdown del reinicio del tope global: minuto-granular y sin tráfico,
      # igual que en /stats. El `:reload_metrics` de arriba depende de la
      # pubsub, así que con el proxy quieto el contador se quedaría congelado.
      schedule_clock_tick()
    end

    # Mount is synchronous: the static render and the test client both
    # expect data to be present right after `live/2`. The async path is
    # reserved for period switches and background reloads (below).
    socket =
      socket
      |> assign_budget_reset()
      |> load_metrics_sync(user)

    {:ok, socket}
  end

  @impl true
  def handle_params(unsigned_params, _uri, socket) do
    case Map.get(unsigned_params, "period") do
      period when period in ~w(today 7d 30d 90d) ->
        {:noreply,
         socket |> assign(:period, period) |> load_metrics_async(socket.assigns.current_user)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:metrics_bundle, {:ok, {period, bundle}}, socket) do
    # Stale-result guard: the user may have switched periods again while this
    # task was in flight. The newest request owns the socket; late arrivals
    # are dropped so an older period never overwrites a newer one.
    if socket.assigns[:period] == period do
      {:noreply, apply_metrics_bundle(socket, bundle)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:metrics_bundle, {:exit, reason}, socket) do
    require Logger
    Logger.warning("dashboard metrics async load failed: #{inspect(reason)}")
    {:noreply, assign(socket, :loading, false)}
  end

  @impl true
  def handle_info({:metrics_updated, _lite}, socket) do
    # Coalesce reloads: every proxied request broadcasts on this topic, so a
    # busy proxy would otherwise trigger a full Postgres reload per request
    # per connected dashboard. Cap at one reload per @reload_interval_ms.
    if socket.assigns[:reload_scheduled] do
      {:noreply, socket}
    else
      Process.send_after(self(), :reload_metrics, @reload_interval_ms)
      {:noreply, assign(socket, :reload_scheduled, true)}
    end
  end

  def handle_info(:reload_metrics, socket) do
    user = socket.assigns[:current_user]

    {:noreply,
     socket
     |> assign(:reload_scheduled, false)
     |> load_metrics_async(user)}
  end

  # Minute-aligned tick for the budget-reset countdown only. Re-assigning an
  # unchanged value is a no-op in `assign/3`, so this costs a re-render just
  # when the minute (or the midnight rollover) actually changes.
  def handle_info(:clock_tick, socket) do
    schedule_clock_tick()
    {:noreply, assign_budget_reset(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Scope helpers ----------------------------------------------------------
  # ---------------------------------------------------------------------------

  # User-wide scope: EVERY user (admin included) sees only their own
  # memberships on /dashboard. The org-wide view lives in /stats.
  defp user_member_ids(user) do
    user.id |> Accounts.list_group_members_for_user() |> Enum.map(& &1.id)
  end

  # Count of services the user supervises (read-only role). Used to show a
  # shortcut card on /dashboard when > 0.
  defp count_supervised_services(user) do
    Accounts.count_services_for_supervisor(user.id)
  end

  @impl true
  def handle_event("replace_key", %{"id" => member_id}, socket) do
    user = socket.assigns[:current_user]

    case Enum.find(socket.assigns[:memberships], &(&1.id == member_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "No autorizado.")}

      member ->
        case Accounts.replace_api_key(member) do
          {:ok, _api_key, new_token} ->
            {:noreply,
             socket
             |> assign(:new_token, new_token)
             |> assign(:new_token_group, member.group.name)
             |> load_personal_data(user)
             |> put_flash(:info, "Clave regenerada correctamente.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "No se pudo regenerar la clave.")}
        end
    end
  end

  def handle_event("revoke_key", %{"id" => member_id}, socket) do
    user = socket.assigns[:current_user]

    case Enum.find(socket.assigns[:memberships], &(&1.id == member_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "No autorizado.")}

      member ->
        case member.api_key do
          nil ->
            {:noreply, put_flash(socket, :error, "Esta membresía no tiene clave.")}

          api_key ->
            case Accounts.revoke_api_key(api_key) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> load_personal_data(user)
                 |> put_flash(:info, "Clave revocada.")}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "No se pudo revocar la clave.")}
            end
        end
    end
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  ## Events — mis claves API (N claves con etiqueta del usuario logueado) ----

  # La gestión es SIEMPRE del usuario logueado: el `current_user` del socket fija
  # el dueño, nunca un id que venga del cliente. Reutiliza el panel compartido
  # (`KeysPanel`) para tener la misma UX que la página admin de usuarios.
  @impl true
  def handle_event("manage_keys", _params, socket) do
    user = socket.assigns[:current_user]

    {:noreply,
     socket
     |> assign(:keys_modal_open, true)
     |> assign(:new_key_token, nil)
     |> load_user_keys(user.id)}
  end

  def handle_event("cancel_manage_keys", _params, socket) do
    {:noreply,
     socket
     |> assign(:keys_modal_open, false)
     |> assign(:keys, [])
     |> assign(:keys_spend, %{})
     |> assign(:new_key_token, nil)}
  end

  def handle_event("create_key", %{"key" => key_params}, socket) do
    user = socket.assigns[:current_user]
    {token, key_hash, key_prefix} = Accounts.generate_api_key_material()

    attrs = %{
      "subject_type" => "member",
      "user_id" => user.id,
      "label" => String.trim(key_params["label"] || ""),
      "key_hash" => key_hash,
      "key_prefix" => key_prefix,
      "status" => "active"
    }

    attrs = if attrs["label"] == "", do: Map.delete(attrs, "label"), else: attrs

    case Accounts.create_api_key(attrs) do
      {:ok, api_key} ->
        Tokengate.Auditing.audit(
          user,
          "api_key.create",
          "api_key",
          api_key.id,
          %{"label" => api_key.label, "user_id" => user.id, "origin" => "dashboard"}
        )

        {:noreply,
         socket
         |> assign(:new_key_token, token)
         |> put_flash(:info, "Clave creada. Cópiala ahora: no se vuelve a mostrar.")
         |> load_user_keys(user.id)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "No se pudo crear la clave.")}
    end
  end

  def handle_event("revoke_user_key", %{"key-id" => api_key_id}, socket) do
    user = socket.assigns[:current_user]

    # Solo las claves del propio usuario: el id llega del cliente, así que se
    # verifica la propiedad antes de revocar.
    with %{} = api_key <- Accounts.get_api_key(api_key_id),
         true <- api_key.user_id == user.id do
      case Accounts.revoke_api_key(api_key) do
        {:ok, _} ->
          Tokengate.Auditing.audit(
            user,
            "api_key.revoke",
            "api_key",
            api_key.id,
            %{"label" => api_key.label, "user_id" => user.id, "origin" => "dashboard"}
          )

          {:noreply,
           socket
           |> put_flash(:info, "Clave revocada.")
           |> load_user_keys(user.id)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo revocar la clave.")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Clave no encontrada.")}
    end
  end

  def handle_event("dismiss_new_key_token", _params, socket) do
    {:noreply, assign(socket, :new_key_token, nil)}
  end

  def handle_event("clear_user_sticky_routes", _params, socket) do
    user = socket.assigns[:current_user]
    Accounts.clear_user_sticky_routes(user.id)

    Tokengate.Auditing.audit(
      user,
      "routing.clear_sticky",
      "user",
      user.id,
      %{"origin" => "dashboard"}
    )

    {:noreply,
     socket
     |> put_flash(:info, "Sticky routes limpiadas. Tu próxima petición se re-ruteará.")
     |> load_user_keys(user.id)}
  end

  ## Events — period selector -----------------------------------------------

  @impl true
  def handle_event("set_period", %{"period" => period}, socket)
      when period in ~w(today 7d 30d 90d) do
    user = socket.assigns[:current_user]
    {:noreply, socket |> assign(:period, period) |> load_metrics_async(user)}
  end

  def handle_event("set_breakdown", %{"tab" => tab}, socket)
      when tab in ~w(model member group) do
    {:noreply, assign(socket, :active_breakdown, tab)}
  end

  ## Data loading ---------------------------------------------------------

  # Horas/minutos que faltan para el reinicio del tope global (00:00 UTC) y el
  # instante del reinicio. Misma semántica que /stats: la duración es
  # independiente de la zona; `reset_at` se muestra en la hora del usuario.
  defp assign_budget_reset(socket) do
    reset_at = Periods.next_utc_day_start(Periods.now_utc())
    {hours, minutes} = Stats.countdown_parts(reset_at)

    socket
    |> assign(:budget_reset_hours, hours)
    |> assign(:budget_reset_minutes, minutes)
    |> assign(:budget_reset_at, reset_at)
  end

  # Wakes just after the wall-clock minute turns so the countdown label is
  # never more than a second stale.
  defp schedule_clock_tick do
    ms = 60_000 - rem(System.system_time(:millisecond), 60_000)
    Process.send_after(self(), :clock_tick, ms)
  end

  defp load_personal_data(socket, user) do
    memberships = Accounts.list_group_members_for_user(user.id)

    # El resumen del sujeto (límite efectivo + top-ups) se resuelve en lote:
    # una pasada para todas las membresías.
    summaries = Tokengate.Credits.summaries(memberships)

    groups =
      Enum.map(memberships, fn membership ->
        summary = Map.get(summaries, membership.id)

        %{
          membership: membership,
          group: membership.group,
          api_key: membership.api_key,
          monthly_limit: summary && summary.limit_usd,
          monthly_spend: (summary && summary.spend_usd) || Decimal.new(0),
          credit: summary
        }
      end)

    # Admins always see the full org-wide dashboard. Regular users need at
    # least one group membership to access API keys, endpoint info, and metrics.
    has_access = user.global_role == "admin" or groups != []

    socket
    |> assign(:memberships, memberships)
    |> assign(:groups, groups)
    |> assign(:has_access, has_access)
  end

  # Keys activas del usuario logueado + consumo por key (una sola query por
  # lote). Se cargan solo al abrir el modal: el dashboard no paga el costo en
  # cada render.
  defp load_user_keys(socket, user_id) do
    keys = Accounts.list_api_keys_for_user(user_id)
    spend = Accounts.spend_by_api_key(Enum.map(keys, & &1.id))

    socket
    |> assign(:keys, keys)
    |> assign(:keys_spend, spend)
  end

  # Synchronous load used at mount (static render + tests need the data
  # right after `live/2`). Cache hit applies directly; miss computes inline.
  defp load_metrics_sync(socket, user) do
    period = socket.assigns[:period] || "today"
    timezone = socket.assigns[:timezone] || "Etc/UTC"
    cache_key = DashboardCache.build_key(user.id, period, timezone)
    member_ids = socket.assigns[:scope_member_ids] || []

    bundle =
      DashboardCache.fetch_or_compute(cache_key, fn ->
        compute_metrics_bundle(member_ids, period, timezone)
      end)

    apply_metrics_bundle(socket, bundle)
  end

  # Event-path load (period switches + background reloads).
  #
  # Fast path: a DashboardCache hit applies the bundle synchronously — zero
  # Postgres queries, so the click reply carries the fresh render.
  #
  # Slow path: a cache miss (every first visit to a period within the 5s
  # TTL) dispatches the Postgres work to `start_async/3` so the click
  # replies instantly while `loading: true`; the bundle lands via
  # `handle_async/3`. The task closure captures only plain values (user id,
  # period, timezone, member ids) — never the socket.
  defp load_metrics_async(socket, user) do
    period = socket.assigns[:period] || "today"
    timezone = socket.assigns[:timezone] || "Etc/UTC"
    cache_key = DashboardCache.build_key(user.id, period, timezone)
    member_ids = socket.assigns[:scope_member_ids] || []

    case DashboardCache.fetch(cache_key) do
      {:ok, bundle} ->
        apply_metrics_bundle(socket, bundle)

      :miss ->
        socket
        |> assign(:loading, true)
        |> start_async(:metrics_bundle, fn ->
          bundle =
            DashboardCache.fetch_or_compute(cache_key, fn ->
              compute_metrics_bundle(member_ids, period, timezone)
            end)

          {period, bundle}
        end)
    end
  end

  # Computes the full metrics bundle from Postgres. This is the expensive
  # path — called only on cache miss, inside the async task. Runs on plain
  # values (no socket) so it is safe to execute in another process.
  defp compute_metrics_bundle(member_ids, period, timezone) do
    %{from: from, to: to} = Periods.period_bounds(period, timezone)
    opts = [from: from, to: to]

    # Summary
    summary = fetch_summary(member_ids, opts)

    # Delta vs the previous equivalent period (same shape as /stats KPIs).
    prev_summary = fetch_prev_summary(member_ids, period, timezone)
    deltas = compute_deltas(summary, prev_summary)

    metrics = %{
      requests_total: summary.request_count,
      errors_total: 0,
      error_rate: 0.0,
      cost_usd: summary.total_cost_usd,
      prompt_tokens: summary.total_prompt_tokens,
      completion_tokens: summary.total_completion_tokens,
      cache_read_tokens: summary.total_cache_read_tokens,
      cache_creation_tokens: summary.total_cache_creation_tokens,
      avg_latency_ms: Map.get(summary, :avg_latency_ms) || 0.0,
      avg_ttft_ms: Map.get(summary, :avg_ttft_ms),
      avg_tps: Map.get(summary, :avg_tps),
      deltas: deltas
    }

    # Chart series
    series =
      if member_ids == [] do
        []
      else
        hourly_series_for_members(member_ids, opts, timezone)
      end

    series_with_tps =
      Enum.map(series, fn row ->
        tps =
          if row.total_latency_ms > 0 do
            row.completion_tokens / (row.total_latency_ms / 1000.0)
          else
            0.0
          end

        Map.put(row, :tps, tps)
      end)

    cost_series = to_chart_points(series_with_tps, period, :cost_usd, &usd_tooltip/1, timezone)

    requests_series =
      to_chart_points(series_with_tps, period, :request_count, &requests_tooltip/1, timezone)

    tokens_series = to_token_points(series_with_tps, period, timezone)
    tps_series = to_chart_points(series_with_tps, period, :tps, &tps_tooltip/1, timezone)

    # Breakdowns
    breakdown_opts = Keyword.put(opts, :member_ids, member_ids)
    breakdown_model = Rollup.breakdown_by_model(nil, breakdown_opts)
    breakdown_member = Rollup.breakdown_by_member(nil, breakdown_opts)

    # Model usage stats

    %{
      metrics: metrics,
      cost_series: cost_series,
      requests_series: requests_series,
      tokens_series: tokens_series,
      tps_series: tps_series,
      breakdown_model: breakdown_model,
      model_marks: model_marks_for(breakdown_model),
      top_models: top_model_rows(breakdown_model),
      breakdown_member: breakdown_member,
      top_members: top_member_rows(breakdown_member)
    }
  end

  # Marca de cada modelo del desglose, resuelta en lote: `%{model_id => mark}`.
  # El desglose sale de los logs y solo trae id + nombre; la marca (logo del lab
  # o su icono de reserva) vive en el catálogo, así que se resuelve con una query
  # de modelos por id y un índice de labs — nunca una consulta por fila.
  defp model_marks_for(breakdown_model) do
    ids =
      breakdown_model
      |> Enum.map(& &1.model_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      labs_by_key = Map.new(Providers.list_labs(), &{&1.key, &1})

      ids
      |> Providers.models_by_ids()
      |> Map.new(fn model -> {model.id, Model.mark(model, labs_by_key)} end)
    end
  end

  # Applies the cached (or freshly computed) metrics bundle to the socket.
  # This is the cheap path — no Postgres queries, just assigns. Also records
  # which period is now on screen: the template shows the full-screen
  # spinner only on the very first load (`displayed_period == nil`); later
  # period switches and background reloads keep the old data visible while
  # the new bundle arrives.
  defp apply_metrics_bundle(socket, bundle) do
    socket
    |> assign(:metrics, bundle.metrics)
    |> assign(:cost_series, bundle.cost_series)
    |> assign(:requests_series, bundle.requests_series)
    |> assign(:tokens_series, bundle.tokens_series)
    |> assign(:tps_series, bundle.tps_series)
    |> assign(:breakdown_model, bundle.breakdown_model)
    |> assign(:model_marks, Map.get(bundle, :model_marks, %{}))
    |> assign(:top_models, bundle.top_models)
    |> assign(:breakdown_member, bundle.breakdown_member)
    |> assign(:top_members, bundle.top_members)
    |> assign(:breakdown_group, [])
    |> assign(:top_groups, [])
    |> assign(:displayed_period, socket.assigns[:period])
    |> assign(:loading, false)
  end

  # User-wide: every user (admin included) sees only their own consumption.
  # `member_ids` arrive pre-resolved from the socket assigns (computed once
  # at mount), so no extra membership query is needed inside the bundle.
  # Rollup-first (`request_metrics_hourly`), request_logs fallback built in.
  defp fetch_summary(member_ids, opts) do
    Rollup.summary_for_members(
      from: Keyword.fetch!(opts, :from),
      to: Keyword.get(opts, :to),
      member_ids: member_ids
    )
  end

  # Previous equivalent period (e.g. yesterday, previous 7d) for the KPI
  # deltas — same computation as /stats (`StatsLive.previous_summary/3`).
  defp fetch_prev_summary(member_ids, period, timezone) do
    %{from: from, to: to} = Periods.previous_period_bounds(period, timezone)

    Rollup.summary_for_members(from: from, to: to, member_ids: member_ids)
  end

  # Delta percentages vs the previous period; nil when the previous value is
  # zero (a % change from zero is undefined). Mirrors /stats deltas.
  defp compute_deltas(current, prev) do
    %{
      requests_total: pct_delta(current.request_count, prev.request_count),
      cost_usd: decimal_pct_delta(current.total_cost_usd, prev.total_cost_usd),
      prompt_tokens: pct_delta(current.total_prompt_tokens, prev.total_prompt_tokens),
      completion_tokens: pct_delta(current.total_completion_tokens, prev.total_completion_tokens)
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

  # Hour-bucketed chart series. Rollup-first via
  # `Rollup.hourly_series_for_members/3` (`request_metrics_hourly`), with
  # the request_logs fallback built in — the exact query this LiveView used
  # before the rollup existed now lives in `Rollup` for parity testing.
  defp hourly_series_for_members(member_ids, opts, timezone) do
    Rollup.hourly_series_for_members(member_ids, opts, timezone)
  end

  defp to_token_points(series, period, timezone) do
    Enum.map(series, fn row ->
      in_val = row.prompt_tokens * 1.0
      out_val = row.completion_tokens * 1.0

      %{
        label: bucket_label(row.hour, period, timezone),
        value_in: in_val,
        value_out: out_val,
        tooltip: "#{format_compact(trunc(in_val))} in / #{format_compact(trunc(out_val))} out"
      }
    end)
  end

  # Top 5 models by real (paid) cost for the horizontal-bars chart
  defp top_model_rows(breakdown_model) do
    top_rows(breakdown_model, & &1.model_name)
  end

  # Top 5 members by real (paid) cost for the horizontal-bars chart
  defp top_member_rows(breakdown_member) do
    top_rows(breakdown_member, & &1.user_email)
  end

  # Shared ranking logic: sort by cost_usd desc, take 5,
  # normalize to %{label, value, tooltip} for `hbars_chart`.
  defp top_rows(rows, label_fun) do
    rows
    |> Enum.sort_by(fn row -> Decimal.to_float(row.cost_usd) end, :desc)
    |> Enum.take(5)
    |> Enum.map(fn row ->
      cost = Decimal.to_float(row.cost_usd)

      %{
        label: label_fun.(row),
        value: cost,
        tooltip: "$#{Float.round(cost, 6)} · #{row.request_count} req"
      }
    end)
  end

  # Normalizes a bucketed rollup row into a chart point %{label, value, tooltip}
  defp to_chart_points(series, period, field, tooltip_fn, timezone) do
    Enum.map(series, fn row ->
      value =
        case Map.fetch!(row, field) do
          %Decimal{} = d -> Decimal.to_float(d)
          n when is_number(n) -> n * 1.0
        end

      %{
        label: bucket_label(row.hour, period, timezone),
        value: value,
        tooltip: tooltip_fn.(value)
      }
    end)
  end

  defp bucket_label(hour, period, timezone) when period in ["today", "7d"] do
    TokengateWeb.TimezoneHelper.format_bucket(hour, timezone)
  end

  defp bucket_label(hour, _period, timezone) do
    TokengateWeb.TimezoneHelper.format_bucket_date(hour, timezone)
  end

  defp usd_tooltip(value), do: "#{Float.round(value, 6)} USD"
  defp requests_tooltip(value), do: "#{trunc(value)} requests"
  defp tps_tooltip(value), do: "#{Float.round(value, 1)} tps"

  defp empty_metrics do
    %{
      requests_total: 0,
      errors_total: 0,
      error_rate: 0.0,
      cost_usd: Decimal.new(0),
      prompt_tokens: 0,
      completion_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      avg_latency_ms: 0.0,
      avg_ttft_ms: nil,
      avg_tps: nil,
      deltas: %{
        requests_total: nil,
        cost_usd: nil,
        prompt_tokens: nil,
        completion_tokens: nil
      }
    }
  end

  ## Template helpers (rendered in the .heex template) -------------------

  def format_decimal(%Decimal{} = d) do
    d
    |> Decimal.round(4)
    |> Decimal.to_string()
  end

  def format_decimal(n) when is_number(n), do: to_string(n)
  def format_decimal(_), do: "0"

  def format_number(n) when is_integer(n), do: with_thousands_separator(n)
  def format_number(n) when is_float(n), do: Float.to_string(n)
  def format_number(_), do: "0"

  @doc "Compact notation for big counters: 32.7K, 1.2M, 3.4B."
  def format_compact(n) when is_integer(n) and n >= 1_000_000_000,
    do: "#{Float.round(n / 1_000_000_000, 1)}B"

  def format_compact(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  def format_compact(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  def format_compact(n) when is_integer(n), do: Integer.to_string(n)
  def format_compact(n) when is_float(n), do: format_compact(trunc(n))
  def format_compact(_), do: "0"

  @doc """
  Compact value for the cache KPI: shows the sum (read + creation) when
  either is > 0, otherwise returns "—" so the slot stays visually empty.
  """
  def format_cache_value(read, creation)
      when read in [nil, 0] and creation in [nil, 0],
      do: "—"

  def format_cache_value(read, creation) do
    format_compact((read || 0) + (creation || 0))
  end

  @doc "Delegates to `KpiHelpers.cache_hit_rate/2` so templates can call it locally."
  def cache_hit_rate(read, prompt), do: KpiHelpers.cache_hit_rate(read, prompt)

  @doc "Formats a hit rate for the cache slot subtitle."
  def format_hit_rate(rate), do: KpiHelpers.format_hit_rate(rate)

  defp with_thousands_separator(n) do
    digits = Integer.to_string(abs(n))

    grouped =
      digits
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    if n < 0, do: "-" <> grouped, else: grouped
  end

  def format_tps(nil), do: "—"
  def format_tps(n) when is_float(n), do: Float.round(n, 1) |> Float.to_string()
  def format_tps(n) when is_integer(n), do: to_string(n)

  def format_latency(nil), do: "—"
  def format_latency(n) when is_number(n), do: "#{Float.round(n * 1.0, 1)} ms"

  def chart_max_value(points) do
    points
    |> Enum.map(& &1.value)
    |> Enum.max(fn -> 0.0 end)
  end

  # Compute Y-axis labels (5 ticks from 0 to max)
  defp compute_y_labels(+0.0), do: ["0"]

  defp compute_y_labels(max_value) do
    step = max_value / 4

    for i <- 0..4 do
      val = step * (4 - i)
      format_chart_value(val)
    end
  end

  # Compute X-axis labels (show ~5 evenly spaced labels)
  defp compute_x_labels(series) when length(series) <= 5 do
    Enum.map(series, & &1.label)
  end

  defp compute_x_labels(series) do
    count = length(series)
    # Show ~5 labels: first, last, and 3 evenly spaced
    indices = [0, div(count - 1, 4), div(count - 1, 2), div(count - 1, 4) * 3, count - 1]

    indices
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn i -> Enum.at(series, i).label end)
  end

  defp format_chart_value(val) when val >= 1_000_000, do: "#{Float.round(val / 1_000_000, 1)}M"
  defp format_chart_value(val) when val >= 1_000, do: "#{Float.round(val / 1_000, 1)}K"
  defp format_chart_value(val) when val >= 1, do: "#{trunc(val)}"
  defp format_chart_value(val) when val > 0, do: "#{Float.round(val, 2)}"
  defp format_chart_value(_), do: "0"

  def period_label("today"), do: "Hoy"
  def period_label("7d"), do: "7 días"
  def period_label("30d"), do: "30 días"
  def period_label("90d"), do: "90 días"
  def period_label(_), do: "Hoy"

  def period_active?(current, target), do: current == target

  def breakdown_tab_active?(current, target), do: current == target

  def chart_title(period), do: series_title("Costo", period)
  def requests_title(period), do: series_title("Requests", period)
  def tokens_title(period), do: series_title("Tokens in/out", period)
  def tps_title(period), do: series_title("TPS", period)

  defp series_title(label, period) do
    base =
      case period do
        "today" -> "por hora"
        "7d" -> "por hora (7d)"
        "30d" -> "por día (30d)"
        "90d" -> "por día (90d)"
        _ -> "por hora"
      end

    "#{label} #{base}"
  end

  def has_breakdown_data?(breakdown), do: breakdown != []

  # Same tier colors as /stats rankings
  def tier_badge_class("S"), do: "badge-success"
  def tier_badge_class("A"), do: "badge-info"
  def tier_badge_class("B"), do: "badge-warning"
  def tier_badge_class("C"), do: "badge-warning badge-outline"
  def tier_badge_class("D"), do: "badge-error"
  def tier_badge_class(_), do: "badge-ghost"

  def model_type_badge_class("embedding"), do: "badge-info"
  def model_type_badge_class(_), do: "badge-ghost"

  ## Key helpers -----------------------------------------------------------

  def masked_key(%{api_key: %{key_prefix: prefix}}) when is_binary(prefix) do
    "#{prefix}••••"
  end

  def masked_key(_), do: "Sin clave"

  def key_status_badge(%{api_key: %{status: "active"}}), do: "badge-success"
  def key_status_badge(%{api_key: %{status: "revoked"}}), do: "badge-error"
  def key_status_badge(_), do: "badge-ghost"

  def key_status_label(%{api_key: %{status: "active"}}), do: "Activa"
  def key_status_label(%{api_key: %{status: "revoked"}}), do: "Revocada"
  def key_status_label(_), do: "Sin clave"

  ## Budget helpers -------------------------------------------------------

  def budget_pct(_spend, nil), do: nil

  def budget_pct(spend, limit) when is_struct(limit, Decimal) do
    spend = Decimal.to_float(spend)
    limit = Decimal.to_float(limit)
    if limit > 0, do: Float.round(spend / limit * 100, 1), else: 0.0
  end

  def budget_pct(spend, limit) when is_number(limit) do
    spend = Decimal.to_float(spend)
    if limit > 0, do: Float.round(spend / limit * 100, 1), else: 0.0
  end

  @doc "Returns CSS width string for budget bar, safe for nil limits."
  def budget_bar_width(nil), do: "width: 0%"
  def budget_bar_width(pct) when is_number(pct), do: "width: #{min(pct, 100)}%"

  def budget_bar_class(pct) when is_number(pct) do
    cond do
      pct >= 90 -> "bg-error"
      pct >= 70 -> "bg-warning"
      true -> "bg-success"
    end
  end

  def budget_bar_class(_), do: "bg-base-300"

  ## Credit helpers --------------------------------------------------------

  @doc "¿Hay límite mensual definido para el sujeto? (nil = sin límite)."
  def credit_visible?(%{limit_usd: limit}), do: not is_nil(limit)
  def credit_visible?(_), do: false

  @doc "Porcentaje consumido del límite mensual efectivo (nil = sin límite)."
  def credit_pct(%{limit_usd: limit, limit_spend_usd: spent}) when not is_nil(limit) do
    if Decimal.compare(limit, 0) != :gt do
      100.0
    else
      spent
      |> Decimal.div(limit)
      |> Decimal.mult(100)
      |> Decimal.round(1)
      |> Decimal.to_float()
      |> min(100.0)
    end
  end

  def credit_pct(_), do: nil

  @doc "Formatea un monto en micro-USD como USD."
  def format_micro(micro) when is_integer(micro) do
    micro
    |> Decimal.new()
    |> Decimal.div(Decimal.new(1_000_000))
    |> format_decimal()
  end

  ## Componentes — marca del modelo ---------------------------------------

  # La marca del modelo: logo del lab cuando lo tiene, si no un hero icon. El
  # chip claro es fijo porque los logos del catálogo son oscuros y el tema también
  # (mismo criterio que las cards de modelos/labs). Un modelo sin marca conocida
  # (o fuera del catálogo) cae al icono genérico.
  attr :mark, :any, default: nil
  attr :id, :string, required: true

  defp model_mark(assigns) do
    ~H"""
    <span
      id={@id}
      class="flex items-center justify-center shrink-0 w-7 h-7 rounded-lg border border-base-300 bg-white overflow-hidden"
    >
      <%= case @mark || {:icon, Model.default_icon()} do %>
        <% {:logo, url} -> %>
          <img src={url} alt="" class="w-4 h-4 object-contain" loading="lazy" />
        <% {:icon, icon} -> %>
          <.icon name={icon} class="w-4 h-4 text-base-content/70" />
      <% end %>
    </span>
    """
  end

  ## Chart components ------------------------------------------------------

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, default: "hero-chart-bar"
  attr :series, :list, required: true
  attr :bar_class, :string, default: "fill-primary/70 hover:fill-primary"
  attr :empty_label, :string, default: "Sin datos para este periodo."

  def bar_chart(assigns) do
    max_value = chart_max_value(assigns.series)
    bar_count = max(length(assigns.series), 1)

    assigns =
      assigns
      |> assign(:max_value, max_value)
      |> assign(:bar_width, max(380 / bar_count - 4, 2))
      |> assign(:y_labels, compute_y_labels(max_value))
      |> assign(:x_labels, compute_x_labels(assigns.series))

    ~H"""
    <div id={@id} class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name={@icon} class="w-5 h-5 text-base-content/60" />
          {@title}
        </h2>

        <%= if @series == [] or @max_value == 0.0 do %>
          <div class="h-40 flex items-center justify-center text-base-content/40 text-sm">
            {@empty_label}
          </div>
        <% else %>
          <div class="mt-4">
            <div class="flex">
              <%!-- Y-axis labels --%>
              <div class="flex flex-col justify-between text-[10px] text-base-content/50 pr-1 h-40 text-right w-8">
                <%= for label <- @y_labels do %>
                  <span>{label}</span>
                <% end %>
              </div>
              <%!-- Chart --%>
              <svg viewBox="0 0 400 150" class="flex-1 h-40" preserveAspectRatio="none">
                <%= for {row, i} <- Enum.with_index(@series) do %>
                  <% height = if @max_value > 0, do: max(row.value / @max_value * 120, 1), else: 1 %>
                  <% x = 10 + i * (@bar_width + 4) %>
                  <% y = 140 - height %>
                  <rect
                    x={x}
                    y={y}
                    width={@bar_width}
                    height={height}
                    rx="2"
                    class={[@bar_class, "transition-colors"]}
                  >
                    <title>
                      {row.label} — {row.tooltip}
                    </title>
                  </rect>
                <% end %>
                <line x1="10" y1="140" x2="390" y2="140" class="stroke-base-300" stroke-width="1" />
                <%!-- Horizontal grid lines --%>
                <%= for {_label, i} <- Enum.with_index(@y_labels) do %>
                  <% y = 20 + i * (120 / (length(@y_labels) - 1)) %>
                  <line
                    x1="10"
                    y1={y}
                    x2="390"
                    y2={y}
                    class="stroke-base-300/50"
                    stroke-width="0.5"
                    stroke-dasharray="2,2"
                  />
                <% end %>
              </svg>
            </div>
            <%!-- X-axis labels --%>
            <div class="flex justify-between text-[10px] text-base-content/50 pl-9 mt-1">
              <%= for label <- @x_labels do %>
                <span>{label}</span>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, default: "hero-cpu-chip"
  attr :series, :list, required: true
  attr :empty_label, :string, default: "Sin datos para este periodo."

  def stacked_bar_chart(assigns) do
    max_value =
      assigns.series
      |> Enum.map(fn row -> row.value_in + row.value_out end)
      |> Enum.max(fn -> 0.0 end)

    bar_count = max(length(assigns.series), 1)

    assigns =
      assigns
      |> assign(:max_value, max_value)
      |> assign(:bar_width, max(380 / bar_count - 4, 2))
      |> assign(:y_labels, compute_y_labels(max_value))
      |> assign(:x_labels, compute_x_labels(assigns.series))

    ~H"""
    <div id={@id} class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name={@icon} class="w-5 h-5 text-base-content/60" />
          {@title}
        </h2>

        <%= if @series == [] or @max_value == 0.0 do %>
          <div class="h-40 flex items-center justify-center text-base-content/40 text-sm">
            {@empty_label}
          </div>
        <% else %>
          <div class="mt-4">
            <div class="flex">
              <div class="flex flex-col justify-between text-[10px] text-base-content/50 pr-1 h-40 text-right w-8">
                <%= for label <- @y_labels do %>
                  <span>{label}</span>
                <% end %>
              </div>
              <svg viewBox="0 0 400 150" class="flex-1 h-40" preserveAspectRatio="none">
                <%= for {row, i} <- Enum.with_index(@series) do %>
                  <% in_height =
                    if @max_value > 0, do: max(row.value_in / @max_value * 120, 0), else: 0 %>
                  <% out_height =
                    if @max_value > 0, do: max(row.value_out / @max_value * 120, 0), else: 0 %>
                  <% x = 10 + i * (@bar_width + 4) %>
                  <% out_y = 140 - out_height %>
                  <% in_y = out_y - in_height %>
                  <rect
                    x={x}
                    y={in_y}
                    width={@bar_width}
                    height={in_height}
                    rx="2"
                    class="fill-primary/70 hover:fill-primary transition-colors"
                  >
                    <title>{row.label} — {row.tooltip}</title>
                  </rect>
                  <rect
                    x={x}
                    y={out_y}
                    width={@bar_width}
                    height={out_height}
                    class="fill-accent/70 hover:fill-accent transition-colors"
                  >
                    <title>{row.label} — {row.tooltip}</title>
                  </rect>
                <% end %>
                <line x1="10" y1="140" x2="390" y2="140" class="stroke-base-300" stroke-width="1" />
                <%= for {_label, i} <- Enum.with_index(@y_labels) do %>
                  <% y = 20 + i * (120 / (length(@y_labels) - 1)) %>
                  <line
                    x1="10"
                    y1={y}
                    x2="390"
                    y2={y}
                    class="stroke-base-300/50"
                    stroke-width="0.5"
                    stroke-dasharray="2,2"
                  />
                <% end %>
              </svg>
            </div>
            <div class="flex items-center gap-4 text-[10px] text-base-content/50 mt-1 pl-9">
              <span class="flex items-center gap-1">
                <span class="inline-block w-2 h-2 rounded-sm bg-primary/70"></span> Input
              </span>
              <span class="flex items-center gap-1">
                <span class="inline-block w-2 h-2 rounded-sm bg-accent/70"></span> Output
              </span>
            </div>
            <div class="flex justify-between text-[10px] text-base-content/50 pl-9 mt-1">
              <%= for label <- @x_labels do %>
                <span>{label}</span>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, default: "hero-chart-bar-square"
  attr :rows, :list, required: true
  attr :empty_label, :string, default: "Sin datos para este periodo."

  def hbars_chart(assigns) do
    assigns = assign(assigns, :max_value, chart_max_value(assigns.rows))

    ~H"""
    <div id={@id} class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name={@icon} class="w-5 h-5 text-base-content/60" />
          {@title}
        </h2>

        <%= if @rows == [] or @max_value == 0.0 do %>
          <div class="h-40 flex items-center justify-center text-base-content/40 text-sm">
            {@empty_label}
          </div>
        <% else %>
          <div class="mt-4 space-y-3">
            <div :for={row <- @rows} class="group">
              <div class="flex items-center justify-between text-xs mb-1 gap-2">
                <span class="font-medium truncate" title={row.label}>{row.label}</span>
                <span class="font-mono text-base-content/60 whitespace-nowrap">{row.tooltip}</span>
              </div>
              <div class="h-2.5 rounded-full bg-base-200 overflow-hidden">
                <div
                  class="h-full rounded-full bg-primary/70 group-hover:bg-primary transition-all"
                  style={"width: #{Float.round(max(row.value / @max_value * 100, 2.0), 1)}%"}
                />
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
