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

    {:noreply,
     socket
     |> assign(:filters, normalize_filters(raw))
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
    page = page |> to_string() |> String.to_integer()

    {:noreply,
     socket
     |> assign(:page, max(page, 1))
     |> load_logs()}
  end

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

    socket
    |> assign(:logs, logs)
    |> assign(:total, total)
    |> assign(:page, page)
    |> assign(:total_pages, total_pages)
    |> assign(:export_query, export_query(filters))
  end

  defp normalize_filters(raw) do
    %{}
    |> put_filter(raw, "actor_email", :actor_email)
    |> put_filter(raw, "entity_type", :entity_type)
    |> put_filter(raw, "action", :action)
    |> put_filter(raw, "target_label", :target_label)
    |> put_filter(raw, "ip", :ip)
    |> put_from(raw)
    |> put_to(raw)
  end

  defp put_filter(map, raw, key, atom) do
    case Map.get(raw, key) do
      value when value in [nil, ""] -> map
      value -> Map.put(map, atom, value)
    end
  end

  defp put_from(map, raw) do
    with value when value not in [nil, ""] <- Map.get(raw, "from"),
         {:ok, date} <- Date.from_iso8601(value) do
      Map.put(map, :from, DateTime.new!(date, ~T[00:00:00], "Etc/UTC"))
    else
      _ -> map
    end
  end

  # `to` is inclusive in the UI: push it to the start of the next day.
  defp put_to(map, raw) do
    with value when value not in [nil, ""] <- Map.get(raw, "to"),
         {:ok, date} <- Date.from_iso8601(value) do
      Map.put(map, :to, DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC"))
    else
      _ -> map
    end
  end

  defp export_query(filters) do
    filters
    |> Enum.map(fn
      {:from, dt} -> {"from", DateTime.to_date(dt) |> Date.to_iso8601()}
      {:to, dt} -> {"to", dt |> Date.add(-1) |> Date.to_iso8601()}
      {key, value} -> {to_string(key), to_string(value)}
    end)
    |> URI.encode_query()
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
          Auditoría
          <:subtitle>
            Quién hizo qué, sobre qué y cuándo — retención de 90 días
          </:subtitle>
          <:actions>
            <a
              id="audit-export"
              href={"/operations/audit/export?" <> @export_query}
              class="btn btn-sm btn-neutral"
            >
              <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Exportar CSV
            </a>
          </:actions>
        </.header>

        <.form for={@form} id="audit-filters" phx-change="filter" phx-submit="filter">
          <div class="card bg-base-100 border border-base-300 mb-4">
            <div class="card-body grid grid-cols-1 md:grid-cols-3 lg:grid-cols-6 gap-3">
              <.input field={@form[:actor_email]} type="text" label={gettext("Actor (email)")} />
              <.input field={@form[:entity_type]} type="text" label="Entidad" />
              <.input field={@form[:action]} type="text" label={gettext("Action")} />
              <.input field={@form[:ip]} type="text" label="IP" />
              <.input field={@form[:from]} type="date" label="Desde" />
              <.input field={@form[:to]} type="date" label="Hasta" />
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

        <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
          <table class="table table-sm" id="audit-table">
            <thead>
              <tr>
                <th>{gettext("Date")}</th>
                <th>{gettext("Actor")}</th>
                <th>{gettext("Action")}</th>
                <th>{gettext("Entity")}</th>
                <th>{gettext("Acting as")}</th>
                <th>{gettext("IP")}</th>
                <th>{gettext("Detail")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={log <- @logs} id={"audit-#{log.id}"} class="align-top">
                <td class="whitespace-nowrap">
                  {format_ts(log.inserted_at, @timezone)}
                </td>
                <td>
                  <div class="font-medium">{log.actor_email || "—"}</div>
                  <div class="text-xs text-base-content/50">
                    {if log.user_id, do: log.actor_role || "user", else: "sistema"}
                  </div>
                </td>
                <td>
                  <span class="badge badge-ghost badge-sm font-mono">{log.action}</span>
                </td>
                <td>
                  <div class="font-mono text-xs">{log.entity_type}</div>
                  <div class="text-xs text-base-content/50">
                    {log.target_label || log.entity_id}
                  </div>
                </td>
                <td class="text-xs">
                  {log.acting_as_email || "—"}
                </td>
                <td class="font-mono text-xs">{log.ip || "—"}</td>
                <td class="max-w-xs">
                  <details>
                    <summary class="cursor-pointer text-xs text-base-content/60">
                      {gettext("view")}
                    </summary>
                    <pre class="whitespace-pre-wrap break-all text-xs">{changes_text(log.changes)}</pre>
                  </details>
                </td>
              </tr>
              <tr :if={@logs == []}>
                <td colspan="7" class="text-center text-base-content/50 py-8">
                  {gettext("No events for the selected filters.")}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="flex justify-between">
          <button
            id="audit-prev"
            phx-click="go_to_page"
            phx-value-page={@page - 1}
            disabled={@page <= 1}
            class="btn btn-sm"
          >
            Anterior
          </button>
          <button
            id="audit-next"
            phx-click="go_to_page"
            phx-value-page={@page + 1}
            disabled={@page >= @total_pages}
            class="btn btn-sm"
          >
            Siguiente
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
