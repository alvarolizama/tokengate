defmodule TokengateWeb.AuditLive do
  @moduledoc """
  Admin audit log viewer (`/operations/audit`).

  Shows **who did what, to which entity, from where and when**: actor (+ role),
  impersonator, action, entity, IP and the redacted change set. Filterable by
  actor email, entity type, action, IP and date range; paginated; exportable to
  CSV (`/operations/audit/export`).
  """

  use TokengateWeb, :live_view

  alias Tokengate.Auditing

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:filters, %{})
      |> assign(:form, to_form(%{}, as: :f))
      |> load_logs()

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    raw = params["f"] || %{}
    timezone = socket.assigns[:timezone] || "Etc/UTC"

    {:noreply,
     socket
     |> assign(:filters, normalize_filters(raw, timezone))
     |> assign(:form, to_form(raw, as: :f))
     |> assign(:page, 1)
     |> load_logs()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
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
    |> assign(:logs, logs)
    |> assign(:total, total)
    |> assign(:page, page)
    |> assign(:total_pages, total_pages)
    |> assign(:export_query, export_query(filters, timezone))
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

  defp put_filter(map, raw, key, atom) do
    case Map.get(raw, key) do
      value when value in [nil, ""] -> map
      value -> Map.put(map, atom, value)
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
            <a
              id="audit-export"
              href={"/operations/audit/export?" <> @export_query}
              class="btn btn-sm btn-neutral"
            >
              <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> {gettext("Export CSV")}
            </a>
          </:actions>
        </.header>

        <.form for={@form} id="audit-filters" phx-change="filter" phx-submit="filter">
          <div class="card bg-base-100 border border-base-300 mb-4">
            <div class="card-body grid grid-cols-1 md:grid-cols-3 lg:grid-cols-6 gap-3">
              <.input
                field={@form[:actor_email]}
                type="text"
                label={gettext("Actor (email)")}
                phx-debounce="300"
              />
              <.input
                field={@form[:entity_type]}
                type="text"
                label={gettext("Entity")}
                phx-debounce="300"
              />
              <.input
                field={@form[:action]}
                type="text"
                label={gettext("Action")}
                phx-debounce="300"
              />
              <.input field={@form[:ip]} type="text" label="IP" phx-debounce="300" />
              <.input field={@form[:from]} type="date" label={gettext("From")} />
              <.input field={@form[:to]} type="date" label={gettext("To")} />
            </div>
          </div>
        </.form>

        <div class="flex items-center justify-between text-sm text-base-content/60">
          <span>
            {@total} {if @total == 1, do: gettext("event"), else: gettext("events")} · {gettext(
              "page %{page} of %{total_pages}",
              page: @page,
              total_pages: @total_pages
            )}
          </span>
          <button phx-click="clear_filters" class="btn btn-xs" id="audit-clear">{gettext(
            "Clear filters"
          )}</button>
        </div>

        <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
          <.table
            id="audit-rows"
            rows={@logs}
            row_id={fn log -> "audit-#{log.id}" end}
            row_class="align-top"
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
              <div class="text-xs text-base-content/50">{log.target_label || log.entity_id}</div>
            </:col>
            <:col :let={log} label={gettext("Acting as")}>
              <span class="text-xs">{log.acting_as_email || "—"}</span>
            </:col>
            <:col :let={log} label={gettext("IP")}>
              <span class="font-mono text-xs">{log.ip || "—"}</span>
            </:col>
            <:col :let={log} label={gettext("Detail")}>
              <div class="max-w-xs">
                <details>
                  <summary class="cursor-pointer text-xs text-base-content/60">
                    {gettext("view")}
                  </summary>
                  <pre class="whitespace-pre-wrap break-all text-xs">{changes_text(log.changes)}</pre>
                </details>
              </div>
            </:col>
            <:empty>
              <.icon name="hero-magnifying-glass" class="w-10 h-10 mx-auto mb-2 opacity-40" />
              <p>{gettext("No events for the selected filters.")}</p>
            </:empty>
          </.table>
        </div>

        <div class="flex justify-between">
          <button
            id="audit-prev"
            phx-click="go_to_page"
            phx-value-page={@page - 1}
            disabled={@page <= 1}
            class="btn btn-sm"
          >
            {gettext("Previous")}
          </button>
          <button
            id="audit-next"
            phx-click="go_to_page"
            phx-value-page={@page + 1}
            disabled={@page >= @total_pages}
            class="btn btn-sm"
          >
            {gettext("Next")}
          </button>
        </div>
      </div>
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
