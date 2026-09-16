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
            <.icon name="hero-trophy" class="w-5 h-5 text-base-content/60" /> Proveedores
          </h2>
          <p class="text-xs text-base-content/60">
            Una fila por proveedor con su información básica en el período
            ({Stats.period_label(@period)}). El podio va marcado con medalla y el
            nombre abre el detalle: sus métricas, sus modelos y los usuarios,
            servicios y grupos que lo usan.
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
                placeholder="Filtrar por proveedor…"
              />
            </div>
            <%= if rows == [] do %>
              <p class="text-sm text-base-content/40 py-6 text-center" id="provider-list-empty">
                Sin coincidencias.
              </p>
            <% else %>
              <div class="overflow-x-auto mt-3">
                <table class="table table-sm" id="provider-table">
                  <thead>
                    <tr>
                      <th class="w-12">Puesto</th>
                      <th>Proveedor</th>
                      <th class="text-right">Tier</th>
                      <th class="text-right">Score</th>
                      <th class="text-right">Requests</th>
                      <th class="text-right">Fallos</th>
                      <th class="text-right">Latencia</th>
                      <th class="text-right">P95</th>
                      <th class="text-right">TTFT</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={{row, rank} <- list_rows} id={"provider-ranking-row-#{row.provider_id}"}>
                      <td>
                        <Stats.medal rank={rank} />
                      </td>
                      <td class="font-medium">
                        <.link
                          patch={~p"/stats/providers/#{row.provider_id}?period=#{@period}"}
                          class="link link-hover inline-flex items-center gap-2"
                          id={"provider-link-#{row.provider_id}"}
                        >
                          <Stats.provider_logo logo_url={row.provider_logo_url} />
                          {row.provider_name}
                          <.icon name="hero-chevron-right" class="w-3.5 h-3.5 text-base-content/40" />
                        </.link>
                      </td>
                      <td class="text-right">
                        <span class={["badge badge-sm", Stats.tier_badge_class(row.tier)]}>
                          {row.tier}
                        </span>
                      </td>
                      <td class="text-right font-mono tabular-nums">{row.score || "—"}</td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(row.request_count)}
                      </td>
                      <td class={[
                        "text-right font-mono tabular-nums",
                        row.error_rate >= 0.05 && "text-error",
                        row.error_rate > 0 && row.error_rate < 0.05 && "text-warning"
                      ]}>
                        {Stats.format_percent(row.error_rate)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_ms(row.avg_latency_ms)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_ms(row.p95_latency_ms)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_ms(row.avg_ttft_ms)}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
              <Stats.show_more
                key="provider-list"
                id="provider-list-more"
                top={length(list_rows)}
                total={length(rows)}
              />
            <% end %>
          <% else %>
            <p class="text-sm text-base-content/40 py-6 text-center">
              Sin datos en este período.
            </p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
