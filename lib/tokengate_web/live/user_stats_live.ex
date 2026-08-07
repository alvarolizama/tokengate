defmodule TokengateWeb.UserStatsLive do
  @moduledoc """
  Admin-only consolidated stats page for a **user**, aggregating every
  team membership the user holds.

  Shows aggregated stat cards (requests, cost, tokens, top models, status
  breakdown, last request) and a paginated stream of the user's recent
  logs across all memberships. Real-time updates via the same `logs:new`
  PubSub as `/dashboard/logs`.

  Path: `/dashboard/users/:user_id/stats`

  Admin-only by router; defense-in-depth `require_admin_hook/1` rejects
  event traffic from non-admins (a malicious client could otherwise
  fire events directly over the WebSocket).
  """

  use TokengateWeb, :live_view

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias TokengateWeb.KpiHelpers

  @page_size 50
  @summary_refresh_interval_ms 2_000

  @impl true
  def mount(%{"user_id" => user_id}, _session, socket) do
    user = Accounts.get_user!(user_id)
    memberships = Accounts.list_team_members_for_user(user.id)
    member_ids = Enum.map(memberships, & &1.id)

    if connected?(socket) and member_ids != [] do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "logs:new")
    end

    socket =
      socket
      |> assign(:page_title, "Stats · #{user.email} · Tokengate")
      |> assign(:user, user)
      |> assign(:memberships, memberships)
      |> assign(:team_member_ids, member_ids)
      |> assign(:timezone, socket.assigns[:timezone] || "Etc/UTC")
      |> assign(:is_admin, socket.assigns[:current_user].global_role == "admin")
      |> assign(:filters, default_filters())
      |> assign(:form, to_form(default_filters(), as: :filter))
      |> assign(:cursor, nil)
      |> assign(:has_more, false)
      |> assign(:page_size, @page_size)
      |> assign(:summary_5d, default_summary())
      |> assign(:summary_30d, default_summary())
      |> assign(:summary_refresh_scheduled, false)
      |> require_admin_hook()
      |> load_summary()
      |> load_logs(:reset)

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
    if log.team_member_id in socket.assigns.team_member_ids do
      timezone = socket.assigns.timezone
      filters = socket.assigns.filters

      if log_matches_filters?(log, filters, timezone) do
        socket = stream_insert(socket, :logs, log, at: 0)

        # Coalesce summary reloads: at most one member_stats recompute per
        # interval per connected LiveView, regardless of broadcast rate.
        # Without this, every proxied request triggers 2 Postgres aggregate
        # queries in every admin watching this page (PubSub storm).
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
     |> load_summary()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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
      |> load_logs(:reset)

    {:noreply, socket}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more do
      {:noreply, load_logs(socket, :more)}
    else
      {:noreply, socket}
    end
  end

  ## Data loading ---------------------------------------------------------

  defp load_summary(socket) do
    ids = socket.assigns.team_member_ids

    socket
    |> assign(:summary_5d, Logs.member_stats(ids, from: days_ago(5)))
    |> assign(:summary_30d, Logs.member_stats(ids, from: days_ago(30)))
  end

  defp load_logs(socket, mode) do
    ids = socket.assigns.team_member_ids

    if ids == [] do
      socket
      |> assign(:has_more, false)
      |> stream(:logs, [], reset: true)
    else
      base_filters =
        socket.assigns.filters
        |> Map.put("team_member_ids", ids)
        |> drop_empty_filters()

      logs =
        case mode do
          :reset ->
            Logs.list_logs(Map.put(base_filters, "limit", @page_size))

          :more ->
            cursor_filters =
              if socket.assigns.cursor do
                Map.put(base_filters, "before", socket.assigns.cursor)
              else
                base_filters
              end

            Logs.list_logs(Map.put(cursor_filters, "limit", @page_size))
        end

      has_more = length(logs) == @page_size

      socket =
        socket
        |> assign(:has_more, has_more)
        |> case do
          s when mode == :reset ->
            s |> stream(:logs, logs, reset: true)

          s ->
            s |> stream(:logs, logs)
        end

      case logs do
        [] ->
          socket

        _ ->
          oldest = List.last(logs)
          assign(socket, :cursor, oldest.inserted_at)
      end
    end
  end

  # Logs.list_logs/1 doesn't tolerate empty-string values for boolean
  # fields (streaming) — strip them before forwarding.
  defp drop_empty_filters(filters) do
    filters
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  defp default_filters do
    %{
      "status_class" => "",
      "streaming" => "",
      "from" => "",
      "to" => "",
      "model_search" => ""
    }
  end

  defp default_summary do
    %{
      total_cost_usd: Decimal.new(0),
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_cache_read_tokens: 0,
      total_cache_creation_tokens: 0,
      request_count: 0,
      avg_latency_ms: nil,
      avg_tps: 0.0,
      avg_ttft_ms: nil,
      status_breakdown: %{"2xx" => 0, "4xx" => 0, "5xx" => 0},
      top_models: [],
      last_request_at: nil,
      realtime_5min: %{request_count: 0, error_count: 0, avg_latency_ms: nil, error_rate: 0.0}
    }
  end

  ## Filter helpers -------------------------------------------------------

  defp log_matches_filters?(log, filters, timezone) do
    status_class = filters["status_class"]
    streaming = filters["streaming"]
    search = filters["model_search"]

    cond do
      status_class not in [nil, ""] and not status_class_match?(log.status_code, status_class) ->
        false

      streaming not in [nil, ""] and not streaming_match?(log.streaming, streaming) ->
        false

      search not in [nil, ""] and
          not (String.contains?(log.model_requested || "", search) or
                   String.contains?(log.model_responded || "", search)) ->
        false

      true ->
        date_range_match?(log.inserted_at, filters["from"], filters["to"], timezone)
    end
  end

  defp status_class_match?(_, ""), do: true
  defp status_class_match?(status, "2xx"), do: status >= 200 and status < 300
  defp status_class_match?(status, "4xx"), do: status >= 400 and status < 500
  defp status_class_match?(status, "5xx"), do: status >= 500 and status < 600
  defp status_class_match?(_, _), do: true

  defp streaming_match?(_, ""), do: true
  defp streaming_match?(streaming, "true"), do: streaming == true
  defp streaming_match?(streaming, "false"), do: streaming == false
  defp streaming_match?(_, _), do: true

  defp date_range_match?(_dt, "", "", _timezone), do: true

  defp date_range_match?(dt, from, to, timezone) do
    after_from =
      case parse_date_string(from, timezone) do
        nil -> true
        from_dt -> DateTime.compare(dt, from_dt) != :lt
      end

    before_to =
      case parse_date_string(to, timezone, :end_of_day) do
        nil -> true
        to_dt -> DateTime.compare(dt, to_dt) != :gt
      end

    after_from and before_to
  end

  defp parse_date_string(date_str, timezone, mode \\ :start_of_day)

  defp parse_date_string("", _tz, _mode), do: nil
  defp parse_date_string(nil, _tz, _mode), do: nil

  defp parse_date_string(date_str, timezone, mode) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        time =
          case mode do
            :start_of_day -> ~T[00:00:00]
            :end_of_day -> ~T[23:59:59]
          end

        date
        |> DateTime.new!(time, timezone)
        |> DateTime.shift_zone!("Etc/UTC")

      _ ->
        nil
    end
  end

  defp days_ago(n) do
    DateTime.utc_now()
    |> DateTime.add(-n * 24 * 60 * 60, :second)
    |> DateTime.truncate(:second)
  end

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
      <div class="space-y-6">
        <%!-- Header --%>
        <header class="flex items-center justify-between gap-6 pb-4">
          <div>
            <div class="flex items-center gap-2 text-xs text-base-content/60">
              <.link navigate={~p"/dashboard/users"} class="hover:underline">Usuarios</.link>
              <span>›</span>
              <span>Stats</span>
            </div>
            <h1 class="text-lg font-semibold leading-8 mt-1">
              {@user.email}
            </h1>
            <p class="text-sm text-base-content/70">
              {@user.name || ""}
              <%= if @memberships != [] do %>
                · {length(@memberships)} {if length(@memberships) == 1,
                  do: "membresía",
                  else: "membresías"}
              <% end %>
            </p>
          </div>
          <div class="flex-1"></div>
        </header>

        <%!-- KPI cards (5d window) --%>
        <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3">
          <.stat_card
            label="Requests (5d)"
            value={Integer.to_string(@summary_5d.request_count)}
            sub={safe_sub_count(@summary_5d.realtime_5min.request_count, " en 5 min")}
            icon="hero-squares-2x2"
          />
          <.stat_card
            label="Costo (5d)"
            value={fmt_money(@summary_5d.total_cost_usd)}
            sub={safe_sub_count(@summary_5d.request_count, " reqs")}
            icon="hero-currency-dollar"
          />
          <.stat_card
            label="Input tokens (5d)"
            value={format_number(@summary_5d.total_prompt_tokens)}
            sub={
              "prompt + cache_read · hit " <>
                KpiHelpers.format_hit_rate(
                  KpiHelpers.cache_hit_rate(
                    @summary_5d.total_cache_read_tokens,
                    @summary_5d.total_prompt_tokens
                  )
                )
            }
            icon="hero-arrow-down-on-square-stack"
          />
          <.stat_card
            label="Output tokens (5d)"
            value={format_number(@summary_5d.total_completion_tokens)}
            sub={"avg TPS: " <> fmt_tps(@summary_5d.avg_tps)}
            icon="hero-arrow-up-on-square-stack"
          />
          <.stat_card
            label="Errores (5d)"
            value={
              Integer.to_string(
                @summary_5d.status_breakdown["4xx"] + @summary_5d.status_breakdown["5xx"]
              )
            }
            sub={safe_sub_count(@summary_5d.realtime_5min.error_rate, "% (5 min)")}
            icon="hero-exclamation-triangle"
            tone={error_tone(@summary_5d.status_breakdown)}
          />
          <.stat_card
            label="Último request"
            value={last_request_label(@summary_5d.last_request_at, @timezone)}
            sub={"latency prom: " <> fmt_ms(@summary_5d.avg_latency_ms)}
            icon="hero-clock"
          />
        </div>

        <%!-- Memberships + Status breakdown + Top modelos --%>
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-3">
          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <h3 class="text-sm font-semibold mb-2">Membresías (consolidado)</h3>
              <%= if @memberships == [] do %>
                <p class="text-xs text-base-content/40">Sin membresías — usuario sin acceso.</p>
              <% else %>
                <ul class="space-y-1 text-sm">
                  <li :for={m <- @memberships} class="flex items-center justify-between">
                    <span>{(m.team && m.team.name) || "—"}</span>
                    <span class="badge badge-sm badge-ghost">
                      {if m.api_key, do: m.api_key.key_prefix, else: "—"}
                    </span>
                  </li>
                </ul>
              <% end %>
            </div>
          </div>
          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <h3 class="text-sm font-semibold mb-2">Status breakdown (5d)</h3>
              <div class="space-y-2">
                <.status_row
                  class_label="2xx"
                  count={@summary_5d.status_breakdown["2xx"]}
                  tone="success"
                />
                <.status_row
                  class_label="4xx"
                  count={@summary_5d.status_breakdown["4xx"]}
                  tone="warning"
                />
                <.status_row
                  class_label="5xx"
                  count={@summary_5d.status_breakdown["5xx"]}
                  tone="error"
                />
              </div>
              <p class="text-xs text-base-content/40 mt-3">
                30d: 2xx {Integer.to_string(@summary_30d.status_breakdown["2xx"])} · 4xx {Integer.to_string(
                  @summary_30d.status_breakdown["4xx"]
                )} · 5xx {Integer.to_string(@summary_30d.status_breakdown["5xx"])}
              </p>
            </div>
          </div>
          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4">
              <h3 class="text-sm font-semibold mb-2">Top modelos (5d)</h3>
              <%= if @summary_5d.top_models == [] do %>
                <p class="text-xs text-base-content/40">Sin requests en los últimos 5 días.</p>
              <% else %>
                <ol class="space-y-1">
                  <li
                    :for={row <- @summary_5d.top_models}
                    class="flex items-center justify-between text-sm"
                  >
                    <span class="font-mono">{row.model_requested || "—"}</span>
                    <span class="badge badge-sm badge-ghost">
                      {Integer.to_string(row.count)}
                    </span>
                  </li>
                </ol>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Filter form --%>
        <.form
          for={@form}
          id="user-stats-filter-form"
          phx-change="filter"
          class="grid grid-cols-2 md:grid-cols-4 gap-3"
        >
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

        <%!-- Logs table (stream) --%>
        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Fecha</th>
                <th>Modelo</th>
                <th>Agente</th>
                <th>Streaming</th>
                <th>Estado</th>
                <th class="text-right">Input</th>
                <th class="text-right">Output</th>
                <th class="text-right">Costo</th>
                <th class="text-right">Latencia</th>
              </tr>
            </thead>
            <tbody id="user-stats-logs" phx-update="stream">
              <tr id="user-stats-logs-empty" class="hidden only:table-row">
                <td colspan="9" class="text-center py-8 text-base-content/40">
                  <%= if @memberships == [] do %>
                    Este usuario no tiene membresías — no hay logs que mostrar.
                  <% else %>
                    No hay requests con los filtros actuales.
                  <% end %>
                </td>
              </tr>
              <tr :for={{id, log} <- @streams.logs} id={id}>
                <td class="whitespace-nowrap text-sm">
                  {TokengateWeb.TimezoneHelper.format_datetime(log.inserted_at, @timezone)}
                </td>
                <td class="text-sm">
                  {model_display(log.model_requested, log.model_responded)}
                </td>
                <td class="text-sm">{log.client_agent || "—"}</td>
                <td>{if log.streaming, do: "Sí", else: "No"}</td>
                <td>
                  <span class={["badge badge-sm", status_badge(log.status_code)]}>
                    {Integer.to_string(log.status_code)}
                  </span>
                </td>
                <td class="text-right text-sm">{format_number(log.prompt_tokens || 0)}</td>
                <td class="text-right text-sm">{format_number(log.completion_tokens || 0)}</td>
                <td class="text-right text-sm font-mono">${format_cost(log.provider_cost_usd)}</td>
                <td class="text-right text-sm">{format_number(log.latency_ms || 0)} ms</td>
              </tr>
            </tbody>
          </table>
        </div>

        <%= if @has_more do %>
          <div class="flex justify-center">
            <button phx-click="load_more" class="btn btn-ghost btn-sm" id="load-more-user-stats-logs">
              Cargar más
            </button>
          </div>
        <% end %>
      </div>
    </Layouts.dashboard>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: ""
  attr :icon, :string, default: "hero-chart-bar"
  attr :tone, :string, default: "default"

  defp stat_card(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body p-4">
        <div class="flex items-center justify-between">
          <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
            {@label}
          </p>
          <.icon name={@icon} class="w-4 h-4 text-base-content/40" />
        </div>
        <p class={["mt-1 text-2xl font-bold", tone_class(@tone)]}>
          {@value}
        </p>
        <p :if={@sub != ""} class="text-xs text-base-content/40 mt-1">{@sub}</p>
      </div>
    </div>
    """
  end

  attr :class_label, :string, required: true
  attr :count, :integer, default: 0
  attr :tone, :string, default: "default"

  defp status_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <span class={["badge badge-sm", row_tone(@tone)]}>{@class_label}</span>
      <span class="text-sm font-mono">{Integer.to_string(@count)}</span>
    </div>
    """
  end

  defp tone_class("error"), do: "text-error"
  defp tone_class("warning"), do: "text-warning"
  defp tone_class("success"), do: "text-success"
  defp tone_class(_), do: "text-base-content"

  defp row_tone("error"), do: "badge-error"
  defp row_tone("warning"), do: "badge-warning"
  defp row_tone("success"), do: "badge-success"
  defp row_tone(_), do: "badge-ghost"

  defp error_tone(%{"5xx" => n}) when n > 0, do: "error"
  defp error_tone(%{"4xx" => n}) when n > 0, do: "warning"
  defp error_tone(_), do: "default"

  ## Format helpers -------------------------------------------------------

  defp format_cost(%Decimal{} = d) do
    d |> Decimal.to_float() |> :erlang.float_to_binary([:compact, {:decimals, 6}])
  end

  defp format_cost(nil), do: "—"

  defp format_number(n) when is_integer(n) do
    digits = Integer.to_string(abs(n))

    grouped =
      digits
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    if n < 0, do: "-" <> grouped, else: grouped
  end

  defp format_number(_), do: "0"

  defp fmt_money(%Decimal{} = d) do
    "$" <> (d |> Decimal.to_float() |> :erlang.float_to_binary([:compact, {:decimals, 4}]))
  end

  defp fmt_money(_), do: "$0"

  defp fmt_tps(nil), do: "—"
  defp fmt_tps(tps) when tps in [+0.0, -0.0, 0.0], do: "—"

  defp fmt_tps(tps) when is_number(tps) do
    tps |> Float.round(1) |> :erlang.float_to_binary([:compact, {:decimals, 1}])
  end

  defp fmt_tps(_), do: "—"

  defp fmt_ms(nil), do: "—"
  defp fmt_ms(ms) when is_number(ms), do: "#{Float.round(ms, 0) |> trunc()} ms"
  defp fmt_ms(_), do: "—"

  defp model_display(req, resp) do
    cond do
      is_binary(resp) and resp != "" and resp != req -> "#{req} → #{resp}"
      true -> req || "—"
    end
  end

  defp status_badge(code) when is_integer(code) and code >= 200 and code < 300,
    do: "badge-success"

  defp status_badge(code) when is_integer(code) and code >= 400 and code < 500,
    do: "badge-warning"

  defp status_badge(code) when is_integer(code) and code >= 500 and code < 600, do: "badge-error"
  defp status_badge(_), do: "badge-ghost"

  defp last_request_label(nil, _tz), do: "—"

  defp last_request_label(%DateTime{} = dt, tz),
    do: TokengateWeb.TimezoneHelper.format_datetime(dt, tz)

  defp safe_sub_count(n, suffix) when is_integer(n), do: Integer.to_string(n) <> suffix

  defp safe_sub_count(f, suffix) when is_float(f),
    do: :erlang.float_to_binary(f, [:compact, {:decimals, 1}]) <> suffix

  defp safe_sub_count(_, suffix), do: "0" <> suffix
end
