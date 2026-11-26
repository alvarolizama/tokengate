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

  The first paint never waits on Postgres: mount renders a skeleton and the
  bundle is computed by an async task (`start_async/3`), whose result lands in
  `handle_async/3`. The previous-period summary — a closed, immutable window —
  is cached on its own 60s entry so the 5s refresh does not re-run it.

  Real-time updates come from `Phoenix.PubSub` on the `"metrics:updated"`
  topic (broadcast by `Tokengate.Metrics.Collector.record_request/1`).
  On `{:metrics_updated, _}` the LiveView debounces and re-reads from
  cache — a cache hit skips all Postgres queries.

  The period selector offers the canonical windows only — Hoy (UTC day),
  Ayer (closed UTC day), Esta semana, 30 días — and the active period travels
  in the URL (`?period=week`), so a bookmark reopens the same window and an
  out-of-set bookmark degrades to the default instead of raising.
  All UI strings are in Spanish (the app's UI language).
  """

  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2, where: 3]
  import TokengateWeb.KpiHelpers, only: [kpi_cards: 1]
  import TokengateWeb.KeysPanel

  # `period_selector/1`, `period_label/1`, and `budget_bar/1` come from the
  # shared stats helpers: the four canonical windows and budget thresholds have
  # ONE source, and the dashboard must not grow its own copy.
  import TokengateWeb.StatsHelpers,
    only: [budget_badge: 1, budget_bar: 1, credit_pct: 1, period_label: 1, period_selector: 1]

  alias Tokengate.Accounts
  alias Tokengate.Accounts.ApiKey
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Metrics.StatsQueries
  alias Tokengate.Periods
  alias Tokengate.Providers
  alias Tokengate.Providers.Model
  alias Tokengate.Repo
  alias TokengateWeb.KpiHelpers

  @pubsub Tokengate.PubSub
  @metrics_topic "metrics:updated"
  @reload_interval_ms 5_000
  # The previous window is closed: its summary can be reused far longer than
  # the live bundle (same TTL as the /stats structural cache).
  @prev_summary_cache_ttl 60_000

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
      |> assign(:period, Periods.default_period())
      |> assign(:metrics, empty_metrics())
      |> assign(:cost_series, [])
      |> assign(:requests_series, [])
      |> assign(:tokens_series, [])
      |> assign(:tps_series, [])
      |> assign(:breakdown_model, [])
      |> assign(:breakdown_member, [])
      |> assign(:active_breakdown, "model")
      |> assign(:scope_label, "Personal")
      # Scope por USUARIO (identidad durable, `request_logs.user_id`): la
      # misma que usa el motor de créditos. Antes se scopeaba por las
      # membresías ACTUALES (`group_member_id`): al rotar una membresía, su
      # histórico quedaba fuera del dashboard aunque el presupuesto ya lo
      # hubiera debitado — el KPI de costo no cuadraba con el saldo.
      |> assign(:scope_user_ids, [user.id])
      |> assign(:new_token, nil)
      |> assign(:new_token_group, nil)
      |> assign(:supervised_services_count, count_supervised_services(user))
      |> assign(:model_marks, %{})
      |> assign(:keys_modal_open, false)
      |> assign(:keys, [])
      |> assign(:keys_spend, %{})
      |> assign(:new_key_token, nil)
      |> assign(:editing_key_id, nil)
      |> load_personal_data(user)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @metrics_topic)
    end

    # Mount paints the shell only (skeleton): the metrics bundle is kicked off
    # by `handle_params/3`, which LiveView runs right after mount on the
    # connected socket, so the Postgres work never blocks the first paint. The
    # dead render keeps the same skeleton until the socket connects.
    {:ok, socket}
  end

  # The active period lives in the URL. A bookmark (`?period=30d`) reopens the
  # same window; anything outside the canonical set — `?period=month`,
  # `?period=7d`, a forged non-binary — degrades to `Periods.default_period/0`
  # instead of being reinterpreted as another window.
  @impl true
  def handle_params(params, _uri, socket) do
    period = Periods.normalize_period(Map.get(params, "period"))
    user = socket.assigns[:current_user]

    socket = assign(socket, :period, period)

    # A patch that lands on the period already on screen must not re-query:
    # the selector also patches when the user re-clicks the active button.
    if socket.assigns.displayed_period == period do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> load_personal_data(user)
       |> load_metrics_async()}
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

    # Refresh path: both reads go through `DashboardCache` first, so a burst of
    # pubsub broadcasts collapses into one computation per TTL window (5s) and
    # every viewer of the scope shares it. A miss lands async, keeping the
    # previous bundle on screen.
    {:noreply,
     socket
     |> assign(:reload_scheduled, false)
     |> load_personal_data(user)
     |> load_metrics_async()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Scope helpers ----------------------------------------------------------
  # ---------------------------------------------------------------------------

  # Count of services the user supervises (read-only role). Used to show a
  # shortcut card on /dashboard when > 0.
  defp count_supervised_services(user) do
    Accounts.count_services_for_supervisor(user.id)
  end

  ## Events — membership key lifecycle --------------------------------------

  # Revoke = issue a new key and void the previous one. The row is NOT rotated in
  # place: a new `api_keys` row is inserted and the old one is flipped to
  # `revoked`, so `request_logs` keeps pointing at the token that was actually
  # used. The new token is shown once, in the one-time alert.
  def handle_event("revoke_key", %{"id" => member_id}, socket) do
    user = socket.assigns[:current_user]

    case find_membership(socket, member_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized."))}

      %{api_key: nil} ->
        {:noreply, put_flash(socket, :error, gettext("This membership has no key."))}

      member ->
        case Accounts.revoke_and_replace_api_key(member.api_key) do
          {:ok, replacement, new_token} ->
            audit(socket, "api_key.revoke", "api_key", member.api_key.id, %{
              "label" => member.api_key.label,
              "replacement_id" => replacement.id,
              "user_id" => user.id
            })

            {:noreply,
             socket
             |> assign(:new_token, new_token)
             |> assign(:new_token_group, member.group.name)
             |> reload_personal_data(user)
             |> reload_open_keys_panel(user)
             |> put_flash(:info, gettext("Key revoked. A new one was issued: copy it now."))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not revoke the key."))}
        end
    end
  end

  # Borrar = soft-hide: the row leaves every listing and stops authenticating,
  # but it is not deleted (its historical consumption stays attributed).
  def handle_event("hide_key", %{"id" => member_id}, socket) do
    user = socket.assigns[:current_user]

    case find_membership(socket, member_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized."))}

      %{api_key: nil} ->
        {:noreply, put_flash(socket, :error, gettext("This membership has no key."))}

      member ->
        case Accounts.hide_api_key(member.api_key) do
          {:ok, hidden} ->
            audit(socket, "api_key.hide", "api_key", hidden.id, %{
              "label" => hidden.label,
              "user_id" => user.id
            })

            {:noreply,
             socket
             |> reload_personal_data(user)
             |> reload_open_keys_panel(user)
             |> put_flash(:info, gettext("Key deleted."))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not delete the key."))}
        end
    end
  end

  # First key of a membership that has none (or whose key was hidden): issues a
  # fresh row instead of reviving the old one.
  def handle_event("generate_key", %{"id" => member_id}, socket) do
    user = socket.assigns[:current_user]

    case find_membership(socket, member_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Not authorized."))}

      member ->
        {token, key_hash, key_prefix} = Accounts.generate_api_key_material()

        attrs = %{
          "subject_type" => "member",
          "user_id" => user.id,
          "group_member_id" => member.id,
          "key_hash" => key_hash,
          "key_prefix" => key_prefix,
          "status" => "active"
        }

        case Accounts.create_api_key(attrs) do
          {:ok, api_key} ->
            audit(socket, "api_key.create", "api_key", api_key.id, %{
              "label" => api_key.label,
              "user_id" => user.id
            })

            {:noreply,
             socket
             |> assign(:new_token, token)
             |> assign(:new_token_group, member.group.name)
             |> reload_personal_data(user)
             |> reload_open_keys_panel(user)
             |> put_flash(:info, gettext("Key created. Copy it now: it is not shown again."))}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Could not create the key."))}
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
        audit(socket, "api_key.create", "api_key", api_key.id, %{
          "label" => api_key.label,
          "user_id" => user.id
        })

        {:noreply,
         socket
         |> assign(:new_key_token, token)
         |> put_flash(:info, gettext("Key created. Copy it now: it is not shown again."))
         |> load_user_keys(user.id)
         |> reload_personal_data(user)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not create the key."))}
    end
  end

  # Revoke = issue a new one and void the previous one — the same lifecycle the
  # group card and the service panel use. The previous row keeps its hash for
  # `request_logs` attribution; the token of the replacement is shown once in
  # the panel's `new_token` slot.
  def handle_event("revoke_user_key", %{"key-id" => api_key_id}, socket) do
    user = socket.assigns[:current_user]

    # The id arrives from the client: cast it first (a non-UUID used to raise
    # Ecto.Query.CastError and kill the LiveView) and check ownership before
    # touching the row.
    with {:ok, api_key_id} <- Ecto.UUID.cast(api_key_id),
         %{} = api_key <- Accounts.get_api_key(api_key_id),
         true <- api_key.user_id == user.id and is_nil(api_key.hidden_at),
         {:ok, _replacement, token} <- Accounts.revoke_and_replace_api_key(api_key) do
      audit(socket, "api_key.revoke", "api_key", api_key.id, %{
        "label" => api_key.label,
        "user_id" => user.id
      })

      {:noreply,
       socket
       |> assign(:new_key_token, token)
       |> put_flash(:info, gettext("Key revoked. A new one was issued: copy it now."))
       |> load_user_keys(user.id)
       |> reload_personal_data(user)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Key not found."))}
    end
  end

  # Borrar = soft-hide. The row disappears from the panel and the card; the
  # historical consumption stays attributed to it.
  def handle_event("hide_user_key", %{"key-id" => api_key_id}, socket) do
    user = socket.assigns[:current_user]

    with {:ok, api_key_id} <- Ecto.UUID.cast(api_key_id),
         %{} = api_key <- Accounts.get_api_key(api_key_id),
         true <- api_key.user_id == user.id and is_nil(api_key.hidden_at),
         {:ok, hidden} <- Accounts.hide_api_key(api_key) do
      audit(socket, "api_key.hide", "api_key", hidden.id, %{
        "label" => hidden.label,
        "user_id" => user.id
      })

      {:noreply,
       socket
       |> put_flash(:info, gettext("Key deleted."))
       |> load_user_keys(user.id)
       |> reload_personal_data(user)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Key not found."))}
    end
  end

  # Inline rename submit. Its pattern is a SUPERSET of the pencil click (the
  # submit payload also carries "key-id"), so this clause comes FIRST — Elixir
  # takes the first matching clause and a broader one above would no-op the
  # save. `rename_api_key/3` owns the ownership check and audits
  # `api_key.rename` with the old/new label, so users and services produce the
  # same entry.
  def handle_event("rename_user_key", %{"key-id" => key_id, "key" => %{"label" => label}}, socket)
      when is_binary(label) do
    user = socket.assigns[:current_user]

    with {:ok, key_id} <- Ecto.UUID.cast(key_id),
         {:ok, _renamed} <-
           Accounts.rename_api_key(%ApiKey{id: key_id}, label,
             user_id: user.id,
             actor: user
           ) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Key renamed."))
       |> assign(:editing_key_id, nil)
       |> load_user_keys(user.id)
       |> reload_personal_data(user)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not rename the key."))}
    end
  end

  # Pencil: opens the inline editor for that row.
  def handle_event("rename_user_key", %{"key-id" => key_id}, socket) when is_binary(key_id) do
    {:noreply, assign(socket, :editing_key_id, key_id)}
  end

  def handle_event("rename_user_key", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_rename_key", _params, socket) do
    {:noreply, assign(socket, :editing_key_id, nil)}
  end

  def handle_event("dismiss_new_key_token", _params, socket) do
    {:noreply, assign(socket, :new_key_token, nil)}
  end

  def handle_event("clear_user_sticky_routes", _params, socket) do
    user = socket.assigns[:current_user]
    Accounts.clear_user_sticky_routes(user.id)

    audit(socket, "routing.clear_sticky", "user", user.id, %{"email" => user.email})

    {:noreply,
     socket
     |> put_flash(:info, gettext("Sticky routes cleared. Your next request will be re-routed."))
     |> load_user_keys(user.id)}
  end

  ## Events — breakdown tabs ------------------------------------------------

  def handle_event("set_breakdown", %{"tab" => tab}, socket)
      when tab in ~w(model member) do
    {:noreply, assign(socket, :active_breakdown, tab)}
  end

  ## Data loading ---------------------------------------------------------

  defp load_personal_data(socket, user) do
    # Estas tarjetas se refrescan en cada cambio de período y en cada reload de
    # pubsub (no sólo al montar), así que la pasada de queries del resumen de
    # crédito se cachea con el mismo TTL de 5s que el resto del dashboard.
    data =
      DashboardCache.fetch_or_compute({:dashboard_personal, user.id}, fn ->
        build_personal_data(user)
      end)

    socket
    |> assign(:memberships, data.memberships)
    |> assign(:groups, data.groups)
    |> assign(:active_keys_count, Map.get(data, :active_keys_count, 0))
    |> assign(:has_access, data.has_access)
  end

  # Explicit invalidation: events that mutate the membership or its key
  # (revoke/hide/rename) cannot wait for the TTL to show the change.
  defp reload_personal_data(socket, user) do
    DashboardCache.invalidate({:dashboard_personal, user.id})
    load_personal_data(socket, user)
  end

  defp reload_open_keys_panel(socket, user) do
    if socket.assigns[:keys_modal_open] do
      load_user_keys(socket, user.id)
    else
      socket
    end
  end

  defp find_membership(socket, member_id) when is_binary(member_id) do
    Enum.find(socket.assigns[:memberships] || [], &(&1.id == member_id))
  end

  defp find_membership(_socket, _member_id), do: nil

  # El resumen del sujeto (límite efectivo + top-ups) se resuelve en lote:
  # una pasada para todas las membresías, desde el agregado compartido
  # (`user_credit_aggregates/0`, 5s de TTL) en vez de re-agregar por usuario.
  defp build_personal_data(user) do
    memberships = Accounts.list_group_members_for_user(user.id)
    summaries = Tokengate.Credits.summaries(memberships, cached: true)
    # Revoking inserts a NEW row for the same membership, so the `has_one`
    # preload can hand back the revoked one. The card resolves the user's
    # visible active key from ONE batched read instead (keys belong to the
    # user, not to the profile).
    active_keys = Accounts.list_api_keys_for_user(user.id)

    groups =
      Enum.map(memberships, fn membership ->
        summary = Map.get(summaries, membership.id)

        %{
          membership: membership,
          group: membership.group,
          api_key: card_key(membership, active_keys),
          monthly_limit: summary && summary.limit_usd,
          monthly_spend: (summary && summary.spend_usd) || Decimal.new(0),
          credit: summary
        }
      end)

    # Admins always see the full org-wide dashboard. Regular users need at
    # least one group membership to access API keys, endpoint info, and metrics.
    %{
      memberships: memberships,
      groups: groups,
      active_keys_count: length(active_keys),
      has_access: user.global_role == "admin" or groups != []
    }
  end

  # The key shown on the card: the one bound to this membership, otherwise the
  # user's first visible active key (a hidden or revoked row is never shown).
  defp card_key(membership, active_keys) do
    Enum.find(active_keys, &(&1.group_member_id == membership.id)) ||
      List.first(active_keys)
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

  # Loads the metrics bundle for the period on screen.
  #
  # Fast path: a DashboardCache hit applies the bundle synchronously — zero
  # Postgres queries.
  #
  # Slow path: a miss dispatches the Postgres work to `start_async/3` so the
  # render (first paint included) is never blocked; the bundle lands via
  # `handle_async/3` while `loading: true` keeps the skeleton (first load) or
  # the previous bundle (period switch) on screen. The task closure captures
  # only plain values (period, timezone, user ids) — never the socket.
  #
  # On the dead render there is no LiveView process to receive the result, so
  # the task is only started once connected; `handle_params/3` runs again on
  # the connected mount and starts it then.
  defp load_metrics_async(socket) do
    period = socket.assigns[:period] || Periods.default_period()
    timezone = socket.assigns[:timezone] || "Etc/UTC"
    user_ids = socket.assigns[:scope_user_ids] || []
    cache_key = bundle_cache_key(user_ids, period, timezone)

    case DashboardCache.fetch(cache_key) do
      {:ok, bundle} ->
        apply_metrics_bundle(socket, bundle)

      :miss ->
        if connected?(socket) do
          socket
          |> assign(:loading, true)
          |> start_async(:metrics_bundle, fn ->
            bundle =
              DashboardCache.fetch_or_compute(cache_key, fn ->
                compute_metrics_bundle(user_ids, period, timezone)
              end)

            {period, bundle}
          end)
        else
          socket
        end
    end
  end

  # Bundle cache key: the WINDOW plus the SCOPE that decides which rows the
  # bundle contains — never the socket's user id. Every socket of the same
  # scope shares one entry per TTL window, and carrying the scope in the key
  # keeps a personal bundle from ever being served to a different user.
  defp bundle_cache_key(user_ids, period, timezone) do
    {:dashboard_bundle, period, timezone, user_ids}
  end

  # Computes the full metrics bundle from Postgres. This is the expensive
  # path — called only on cache miss, inside the async task. Runs on plain
  # values (no socket) so it is safe to execute in another process.
  #
  # `user_ids` es la identidad durable (`request_logs.user_id`): el MISMO
  # sujeto que agota el motor de créditos. Las membresías ya no participan
  # en el scoping — su rotación no puede volver a esconder el histórico.
  defp compute_metrics_bundle(user_ids, period, timezone) do
    %{from: from, to: to} = Periods.period_bounds(period, timezone)
    opts = [from: from, to: to]

    # Summary
    summary = fetch_summary(user_ids, opts)

    # Delta vs the previous equivalent period (same shape as /stats KPIs).
    prev_summary = fetch_prev_summary(user_ids, period, timezone)
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
      if user_ids == [] do
        []
      else
        hourly_series_for_users(user_ids, opts, timezone)
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

    breakdown_opts = Keyword.put(opts, :user_ids, user_ids)
    breakdown_model = StatsQueries.breakdown_by_model(nil, breakdown_opts)
    breakdown_member = breakdown_by_api_key(user_ids, opts)

    %{
      metrics: metrics,
      cost_series: cost_series,
      requests_series: requests_series,
      tokens_series: tokens_series,
      tps_series: tps_series,
      breakdown_model: breakdown_model,
      model_marks: model_marks_for(breakdown_model),
      breakdown_member: breakdown_member
    }
  end

  defp breakdown_by_api_key([], _opts), do: []

  defp breakdown_by_api_key(user_ids, opts) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.get(opts, :to)

    query =
      from(rl in RequestLog,
        where: rl.user_id in ^user_ids and rl.inserted_at >= ^from,
        left_join: ak in ApiKey,
        on: rl.api_key_id == ak.id and is_nil(ak.hidden_at),
        group_by: [
          rl.api_key_id,
          fragment("CASE WHEN ? IS NULL THEN ? ELSE NULL END", rl.api_key_id, rl.api_key_prefix),
          ak.id,
          ak.label,
          ak.key_prefix,
          ak.status
        ],
        order_by: [
          desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
          desc: count(rl.id)
        ],
        select: %{
          api_key_id: rl.api_key_id,
          api_key_prefix: max(rl.api_key_prefix),
          key_label: ak.label,
          key_prefix: ak.key_prefix,
          key_status: ak.status,
          request_count: count(rl.id),
          cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
          prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.prompt_tokens),
          completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.completion_tokens),
          total_latency_ms: fragment("COALESCE(SUM(?), 0)::bigint", rl.latency_ms)
        }
      )

    query =
      if to do
        where(query, [rl], rl.inserted_at <= ^to)
      else
        query
      end

    query
    |> Repo.all(timeout: 15_000)
    |> Enum.map(&normalize_api_key_breakdown_row/1)
  end

  defp normalize_api_key_breakdown_row(row) do
    prefix = row.key_prefix || row.api_key_prefix
    masked_prefix = if is_binary(prefix) and prefix != "", do: "#{prefix}••••", else: nil

    dom_id =
      cond do
        is_binary(row.api_key_id) -> "bd-member-#{row.api_key_id}"
        is_binary(prefix) and prefix != "" -> "bd-member-prefix-#{prefix}"
        true -> "bd-member-unattributed"
      end

    label =
      case row.key_label do
        l when is_binary(l) and l != "" -> l
        _ -> nil
      end

    %{
      dom_id: dom_id,
      api_key_id: row.api_key_id,
      label: label,
      masked_prefix: masked_prefix,
      status: row.key_status,
      request_count: row.request_count,
      cost_usd: Decimal.new(to_string(row.cost_usd)),
      prompt_tokens: row.prompt_tokens,
      completion_tokens: row.completion_tokens,
      avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
    }
  end

  defp compute_tps(_tokens, 0), do: nil
  defp compute_tps(0, _latency), do: 0.0
  defp compute_tps(tokens, latency), do: tokens / (latency / 1000)

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
    |> assign(:breakdown_member, bundle.breakdown_member)
    |> assign(:displayed_period, socket.assigns[:period])
    |> assign(:loading, false)
  end

  # User-wide: every user (admin included) sees only their own consumption.
  # `user_ids` llegan del socket (el propio id, resuelto al montar).
  #
  # Lee por el MISMO camino que /stats (`StatsQueries.summary/1`: rollup para
  # la parte antigua + cola raw de las últimas 3h), acotado al USUARIO y a la
  # ventana del período. La identidad es la misma del motor de créditos
  # (`request_logs.user_id`), así el KPI cuadra con el saldo aunque la
  # membresía se haya rotado.
  defp fetch_summary(user_ids, opts) do
    StatsQueries.summary(
      from: Keyword.fetch!(opts, :from),
      to: Keyword.get(opts, :to),
      user_ids: user_ids
    )
  end

  # The previous window is CLOSED and immutable: its summary cannot change
  # between refreshes, yet it used to be re-aggregated on every 5s reload, per
  # viewer. It goes through `DashboardCache` with a 60s entry covering
  # everything that changes the result (scope, period, timezone) — the current
  # period's counter stays uncached, because a stale live KPI reads as a broken
  # number.
  defp fetch_prev_summary(user_ids, period, timezone) do
    DashboardCache.fetch_or_compute(
      {:dashboard_prev_summary, period, timezone, user_ids},
      fn ->
        %{from: from, to: to} = Periods.previous_period_bounds(period, timezone)

        StatsQueries.summary(from: from, to: to, user_ids: user_ids)
      end,
      ttl: @prev_summary_cache_ttl
    )
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
  # `Rollup.hourly_series_for_users/3` (`request_metrics_hourly` + fallback
  # raw), scoped by user id — the durable identity.
  defp hourly_series_for_users(user_ids, opts, timezone) do
    Rollup.hourly_series_for_users(user_ids, opts, timezone)
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

  defp bucket_label(hour, period, timezone) when period in ["today", "yesterday", "week"] do
    TokengateWeb.TimezoneHelper.format_bucket(hour, timezone)
  end

  defp bucket_label(hour, _period, timezone) do
    TokengateWeb.TimezoneHelper.format_bucket_date(hour, timezone)
  end

  defp usd_tooltip(value), do: "#{Float.round(value, 6)} USD"
  defp requests_tooltip(value), do: gettext("%{count} requests", count: trunc(value))
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

  # Labels come from the shared stats helpers (`period_label/1` is imported):
  # one msgid per canonical window, so the dashboard cannot drift again.

  def breakdown_tab_active?(current, target), do: current == target

  def chart_title(period), do: series_title(gettext("Cost"), period)
  def requests_title(period), do: series_title(gettext("Requests"), period)
  def tokens_title(period), do: series_title(gettext("Tokens in/out"), period)
  def tps_title(period), do: series_title("TPS", period)

  defp series_title(label, period) do
    base =
      case period do
        "today" -> gettext("per hour")
        "yesterday" -> gettext("per hour (yesterday)")
        "week" -> gettext("per hour (week)")
        "30d" -> gettext("per day (30d)")
        _ -> gettext("per hour")
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

  def masked_key(_), do: gettext("No key")

  def key_status_badge(%{api_key: %{status: "active"}}), do: "badge-success"
  def key_status_badge(%{api_key: %{status: "revoked"}}), do: "badge-error"
  def key_status_badge(_), do: "badge-ghost"

  def key_status_label(%{api_key: %{status: "active"}}), do: gettext("Active")
  def key_status_label(%{api_key: %{status: "revoked"}}), do: gettext("Revoked")
  def key_status_label(_), do: gettext("No key")

  ## Credit helpers --------------------------------------------------------

  @doc "¿Hay límite mensual definido para el sujeto? (nil = sin límite)."
  def credit_visible?(%{limit_usd: limit}), do: not is_nil(limit)
  def credit_visible?(_), do: false

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
          <.icon name={icon} class="w-4 h-4 text-neutral-600" />
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
  attr :empty_label, :string, default: "No data for this period."

  def bar_chart(assigns) do
    max_value = chart_max_value(assigns.series)
    bar_count = max(length(assigns.series), 1)
    slot = 380.0 / bar_count
    gap = min(4.0, slot * 0.25)
    bar_width = max(slot - gap, 0.8)

    assigns =
      assigns
      |> assign(:max_value, max_value)
      |> assign(:slot, slot)
      |> assign(:bar_width, bar_width)
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
            {TokengateWeb.Gettext.translate(@empty_label)}
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
                  <% x = 10.0 + i * @slot %>
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
  attr :empty_label, :string, default: "No data for this period."

  def stacked_bar_chart(assigns) do
    max_value =
      assigns.series
      |> Enum.map(fn row -> row.value_in + row.value_out end)
      |> Enum.max(fn -> 0.0 end)

    bar_count = max(length(assigns.series), 1)
    slot = 380.0 / bar_count
    gap = min(4.0, slot * 0.25)
    bar_width = max(slot - gap, 0.8)

    assigns =
      assigns
      |> assign(:max_value, max_value)
      |> assign(:slot, slot)
      |> assign(:bar_width, bar_width)
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
            {TokengateWeb.Gettext.translate(@empty_label)}
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
                  <% x = 10.0 + i * @slot %>
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
end
