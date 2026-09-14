defmodule TokengateWeb.StatsLive.Providers do
  @moduledoc """
  Sección providers (Infra) de /stats. Template renderizado por
  `TokengateWeb.StatsLive` vía `<.live_component>`; helpers de formato
  vía `TokengateWeb.StatsHelpers`.

  El ranking de proveedores vivía en el Resumen (`:index`) y se movió acá
  para no recomputar el `percentile_cont` sobre todo el período en cada
  recarga del broadcast `logs:new`.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  attr :provider_ranking, :any, required: true
  attr :period, :any, required: true

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
            <div class="overflow-x-auto mt-3">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>#</th>
                    <th>Proveedor</th>
                    <th class="text-center">Tier</th>
                    <th class="text-right">Score</th>
                    <th class="text-right">Requests</th>
                    <th class="text-right">% Fallos</th>
                    <th class="text-right">Latencia prom</th>
                    <th class="text-right">P95</th>
                    <th class="text-right">TTFT prom</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={{row, idx} <- Enum.with_index(@provider_ranking, 1)}
                    id={"provider-ranking-row-#{row.provider_id}"}
                  >
                    <td class="text-base-content/60">{idx}</td>
                    <td class="font-medium truncate max-w-[180px]">
                      {row.provider_name}
                    </td>
                    <td class="text-center">
                      <span class={["badge badge-sm", Stats.tier_badge_class(row.tier)]}>
                        {row.tier}
                      </span>
                    </td>
                    <td class="text-right font-mono">{row.score || "—"}</td>
                    <td class="text-right font-mono">
                      {Stats.format_number(row.request_count)}
                    </td>
                    <td class={[
                      "text-right font-mono",
                      row.error_rate >= 0.05 && "text-error",
                      row.error_rate > 0 && row.error_rate < 0.05 && "text-warning"
                    ]}>
                      {Stats.format_percent(row.error_rate)}
                    </td>
                    <td class="text-right font-mono">{Stats.format_ms(row.avg_latency_ms)}</td>
                    <td class="text-right font-mono">{Stats.format_ms(row.p95_latency_ms)}</td>
                    <td class="text-right font-mono">{Stats.format_ms(row.avg_ttft_ms)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
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
