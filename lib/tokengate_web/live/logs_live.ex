defmodule TokengateWeb.LogsLive do
  @moduledoc false
  use TokengateWeb, :live_view

  alias Tokengate.{Accounts, Logs}

  @page_size 50
  @pubsub Tokengate.PubSub
  @logs_topic "logs:new"

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    scope_member_ids = resolve_scope_member_ids(user)

    socket =
      socket
      |> assign(:page_title, "Logs · Tokengate")
      |> assign(:page_size, @page_size)
      |> assign(:has_more, false)
      |> assign(:cursor, nil)
      |> assign(:scope_member_ids, scope_member_ids)
      |> assign(:filters, default_filters())
      |> assign(:form, to_form(default_filters(), as: :filter))
      |> assign(:summary, empty_summary())
      |> assign(:last_seen_at, DateTime.utc_now() |> DateTime.truncate(:second))

    socket = load_logs(socket, :reset)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @logs_topic)
    end

    {:ok, socket}
  end

  ## Real-time -------------------------------------------------------------

  @impl true
  def handle_info({:new_log, log}, socket) do
    # Only prepend if the log falls within the user's scope and filters.
    if log_in_scope?(log, socket.assigns[:scope_member_ids]) and
         log_matches_filters?(log, socket.assigns[:filters]) do
      socket =
        socket
        |> stream_insert(:logs, log, at: 0)
        |> assign(:last_seen_at, max_datetime(log.inserted_at, socket.assigns[:last_seen_at]))

      {:noreply, refresh_summary(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp log_in_scope?(_log, nil), do: true

  defp log_in_scope?(log, member_ids) when is_list(member_ids) do
    log.team_member_id in member_ids
  end

  defp log_matches_filters?(log, filters) do
    agent = filters["agent_type"]
    status_class = filters["status_class"]
    streaming = filters["streaming"]
    model_search = filters["model_search"]

    (agent in ["", nil, log.agent_type])
    and status_class_match?(log.status_code, status_class)
    and streaming_match?(log.streaming, streaming)
    and model_match?(log, model_search)
    and date_range_match?(log.inserted_at, filters["from"], filters["to"])
  end

  defp status_class_match?(_status, ""), do: true
  defp status_class_match?(_status, nil), do: true
  defp status_class_match?(status, "2xx"), do: status >= 200 and status < 300
  defp status_class_match?(status, "4xx"), do: status >= 400 and status < 500
  defp status_class_match?(status, "5xx"), do: status >= 500 and status < 600
  defp status_class_match?(_, _), do: true

  defp streaming_match?(_streaming, ""), do: true
  defp streaming_match?(_streaming, nil), do: true
  defp streaming_match?(streaming, "true"), do: streaming == true
  defp streaming_match?(streaming, "false"), do: streaming == false
  defp streaming_match?(_, _), do: true

  defp model_match?(_log, ""), do: true
  defp model_match?(_log, nil), do: true
  defp model_match?(log, search) do
    String.contains?(log.model_requested || "", search) or
      String.contains?(log.model_responded || "", search)
  end

  defp date_range_match?(_dt, "", ""), do: true
  defp date_range_match?(_dt, nil, nil), do: true
  defp date_range_match?(dt, from, to) do
    after_from? = case parse_date_string(from) do
      nil -> true
      from_dt -> DateTime.compare(dt, from_dt) != :lt
    end

    before_to? = case parse_date_string(to) do
      nil -> true
      to_dt -> DateTime.compare(dt, to_dt) != :gt
    end

    after_from? and before_to?
  end

  defp parse_date_string(""), do: nil
  defp parse_date_string(nil), do: nil
  defp parse_date_string(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        date
        |> NaiveDateTime.new!(~T[00:00:00])
        |> DateTime.from_naive!("Etc/UTC")

      _ ->
        nil
    end
  end

  defp max_datetime(dt1, dt2) do
    if DateTime.compare(dt1, dt2) == :gt, do: dt1, else: dt2
  end

  defp refresh_summary(socket) do
    summary =
      Logs.cost_summary(build_filters(socket, include_limit: false, include_cursor: false))

    socket |> assign(:summary, summary)
  end

  ## Scope resolution ------------------------------------------------------

  defp resolve_scope_member_ids(%{global_role: "admin"}) do
    nil
  end

  defp resolve_scope_member_ids(user) do
    memberships = Accounts.list_team_members_for_user(user.id)

    manager_team_ids =
      memberships
      |> Enum.filter(&(&1.team_role == "manager"))
      |> Enum.map(& &1.team_id)
      |> Enum.uniq()

    if manager_team_ids != [] do
      manager_team_ids
      |> Enum.flat_map(&Accounts.list_team_members_for_team/1)
      |> Enum.map(& &1.id)
      |> Enum.uniq()
    else
      Enum.map(memberships, & &1.id)
    end
  end

  ## Data loading ----------------------------------------------------------

  defp load_logs(socket, mode) do
    list_filters = build_filters(socket, include_cursor: mode == :more)

    logs = Logs.list_logs(list_filters)

    summary =
      Logs.cost_summary(build_filters(socket, include_limit: false, include_cursor: false))

    has_more = length(logs) == @page_size

    socket =
      socket
      |> assign(:summary, summary)
      |> assign(:has_more, has_more)

    socket =
      case mode do
        :reset -> stream(socket, :logs, logs, reset: true)
        :more -> stream(socket, :logs, logs)
      end

    case logs do
      [] ->
        socket

      _ ->
        oldest = List.last(logs)
        assign(socket, :cursor, oldest.inserted_at)
    end
  end

  ## Filter building -------------------------------------------------------

  defp default_filters do
    %{
      "agent_type" => "",
      "status_class" => "",
      "streaming" => "",
      "from" => "",
      "to" => "",
      "model_search" => ""
    }
  end

  defp build_filters(socket, opts) do
    include_cursor = Keyword.get(opts, :include_cursor, false)
    include_limit = Keyword.get(opts, :include_limit, true)
    form_filters = socket.assigns[:filters]

    base =
      %{}
      |> maybe_put(:agent_type, form_filters["agent_type"])
      |> maybe_put(:status_class, form_filters["status_class"])
      |> maybe_put(:streaming, parse_bool(form_filters["streaming"]))
      |> maybe_put(:model_search, form_filters["model_search"])
      |> maybe_put(:from, parse_from_date(form_filters["from"]))
      |> maybe_put(:to, parse_to_date(form_filters["to"]))
      |> maybe_put_scope(socket.assigns[:scope_member_ids])

    base =
      if include_cursor do
        maybe_put(base, :before, socket.assigns[:cursor])
      else
        base
      end

    if include_limit, do: Map.put(base, :limit, @page_size), else: base
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_scope(map, nil), do: map
  defp maybe_put_scope(map, ids), do: Map.put(map, :team_member_ids, ids)

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(_), do: nil

  defp parse_from_date(""), do: nil
  defp parse_from_date(nil), do: nil

  defp parse_from_date(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        date
        |> NaiveDateTime.new!(~T(00:00:00))
        |> DateTime.from_naive!("Etc/UTC")

      _ ->
        nil
    end
  end

  defp parse_to_date(""), do: nil
  defp parse_to_date(nil), do: nil

  defp parse_to_date(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        date
        |> NaiveDateTime.new!(~T(23:59:59))
        |> DateTime.from_naive!("Etc/UTC")

      _ ->
        nil
    end
  end

  defp empty_summary do
    %{
      request_count: 0,
      total_cost_usd: Decimal.new(0),
      total_savings_usd: Decimal.new(0),
      total_provider_cost_usd: Decimal.new(0),
      total_estimated_cost_usd: Decimal.new(0),
      total_prompt_tokens: 0,
      total_completion_tokens: 0
    }
  end

  ## Events ----------------------------------------------------------------

  @impl true
  def handle_event("filter", params, socket) do
    filter_params =
      params
      |> Map.get("filter", %{})
      |> then(&Map.merge(default_filters(), &1))

    socket =
      socket
      |> assign(:filters, filter_params)
      |> assign(:form, to_form(filter_params, as: :filter))
      |> assign(:cursor, nil)

    {:noreply, load_logs(socket, :reset)}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns[:has_more] do
      {:noreply, load_logs(socket, :more)}
    else
      {:noreply, socket}
    end
  end

  ## Template helpers ------------------------------------------------------

  defp format_cost(%Decimal{} = d) do
    d
    |> Decimal.to_float()
    |> then(&:erlang.float_to_binary(&1, [:compact, {:decimals, 6}]))
  end

  defp format_cost(nil), do: "—"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%d/%m/%Y %H:%M:%S")
  end

  defp model_display(model_requested, model_responded) do
    if model_requested == model_responded do
      model_requested
    else
      "#{model_requested} → #{model_responded}"
    end
  end

  defp tps(completion_tokens, latency_ms)
       when is_integer(completion_tokens) and is_integer(latency_ms) and latency_ms > 0 do
    tps = completion_tokens / (latency_ms / 1000)
    :erlang.float_to_binary(tps, [:compact, {:decimals, 1}])
  end

  defp tps(_completion_tokens, _latency_ms), do: "—"

  defp status_badge_class(status_code) when status_code >= 200 and status_code < 300,
    do: "badge-success"

  defp status_badge_class(status_code) when status_code >= 400 and status_code < 500,
    do: "badge-warning"

  defp status_badge_class(status_code) when status_code >= 500, do: "badge-error"
  defp status_badge_class(_), do: "badge-ghost"

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user}>
      <div class="space-y-6">
        <.header>
          Logs
          <:subtitle>Registro de solicitudes a la API en tiempo real</:subtitle>
        </.header>

        <%!-- Summary strip --%>
        <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Solicitudes
                </p>
                <.icon name="hero-arrow-trending-up" class="w-4 h-4 text-base-content/40" />
              </div>
              <p class="mt-1 text-2xl font-bold text-base-content" id="summary-requests">
                {@summary.request_count}
              </p>
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Costo total
                </p>
                <.icon name="hero-currency-dollar" class="w-4 h-4 text-base-content/40" />
              </div>
              <p class="mt-1 text-2xl font-bold text-base-content" id="summary-cost">
                ${format_cost(@summary.total_cost_usd)}
              </p>
            </div>
          </div>

          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <div class="flex items-center justify-between">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                  Ahorros
                </p>
                <.icon name="hero-banknotes" class="w-4 h-4 text-base-content/40" />
              </div>
              <p class="mt-1 text-2xl font-bold text-base-content" id="summary-savings">
                ${format_cost(@summary.total_savings_usd)}
              </p>
            </div>
          </div>
        </div>

        <%!-- Filter form --%>
        <.form
          for={@form}
          id="logs-filter-form"
          phx-change="filter"
          class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3"
        >
          <.input
            field={@form[:agent_type]}
            type="text"
            placeholder="Agente"
            label="Agente"
          />
          <.input
            field={@form[:status_class]}
            type="select"
            prompt="Todos"
            options={[{"2xx", "2xx"}, {"4xx", "4xx"}, {"5xx", "5xx"}]}
            label="Estado"
          />
          <.input
            field={@form[:streaming]}
            type="select"
            prompt="Todos"
            options={[{"Sí", "true"}, {"No", "false"}]}
            label="Streaming"
          />
          <.input
            field={@form[:model_search]}
            type="text"
            placeholder="gpt-4o"
            label="Modelo"
          />
          <.input
            field={@form[:from]}
            type="date"
            label="Desde"
          />
          <.input
            field={@form[:to]}
            type="date"
            label="Hasta"
          />
        </.form>

        <%!-- Logs table --%>
        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Fecha</th>
                <th>Modelo</th>
                <th>Agente</th>
                <th>Estado</th>
                <th class="text-right">Input</th>
                <th class="text-right">Output</th>
                <th class="text-right">TPS</th>
                <th>Latencia</th>
                <th class="text-right">Estimado</th>
                <th class="text-right">Costo</th>
                <th class="text-right">Proveedor</th>
                <th class="text-right">Ahorro</th>
              </tr>
            </thead>
            <tbody id="logs" phx-update="stream">
              <tr id="logs-empty" class="hidden only:table-row">
                <td colspan="12" class="text-center py-8 text-base-content/40">
                  No hay logs que coincidan con los filtros.
                </td>
              </tr>
              <tr :for={{id, log} <- @streams.logs} id={id}>
                <td class="whitespace-nowrap text-sm">{format_datetime(log.inserted_at)}</td>
                <td class="text-sm">{model_display(log.model_requested, log.model_responded)}</td>
                <td>
                  <span class="badge badge-sm badge-ghost">{log.agent_type}</span>
                </td>
                <td>
                  <span class={["badge", "badge-sm", status_badge_class(log.status_code)]}>
                    {log.status_code}
                  </span>
                </td>
                <td class="text-sm text-right tabular-nums">{log.prompt_tokens}</td>
                <td class="text-sm text-right tabular-nums">{log.completion_tokens}</td>
                <td class="text-sm text-right tabular-nums text-base-content/70">
                  {tps(log.completion_tokens, log.latency_ms)}
                </td>
                <td class="text-sm">{log.latency_ms}ms</td>
                <td class="text-sm text-right tabular-nums">{format_cost(log.estimated_cost_usd)}</td>
                <td class="text-sm text-right tabular-nums">{format_cost(log.cost_usd)}</td>
                <td class="text-sm text-right tabular-nums">{format_cost(log.provider_cost_usd)}</td>
                <td class="text-sm text-right tabular-nums">{format_cost(log.savings_usd)}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- Load more --%>
        <div class="flex justify-center">
          <button
            :if={@has_more}
            phx-click="load_more"
            class="btn btn-primary btn-sm"
            id="load-more-btn"
          >
            <.icon name="hero-chevron-down" class="w-4 h-4" /> Cargar más
          </button>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end
end
