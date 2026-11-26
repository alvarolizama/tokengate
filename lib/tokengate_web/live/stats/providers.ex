defmodule TokengateWeb.StatsLive.Providers do
  @moduledoc """
  Sección providers (Infra) de /stats. Template renderizado por
  `TokengateWeb.StatsLive` vía `<.live_component>`; helpers de formato
  vía `TokengateWeb.StatsHelpers`.

  El ranking de proveedores vivía en el Resumen (`:index`) y se movió acá
  para no recomputar el `percentile_cont` sobre todo el período en cada
  recarga del broadcast `logs:new`.

  Se renderiza como una TABLA ÚNICA: puesto (medalla oro/plata/bronce en el
  top 3) + nombre + la información básica de cada proveedor. El nombre es el
  enlace al detalle (`/stats/providers/:id?period=…`), donde viven sus
  métricas, sus modelos y quién lo usa. El buscador filtra por nombre en vivo
  y el período se elige en el selector del hub, que sigue visible acá.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  attr :provider_ranking, :any, required: true
  attr :period, :any, required: true
  attr :sort_field, :any, required: true
  attr :sort_direction, :any, required: true
  attr :list_search, :any, required: true
  attr :per_page, :integer, default: 10
  attr :shown_counts, :map, required: true

  def providers(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 border border-base-300 shadow-sm" id="provider-ranking">
        <div class="card-body">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div class="min-w-0">
              <h2 class="card-title text-base">
                <.icon name="hero-trophy" class="w-5 h-5 text-base-content/60 shrink-0" />
                {gettext("Providers")}
              </h2>
              <p class="text-xs text-base-content/60 mt-1">
                {gettext(
                  "One row per provider with its basic information in the period (%{period}). The podium is marked with a medal and the name opens the detail: its metrics, its models and the users, services and limit profiles that use it.",
                  period: Stats.period_label(@period)
                )}
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-2 shrink-0">
              <Stats.list_search
                :if={Stats.has_data?(@provider_ranking)}
                id="provider-list-search"
                value={@list_search}
                placeholder={gettext("Filter by provider…")}
              />
              <.link
                href={"/stats/export?type=providers&period=#{@period}"}
                class="btn btn-sm btn-ghost"
                id="csv-providers"
              >
                <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> CSV
              </.link>
            </div>
          </div>
          <%= if Stats.has_data?(@provider_ranking) do %>
            <%!-- El puesto se toma de la clasificación completa por score, no del
                 listado ordenado o filtrado: el puesto de cada proveedor no
                 cambia porque el usuario ordene o escriba en el buscador. --%>
            <% ranks =
              @provider_ranking
              |> Enum.sort_by(&{if(&1.score, do: 0, else: 1), -(&1.score || 0), &1.provider_name})
              |> Enum.map(& &1.provider_id)
              |> Enum.with_index(1)
              |> Map.new() %>
            <% rows =
              Enum.filter(
                @provider_ranking,
                &Stats.matches?(@list_search, &1.provider_name)
              ) %>
            <% total_cost =
              Enum.reduce(rows, Decimal.new(0), fn r, acc ->
                Decimal.add(acc, Map.get(r, :cost_usd, Decimal.new(0)))
              end) %>
            <% list_rows = Stats.shown_rows(rows, "provider-list", @shown_counts, @per_page) %>
            <div class="mt-3 overflow-x-auto">
              <.table
                id="provider-table"
                rows={list_rows}
                row_id={fn row -> "provider-ranking-row-#{row.provider_id}" end}
                sort_field={@sort_field}
                sort_direction={@sort_direction}
                sort_event="sort"
              >
                <:col :let={row} label={gettext("Rank")} align="center">
                  <span class="inline-flex w-6 justify-center">
                    <%= if rank = Map.get(ranks, row.provider_id) do %>
                      <Stats.medal rank={rank} />
                    <% end %>
                  </span>
                </:col>
                <:col :let={row} label={gettext("Provider")} field={:provider_name}>
                  <.link
                    patch={~p"/stats/providers/#{row.provider_id}?period=#{@period}"}
                    class="link link-hover font-medium inline-flex items-center gap-2"
                    id={"provider-link-#{row.provider_id}"}
                  >
                    <Stats.provider_logo logo_url={row.provider_logo_url} />
                    {Stats.provider_label(row.provider_name)}
                    <.icon name="hero-chevron-right" class="w-3.5 h-3.5 text-base-content/40" />
                  </.link>
                </:col>
                <:col :let={row} label={gettext("Tier")} align="right">
                  <span class={["badge badge-sm", Stats.tier_badge_class(row.tier)]}>{row.tier}</span>
                </:col>
                <:col :let={row} label={gettext("Score")} field={:score} align="right">
                  <span class="font-mono tabular-nums">{row.score || "—"}</span>
                </:col>
                <:col :let={row} label={gettext("Requests")} field={:request_count} align="right">
                  <span class="font-mono tabular-nums">{Stats.format_number(row.request_count)}</span>
                </:col>
                <:col :let={row} label={gettext("Cost")} field={:cost_usd} align="right">
                  <span class="font-mono tabular-nums">
                    ${Stats.format_decimal(Map.get(row, :cost_usd, Decimal.new(0)))}
                  </span>
                </:col>
                <:col :let={row} label={gettext("Share")} align="right">
                  <span class="font-mono tabular-nums text-base-content/70">
                    {Stats.cost_share_pct(Map.get(row, :cost_usd, Decimal.new(0)), total_cost)}%
                  </span>
                </:col>
                <:col :let={row} label={gettext("Cost / req")} align="right">
                  <span class="font-mono tabular-nums text-base-content/70">
                    {Stats.cost_per_request(
                      Map.get(row, :cost_usd, Decimal.new(0)),
                      row.request_count
                    )}
                  </span>
                </:col>
                <:col :let={row} label={gettext("Failures")} field={:error_rate} align="right">
                  <span class={[
                    "font-mono tabular-nums",
                    row.error_rate >= 0.05 && "text-error",
                    row.error_rate > 0 && row.error_rate < 0.05 && "text-warning"
                  ]}>
                    {Stats.format_percent(row.error_rate)}
                  </span>
                </:col>
                <:col :let={row} label={gettext("Latency")} field={:avg_latency_ms} align="right">
                  <span class="font-mono tabular-nums">{Stats.format_ms(row.avg_latency_ms)}</span>
                </:col>
                <:col :let={row} label={gettext("P95")} field={:p95_latency_ms} align="right">
                  <span class="font-mono tabular-nums">{Stats.format_ms(row.p95_latency_ms)}</span>
                </:col>
                <:col :let={row} label={gettext("TTFT")} field={:avg_ttft_ms} align="right">
                  <span class="font-mono tabular-nums">{Stats.format_ms(row.avg_ttft_ms)}</span>
                </:col>
                <:empty>
                  <div id="provider-list-empty">
                    <.icon name="hero-magnifying-glass" class="w-10 h-10 mx-auto mb-2 opacity-40" />
                    <p>{gettext("No matches.")}</p>
                  </div>
                </:empty>
              </.table>
            </div>
            <% total_requests = Enum.reduce(rows, 0, &(&1.request_count + &2)) %>
            <% total_errors = Enum.reduce(rows, 0, &(&1.error_count + &2)) %>
            <div
              id="provider-table-totals"
              class="mt-3 flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1 text-xs"
            >
              <span class="font-semibold text-base-content/70">
                {gettext("Total · %{count} providers", count: length(rows))}
              </span>
              <%= if rows != [] do %>
                <div class="flex flex-wrap items-baseline gap-x-5 gap-y-1 font-mono tabular-nums text-base-content/80">
                  <span>
                    <span class="text-base-content/40">{gettext("Requests")}</span>
                    <span class="ml-1">{Stats.format_number(total_requests)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Cost")}</span>
                    <span class="ml-1">${Stats.format_decimal(total_cost)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Failures")}</span>
                    <span class="ml-1">
                      {Stats.format_percent(
                        if(total_requests > 0, do: total_errors / total_requests, else: 0.0)
                      )}
                    </span>
                  </span>
                </div>
              <% end %>
            </div>
            <Stats.show_more
              key="provider-list"
              id="provider-list-more"
              top={length(list_rows)}
              total={length(rows)}
            />
          <% else %>
            <p class="text-sm text-base-content/40 py-6 text-center">
              {gettext("No data in this period.")}
            </p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
