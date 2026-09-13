defmodule TokengateWeb.StatsLive.LiveSection do
  @moduledoc """
  Sección "En vivo" de /stats — métricas en tiempo real, org-wide.

  Cinco bloques (todos auto-refresh):
    * Pulso: requests/min (5m), error rate, requests en vuelo
    * KPIs de hoy (día calendario): requests, costo, tokens, latencia p50/p95
    * Requests por minuto — últimos 60 min (barras)
    * En vuelo ahora: registry ETS (`Logs.Inflight`)
    * Feed: últimos requests via LiveView stream (`logs:new` + refetch)

  Sin selector de periodo: todo es "ahora".
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  attr :pulse, :any, required: true
  attr :today_metrics, :any, required: true
  attr :minute_series, :any, required: true
  attr :minute_series_max, :any, required: true
  attr :inflight_count, :any, required: true
  attr :inflight_by_model, :any, required: true
  attr :last_sync_at, :any, required: true
  attr :stats_loading, :any, required: true
  attr :streams, :any, required: true

  def live(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Status bar: indicador vivo + última sincronización --%>
      <div class="flex items-center justify-between flex-wrap gap-3">
        <div class="flex items-center gap-2">
          <span class="relative flex h-2.5 w-2.5">
            <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-success opacity-60"></span>
            <span class="relative inline-flex rounded-full h-2.5 w-2.5 bg-success"></span>
          </span>
          <span class="text-xs text-base-content/60">
            En vivo · actualización automática
          </span>
        </div>
        <span class="text-xs text-base-content/40 tabular-nums" id="live-last-sync">
          {Stats.format_dt(@last_sync_at)}
        </span>
      </div>

      <%!-- Pulso: req/min, error rate, en vuelo --%>
      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <div id="live-rpm" class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-5">
            <div class="flex items-center justify-between">
              <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                Requests / min
              </span>
              <span class="flex items-center justify-center w-9 h-9 rounded-lg bg-primary/10">
                <.icon name="hero-bolt" class="w-5 h-5 text-primary" />
              </span>
            </div>
            <p class="mt-2 text-2xl font-bold tabular-nums">
              {@pulse.req_per_min}
            </p>
            <p class="text-xs text-base-content/40 mt-1">
              ventana 5 min · {Stats.format_number(@pulse.request_count)} requests
            </p>
          </div>
        </div>

        <div id="live-errors" class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-5">
            <div class="flex items-center justify-between">
              <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                Tasa de error
              </span>
              <span class="flex items-center justify-center w-9 h-9 rounded-lg bg-error/10">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-error" />
              </span>
            </div>
            <p class="mt-2 text-2xl font-bold tabular-nums">
              {@pulse.error_rate}%
            </p>
            <p class="text-xs text-base-content/40 mt-1">
              {Stats.format_number(@pulse.error_count)} errores en 5 min
            </p>
          </div>
        </div>

        <div id="live-inflight" class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-5">
            <div class="flex items-center justify-between">
              <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
                En vuelo
              </span>
              <span class="flex items-center justify-center w-9 h-9 rounded-lg bg-accent/10">
                <.icon name="hero-paper-airplane" class="w-5 h-5 text-accent" />
              </span>
            </div>
            <p class="mt-2 text-2xl font-bold tabular-nums">
              {Stats.format_number(@inflight_count)}
            </p>
            <p class="text-xs text-base-content/40 mt-1">
              requests en curso ahora
            </p>
          </div>
        </div>
      </div>

      <%!-- KPIs de hoy (día calendario) --%>
      <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <div id="live-today-requests" class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-5">
            <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Hoy · requests
            </span>
            <p class="mt-2 text-2xl font-bold tabular-nums">
              {Stats.format_number(@today_metrics.requests_total)}
            </p>
          </div>
        </div>
        <div id="live-today-cost" class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-5">
            <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Hoy · costo
            </span>
            <p class="mt-2 text-2xl font-bold tabular-nums">
              ${Stats.format_decimal(@today_metrics.cost_usd)}
            </p>
          </div>
        </div>
        <div id="live-today-tokens" class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-5">
            <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Hoy · tokens
            </span>
            <p class="mt-2 text-2xl font-bold tabular-nums">
              {Stats.format_compact(@today_metrics.prompt_tokens + @today_metrics.completion_tokens)}
            </p>
            <p class="text-xs text-base-content/40 mt-1">
              {Stats.format_compact(@today_metrics.prompt_tokens)} in · {Stats.format_compact(
                @today_metrics.completion_tokens
              )} out
            </p>
            <p class="text-xs text-base-content/40">
              {if(
                @today_metrics.cache_read_tokens in [nil, 0] and
                  @today_metrics.cache_creation_tokens in [nil, 0],
                do: "cache: —",
                else:
                  "cache: " <>
                    Stats.format_compact(
                      (@today_metrics.cache_read_tokens || 0) +
                        (@today_metrics.cache_creation_tokens || 0)
                    ) <>
                    " (" <>
                    Stats.cache_hit_pct(
                      @today_metrics.prompt_tokens,
                      @today_metrics.cache_read_tokens
                    ) <> " hit)"
              )}
            </p>
          </div>
        </div>
        <div id="live-today-latency" class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-5">
            <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Hoy · latencia
            </span>
            <p class="mt-2 text-2xl font-bold tabular-nums">
              {Stats.format_ms(@today_metrics.avg_latency_ms)}
            </p>
            <p class="text-xs text-base-content/40 mt-1">
              p95: {Stats.format_ms(@today_metrics.p95_latency_ms)}
            </p>
          </div>
        </div>
      </div>

      <%!-- Gráfica: requests por minuto (últimos 60 min) --%>
      <div class="card bg-base-100 border border-base-300 shadow-sm" id="live-minute-chart">
        <div class="card-body p-4 gap-2">
          <div class="flex items-center justify-between">
            <h2 class="card-title text-base">
              <.icon name="hero-chart-bar" class="w-5 h-5 text-base-content/60" />
              Requests por minuto · últimos 60 min
            </h2>
          </div>
          <%= if @minute_series != [] and @minute_series_max > 0 do %>
            <div class="flex items-end gap-px h-40 mt-2">
              <div
                :for={row <- @minute_series}
                class="flex-1 group relative flex items-end h-full"
                title={"#{Stats.format_dt(row.bucket)} · #{Stats.format_number(row.request_count)} req"}
              >
                <div
                  class="w-full rounded-t bg-primary/80 group-hover:bg-primary transition-colors"
                  style={"height: #{bar_height_pct(row.request_count, @minute_series_max)}%"}
                >
                </div>
              </div>
            </div>
            <div class="flex justify-between text-[10px] text-base-content/40 mt-1">
              <span>-60 min</span>
              <span>-30 min</span>
              <span>ahora</span>
            </div>
          <% else %>
            <p class="text-sm text-base-content/40 py-6 text-center">
              Sin requests en la última hora.
            </p>
          <% end %>
        </div>
      </div>

      <%!-- En vuelo: por modelo --%>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <div class="card bg-base-100 border border-base-300 shadow-sm" id="live-inflight-models">
          <div class="card-body p-4">
            <h2 class="card-title text-base">
              <.icon name="hero-paper-airplane" class="w-5 h-5 text-base-content/60" />
              En vuelo por modelo
            </h2>
            <%= if @inflight_by_model == [] do %>
              <p class="text-sm text-base-content/40 py-4 text-center">
                Nada en vuelo ahora mismo.
              </p>
            <% else %>
              <ul class="mt-3 space-y-2">
                <li
                  :for={entry <- @inflight_by_model}
                  class="flex items-center justify-between text-sm"
                  id={"live-inflight-model-#{entry.model}"}
                >
                  <span class="truncate max-w-[200px] font-mono text-xs">
                    {entry.model}
                  </span>
                  <span class="badge badge-sm badge-primary badge-outline">
                    {entry.count}
                  </span>
                </li>
              </ul>
            <% end %>
          </div>
        </div>

        <%!-- Feed: últimos requests --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm" id="live-feed-card">
          <div class="card-body p-4">
            <div class="flex items-center justify-between">
              <h2 class="card-title text-base">
                <.icon name="hero-signal" class="w-5 h-5 text-base-content/60" /> Últimos requests
              </h2>
              <.link navigate={~p"/logs"} class="btn btn-xs btn-ghost" id="live-feed-all">
                Ver todos <.icon name="hero-arrow-right" class="w-3 h-3" />
              </.link>
            </div>
            <div id="live-feed" phx-update="stream" class="mt-3 space-y-1">
              <div
                :for={{id, log} <- @streams.live_feed}
                id={id}
                class="flex items-center justify-between gap-2 text-xs py-1 border-b border-base-200/60 last:border-0"
              >
                <span class="font-mono truncate max-w-[140px]" title={log.model_requested}>
                  {log.model_requested || "—"}
                </span>
                <span class="text-base-content/50 truncate flex-1" title={feed_who(log)}>
                  {feed_who(log)}
                </span>
                <span class={[
                  "shrink-0 font-mono",
                  status_class(log.status_code)
                ]}>
                  {log.status_code}
                </span>
                <span class="shrink-0 font-mono text-base-content/60 tabular-nums">
                  {feed_cost(log)}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp bar_height_pct(count, max) when max > 0, do: round(count / max * 100)
  defp bar_height_pct(_count, _max), do: 0

  defp status_class(code) when code >= 500, do: "text-error"
  defp status_class(code) when code >= 400, do: "text-warning"
  defp status_class(_code), do: "text-success"

  defp feed_who(%{subject_type: "service", service: %{name: name}}), do: "svc · #{name}"
  defp feed_who(%{group_member: %{user: %{email: email}}}), do: email
  defp feed_who(%{group_member_id: nil}), do: "—"
  defp feed_who(_log), do: "—"

  defp feed_cost(%{provider_cost_usd: %Decimal{} = d}) do
    "$" <> Stats.format_decimal(Decimal.round(d, 4))
  end

  defp feed_cost(_log), do: "$0"
end
