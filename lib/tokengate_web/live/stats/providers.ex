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
  attr :list_search, :any, required: true
  attr :per_page, :integer, default: 10
  attr :shown_counts, :map, required: true

  def providers(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-end flex-wrap gap-3">
        <.link
          href={"/stats/export?type=providers&period=#{@period}"}
          class="btn btn-sm btn-ghost"
          id="csv-providers"
        >
          <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> CSV
        </.link>
      </div>

      <div class="card bg-base-100 border border-base-300 shadow-sm" id="provider-ranking">
        <div class="card-body">
          <h2 class="card-title text-base">
            <.icon name="hero-trophy" class="w-5 h-5 text-base-content/60" /> {gettext("Providers")}
          </h2>
          <p class="text-xs text-base-content/60">
            {gettext(
              "One row per provider with its basic information in the period (%{period}). The podium is marked with a medal and the name opens the detail: its metrics, its models and the users, services and limit profiles that use it.",
              period: Stats.period_label(@period)
            )}
          </p>
          <%= if Stats.has_data?(@provider_ranking) do %>
            <%!-- El puesto se toma de la clasificación completa, no del listado
                 filtrado: el puesto de cada proveedor no cambia porque el
                 usuario escriba en el buscador. --%>
            <% rows =
              @provider_ranking
              |> Enum.with_index(1)
              |> Enum.filter(fn {row, _rank} ->
                Stats.matches?(@list_search, row.provider_name)
              end) %>
            <% list_rows = Stats.shown_rows(rows, "provider-list", @shown_counts, @per_page) %>
            <div class="mt-3">
              <Stats.list_search
                id="provider-list-search"
                value={@list_search}
                placeholder={gettext("Filter by provider…")}
              />
            </div>
            <div class="mt-3 overflow-x-auto">
              <.table
                id="provider-table"
                rows={list_rows}
                row_id={fn {row, _rank} -> "provider-ranking-row-#{row.provider_id}" end}
              >
                <:col :let={{_row, rank}} label={gettext("Rank")} align="center">
                  <span class="inline-flex w-6 justify-center">
                    <Stats.medal rank={rank} />
                  </span>
                </:col>
                <:col :let={{row, _rank}} label={gettext("Provider")}>
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
                <:col :let={{row, _rank}} label={gettext("Tier")} align="right">
                  <span class={["badge badge-sm", Stats.tier_badge_class(row.tier)]}>{row.tier}</span>
                </:col>
                <:col :let={{row, _rank}} label={gettext("Score")} align="right">
                  <span class="font-mono tabular-nums">{row.score || "—"}</span>
                </:col>
                <:col :let={{row, _rank}} label={gettext("Requests")} align="right">
                  <span class="font-mono tabular-nums">{Stats.format_number(row.request_count)}</span>
                </:col>
                <:col :let={{row, _rank}} label={gettext("Failures")} align="right">
                  <span class={[
                    "font-mono tabular-nums",
                    row.error_rate >= 0.05 && "text-error",
                    row.error_rate > 0 && row.error_rate < 0.05 && "text-warning"
                  ]}>
                    {Stats.format_percent(row.error_rate)}
                  </span>
                </:col>
                <:col :let={{row, _rank}} label={gettext("Latency")} align="right">
                  <span class="font-mono tabular-nums">{Stats.format_ms(row.avg_latency_ms)}</span>
                </:col>
                <:col :let={{row, _rank}} label={gettext("P95")} align="right">
                  <span class="font-mono tabular-nums">{Stats.format_ms(row.p95_latency_ms)}</span>
                </:col>
                <:col :let={{row, _rank}} label={gettext("TTFT")} align="right">
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
