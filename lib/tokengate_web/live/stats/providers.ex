defmodule TokengateWeb.StatsLive.Providers do
  @moduledoc """
  Sección providers (Infra) de /stats. Template renderizado por
  `TokengateWeb.StatsLive` vía `<.live_component>`; helpers de formato
  vía `TokengateWeb.StatsHelpers`.

  El ranking de proveedores vivía en el Resumen (`:index`) y se movió acá
  para no recomputar el `percentile_cont` sobre todo el período en cada
  recarga del broadcast `logs:new`.

  Se renderiza como LISTADO (no tabla): rango con color, el nombre como
  identificador y las métricas de cada proveedor a la derecha. El buscador
  filtra por nombre en vivo.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  attr :provider_ranking, :any, required: true
  attr :period, :any, required: true
  attr :list_search, :any, required: true

  def providers(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 border border-base-300 shadow-sm" id="provider-ranking">
        <div class="card-body">
          <h2 class="card-title text-base">
            <.icon name="hero-trophy" class="w-5 h-5 text-base-content/60" /> Ranking de proveedores
          </h2>
          <p class="text-xs text-base-content/60">
            Clasificación por confiabilidad (fallos) y velocidad (latencia) en el período
            ({Stats.period_label(@period)}). Tier S es el mejor; "—" significa menos de 10 requests.
          </p>
          <%= if Stats.has_data?(@provider_ranking) do %>
            <%!-- El rango se toma de la clasificación completa, no del listado
                 filtrado: el puesto de cada proveedor no cambia porque el
                 usuario escriba en el buscador. --%>
            <% rows =
              @provider_ranking
              |> Enum.with_index(1)
              |> Enum.filter(fn {row, _rank} ->
                Stats.matches?(@list_search, row.provider_name)
              end) %>
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
              <ul class="mt-2" id="provider-list">
                <Stats.ranked_row
                  :for={{row, rank} <- rows}
                  rank={rank}
                  title={row.provider_name}
                  id={"provider-ranking-row-#{row.provider_id}"}
                >
                  <:metrics>
                    <Stats.metric_cell label="Tier">
                      <span class={["badge badge-sm", Stats.tier_badge_class(row.tier)]}>
                        {row.tier}
                      </span>
                    </Stats.metric_cell>
                    <Stats.metric_cell label="Score" value={row.score || "—"} />
                    <Stats.metric_cell
                      label="Requests"
                      value={Stats.format_number(row.request_count)}
                    />
                    <Stats.metric_cell
                      label="Fallos"
                      value={Stats.format_percent(row.error_rate)}
                      class={[
                        row.error_rate >= 0.05 && "text-error",
                        row.error_rate > 0 && row.error_rate < 0.05 && "text-warning"
                      ]}
                    />
                    <Stats.metric_cell
                      label="Latencia"
                      value={Stats.format_ms(row.avg_latency_ms)}
                    />
                    <Stats.metric_cell label="P95" value={Stats.format_ms(row.p95_latency_ms)} />
                    <Stats.metric_cell label="TTFT" value={Stats.format_ms(row.avg_ttft_ms)} />
                  </:metrics>
                </Stats.ranked_row>
              </ul>
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
