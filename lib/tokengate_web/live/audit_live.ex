defmodule TokengateWeb.AuditLive do
  @moduledoc """
  Admin audit log viewer (`/operations/audit`).

  Shows **who did what, to which entity, from where and when**: actor (+ role),
  impersonator, action, entity, IP and the redacted change set. Filterable by
  actor email, entity type, action, IP and date range; paginated; exportable to
  CSV (`/operations/audit/export`).
  """

  use TokengateWeb, :live_view

  import TokengateWeb.AdminComponents

  alias Tokengate.Auditing
  alias Tokengate.Periods

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Audit") <> " · Tokengate")
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:total, 0)
      |> assign(:total_pages, 1)
      |> assign(:search_query, "")
      |> assign(:filters, %{})
      |> assign(:raw_filters, %{})
      |> assign(:form, to_form(%{}, as: :f))
      |> assign(:export_query, "")
      |> assign(:logs_empty?, true)
      |> assign(:detail_log, nil)
      |> assign(:known_actions, Auditing.known_actions())
      |> assign(:known_entity_types, Auditing.known_entity_types())
      |> stream_configure(:logs, dom_id: &"audit-#{&1.id}")
      |> stream(:logs, [], reset: true)

    socket = if connected?(socket), do: load_logs(socket), else: socket

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    raw = params["f"] || %{}
    timezone = socket.assigns[:timezone] || "Etc/UTC"

    filters =
      raw
      |> normalize_filters(timezone)
      |> maybe_put_search(socket.assigns.search_query)

    {:noreply,
     socket
     |> assign(:raw_filters, raw)
     |> assign(:filters, filters)
     |> assign(:form, to_form(raw, as: :f))
     |> assign(:page, 1)
     |> load_logs()}
  end

  def handle_event("search", %{"q" => q}, socket) do
    timezone = socket.assigns[:timezone] || "Etc/UTC"
    trimmed = String.trim(q || "")

    filters =
      socket.assigns.raw_filters
      |> normalize_filters(timezone)
      |> maybe_put_search(trimmed)

    {:noreply,
     socket
     |> assign(:search_query, trimmed)
     |> assign(:filters, filters)
     |> assign(:page, 1)
     |> load_logs()}
  end

  def handle_event("preset_range", %{"range" => range}, socket) do
    timezone = socket.assigns[:timezone] || "Etc/UTC"
    today = Periods.local_today(timezone)

    from_date =
      case range do
        "today" -> today
        "7d" -> Date.add(today, -6)
        "30d" -> Date.add(today, -29)
        _ -> today
      end

    raw =
      socket.assigns.raw_filters
      |> Map.put("from", Date.to_iso8601(from_date))
      |> Map.put("to", Date.to_iso8601(today))

    filters =
      raw
      |> normalize_filters(timezone)
      |> maybe_put_search(socket.assigns.search_query)

    {:noreply,
     socket
     |> assign(:raw_filters, raw)
     |> assign(:filters, filters)
     |> assign(:form, to_form(raw, as: :f))
     |> assign(:page, 1)
     |> load_logs()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign(:raw_filters, %{})
     |> assign(:filters, %{})
     |> assign(:form, to_form(%{}, as: :f))
     |> assign(:page, 1)
     |> load_logs()}
  end

  def handle_event("go_to_page", %{"page" => page}, socket) do
    parsed =
      case Integer.parse(to_string(page)) do
        {n, ""} -> max(n, 1)
        _ -> socket.assigns.page
      end

    {:noreply,
     socket
     |> assign(:page, parsed)
     |> load_logs()}
  end

  def handle_event("show_detail", %{"id" => id}, socket) do
    case Auditing.get_audit_log(id) do
      nil -> {:noreply, socket}
      log -> {:noreply, assign(socket, :detail_log, log)}
    end
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, :detail_log, nil)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load_logs(socket) do
    filters = socket.assigns.filters
    per_page = socket.assigns.per_page
    page = socket.assigns.page
    total = Auditing.count_audit_logs(filters)
    total_pages = max(ceil(total / per_page), 1)
    page = min(page, total_pages)

    logs =
      Auditing.list_audit_logs(
        Map.merge(filters, %{limit: per_page, offset: (page - 1) * per_page})
      )

    timezone = socket.assigns[:timezone] || "Etc/UTC"

    socket
    |> assign(:logs_empty?, logs == [])
    |> assign(:total, total)
    |> assign(:page, page)
    |> assign(:total_pages, total_pages)
    |> assign(:export_query, export_query(filters, timezone))
    |> stream(:logs, logs, reset: true)
  end

  defp normalize_filters(raw, timezone) do
    %{}
    |> put_filter(raw, "actor_email", :actor_email)
    |> put_filter(raw, "entity_type", :entity_type)
    |> put_filter(raw, "action", :action)
    |> put_filter(raw, "target_label", :target_label)
    |> put_filter(raw, "ip", :ip)
    |> put_from(raw, timezone)
    |> put_to(raw, timezone)
  end

  defp maybe_put_search(filters, ""), do: filters
  defp maybe_put_search(filters, nil), do: filters
  defp maybe_put_search(filters, q), do: Map.put(filters, :q, q)

  defp put_filter(map, raw, key, atom) do
    case Map.get(raw, key) do
      value when value in [nil, ""] -> map
      value -> Map.put(map, atom, String.trim(value))
    end
  end

  defp put_from(map, raw, timezone) do
    with value when value not in [nil, ""] <- Map.get(raw, "from"),
         %DateTime{} = dt <-
           TokengateWeb.TimezoneHelper.parse_local_date(value, timezone, :start_of_day) do
      Map.put(map, :from, dt)
    else
      _ -> map
    end
  end

  # `to` is inclusive in the UI: push it to the start of the next local day.
  defp put_to(map, raw, timezone) do
    with value when value not in [nil, ""] <- Map.get(raw, "to"),
         {:ok, date} <- Date.from_iso8601(value),
         %DateTime{} = dt <-
           TokengateWeb.TimezoneHelper.local_time_to_utc(
             Date.add(date, 1),
             ~T[00:00:00],
             timezone
           ) do
      Map.put(map, :to, dt)
    else
      _ -> map
    end
  end

  defp export_query(filters, timezone) do
    filters
    |> Enum.map(fn
      {:from, dt} ->
        {"from", dt |> shift_to_local_date(timezone) |> Date.to_iso8601()}

      {:to, dt} ->
        {"to", dt |> shift_to_local_date(timezone) |> Date.add(-1) |> Date.to_iso8601()}

      {key, value} ->
        {to_string(key), to_string(value)}
    end)
    |> URI.encode_query()
  end

  defp shift_to_local_date(%DateTime{} = dt, timezone) do
    case DateTime.shift_zone(dt, timezone) do
      {:ok, shifted} -> DateTime.to_date(shifted)
      {:error, _} -> DateTime.to_date(dt)
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

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
        <.header>
          {gettext("Audit")}
          <:subtitle>
            {gettext("Who did what, to what, and when — 90-day retention")}
          </:subtitle>
          <:actions>
            <div class="flex flex-wrap items-center gap-2">
              <.admin_search
                event="search"
                value={@search_query}
                placeholder={gettext("Search actor, target, action, IP…")}
                input_id="audit-search-input"
              />
              <a
                id="audit-export"
                href={"/operations/audit/export?" <> @export_query}
                class="btn btn-sm btn-ghost"
              >
                <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> {gettext("Export CSV")}
              </a>
            </div>
          </:actions>
        </.header>

        <.form for={@form} id="audit-filters" phx-change="filter" phx-submit="filter">
          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 xl:grid-cols-7 gap-3">
              <.input
                field={@form[:actor_email]}
                type="text"
                label={gettext("Actor (email)")}
                phx-debounce="300"
              />
              <.input
                field={@form[:entity_type]}
                type="datalist"
                options={@known_entity_types}
                label={gettext("Entity")}
                phx-debounce="300"
              />
              <.input
                field={@form[:action]}
                type="datalist"
                options={@known_actions}
                label={gettext("Action")}
                phx-debounce="300"
              />
              <.input
                field={@form[:target_label]}
                type="text"
                label={gettext("Target")}
                phx-debounce="300"
              />
              <.input field={@form[:ip]} type="text" label="IP" phx-debounce="300" />
              <.input field={@form[:from]} type="date" label={gettext("From")} />
              <.input field={@form[:to]} type="date" label={gettext("To")} />
            </div>
          </div>
        </.form>

        <div class="flex flex-wrap items-center justify-between gap-2 text-sm text-base-content/60">
          <div class="flex flex-wrap items-center gap-1.5">
            <span class="text-xs text-base-content/50 mr-1">{gettext("Range:")}</span>
            <button
              type="button"
              phx-click="preset_range"
              phx-value-range="today"
              id="audit-preset-today"
              class="btn btn-xs btn-ghost"
            >
              {gettext("Today")}
            </button>
            <button
              type="button"
              phx-click="preset_range"
              phx-value-range="7d"
              id="audit-preset-7d"
              class="btn btn-xs btn-ghost"
            >
              {gettext("7 days")}
            </button>
            <button
              type="button"
              phx-click="preset_range"
              phx-value-range="30d"
              id="audit-preset-30d"
              class="btn btn-xs btn-ghost"
            >
              {gettext("30 days")}
            </button>
          </div>
          <button
            :if={@filters != %{}}
            type="button"
            phx-click="clear_filters"
            class="btn btn-xs btn-ghost"
            id="audit-clear"
          >
            <.icon name="hero-x-mark" class="w-3.5 h-3.5" /> {gettext("Clear filters")}
          </button>
        </div>

        <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
          <.table
            id="audit-rows"
            rows={@streams.logs}
            row_item={fn {_id, log} -> log end}
            row_class="align-top"
            empty?={@logs_empty?}
          >
            <:col :let={log} label={gettext("Date")}>
              <span class="whitespace-nowrap">{format_ts(log.inserted_at, @timezone)}</span>
            </:col>
            <:col :let={log} label={gettext("Actor")}>
              <div class="font-medium">{log.actor_email || "—"}</div>
              <div class="text-xs text-base-content/50">
                {if log.user_id, do: log.actor_role || "user", else: gettext("system")}
              </div>
            </:col>
            <:col :let={log} label={gettext("Action")}>
              <span class="badge badge-ghost badge-sm font-mono">{log.action}</span>
            </:col>
            <:col :let={log} label={gettext("Entity")}>
              <div class="font-mono text-xs">{log.entity_type}</div>
              <div
                class="text-xs text-base-content/50 max-w-xs truncate"
                title={log.target_label || log.entity_id}
              >
                {log.target_label || log.entity_id}
              </div>
            </:col>
            <:col :let={log} label={gettext("Acting as")}>
              <span class="text-xs">{log.acting_as_email || "—"}</span>
            </:col>
            <:col :let={log} label={gettext("IP")}>
              <span class="font-mono text-xs">{log.ip || "—"}</span>
            </:col>
            <:action :let={log}>
              <button
                type="button"
                phx-click="show_detail"
                phx-value-id={log.id}
                id={"audit-detail-" <> log.id}
                class="btn btn-xs btn-ghost"
                title={gettext("Inspect event details")}
              >
                <.icon name="hero-eye" class="w-3.5 h-3.5" />
              </button>
            </:action>
            <:empty>
              <.icon name="hero-magnifying-glass" class="w-10 h-10 mx-auto mb-2 opacity-40" />
              <p>{gettext("No events for the selected filters.")}</p>
            </:empty>
          </.table>

          <.admin_pagination
            id="audit-pagination"
            page={@page}
            per_page={@per_page}
            total={@total}
            total_pages={@total_pages}
          />
        </div>
      </div>

      <.modal
        :if={@detail_log}
        id="audit-detail-modal"
        title={gettext("Audit event detail")}
        on_close="close_detail"
        max_w="max-w-2xl"
      >
        <div class="space-y-4 text-sm">
          <div class="flex flex-wrap items-center gap-2">
            <span class="badge badge-primary badge-soft font-mono">{@detail_log.action}</span>
            <span class="text-xs text-base-content/60">
              {format_ts(@detail_log.inserted_at, @timezone)}
            </span>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-2 text-xs">
            <div class="flex justify-between gap-2 border-b border-base-200 py-1">
              <span class="text-base-content/50">{gettext("Actor")}</span>
              <span class="font-medium truncate">
                {@detail_log.actor_email || gettext("system")}
              </span>
            </div>
            <div class="flex justify-between gap-2 border-b border-base-200 py-1">
              <span class="text-base-content/50">{gettext("Acting as")}</span>
              <span class="font-medium truncate">{@detail_log.acting_as_email || "—"}</span>
            </div>
            <div class="flex justify-between gap-2 border-b border-base-200 py-1">
              <span class="text-base-content/50">{gettext("Entity")}</span>
              <span class="font-mono truncate">
                {@detail_log.entity_type}:{@detail_log.entity_id}
              </span>
            </div>
            <div class="flex justify-between gap-2 border-b border-base-200 py-1">
              <span class="text-base-content/50">{gettext("Target")}</span>
              <span class="font-medium truncate">{@detail_log.target_label || "—"}</span>
            </div>
            <div class="flex justify-between gap-2 border-b border-base-200 py-1">
              <span class="text-base-content/50">IP</span>
              <span class="font-mono">{@detail_log.ip || "—"}</span>
            </div>
            <div class="flex justify-between gap-2 border-b border-base-200 py-1">
              <span class="text-base-content/50">{gettext("Origin")}</span>
              <span class="font-mono">{@detail_log.origin || "—"}</span>
            </div>
          </div>

          <div :if={@detail_log.user_agent} class="text-xs">
            <p class="text-base-content/50 mb-1">User-Agent</p>
            <p class="font-mono text-base-content/80 break-all bg-base-200/50 rounded p-2">
              {@detail_log.user_agent}
            </p>
          </div>

          <div>
            <p class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-1.5">
              {gettext("Changes")}
            </p>
            <pre
              id="audit-detail-changes"
              class="text-xs bg-base-200/60 rounded-lg p-3 whitespace-pre-wrap break-all font-mono"
            >{changes_text(@detail_log.changes)}</pre>
          </div>
        </div>
        <:footer>
          <button type="button" phx-click="close_detail" class="btn btn-ghost btn-sm">
            {gettext("Close")}
          </button>
        </:footer>
      </.modal>
    </Layouts.dashboard>
    """
  end

  defp changes_text(changes) when changes in [nil, %{}], do: "—"
  defp changes_text(changes), do: Jason.encode!(changes, pretty: true)

  # `inserted_at` is a `:utc_datetime` (NaiveDateTime); TimezoneHelper formats
  # DateTime, so normalize first.
  defp format_ts(%NaiveDateTime{} = naive, tz),
    do: format_datetime(DateTime.from_naive!(naive, "Etc/UTC"), tz)

  defp format_ts(other, tz), do: format_datetime(other, tz)
end
