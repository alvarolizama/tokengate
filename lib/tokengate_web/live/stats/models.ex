defmodule TokengateWeb.StatsLive.Models do
  @moduledoc """
  Sección models (Modelos) de /stats. Template renderizado por
  `TokengateWeb.StatsLive`; helpers de formato vía `TokengateWeb.StatsHelpers`.

  Se renderiza como una TABLA ÚNICA: puesto (medalla oro/plata/bronce en el
  top 3) + nombre + el consumo de cada modelo en el período. El nombre es el
  enlace al detalle (`/stats/models/:id?period=…`), donde viven sus métricas,
  los proveedores que lo sirven y quién lo usa. El buscador filtra por nombre
  en vivo y el período se elige en el selector del hub, que sigue visible acá.

  Misma estructura que la tabla de proveedores. El puesto sale de la
  clasificación por consumo del período — no del listado ordenado o filtrado:
  ordenar por otra columna o escribir en el buscador no renumera las filas.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  import TokengateWeb.StatsHelpers, only: [sort_icon: 1]

  attr :breakdown_model, :any, required: true
  attr :period, :any, required: true
  attr :sort_field, :any, required: true
  attr :sort_direction, :any, required: true
  attr :list_search, :any, default: ""

  def models(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-end flex-wrap gap-3">
        <.link
          href={"/stats/export?type=models&period=#{@period}"}
          class="btn btn-sm btn-ghost"
          id="csv-models"
        >
          <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> CSV
        </.link>
      </div>

      <div class="card bg-base-100 border border-base-300 shadow-sm" id="model-ranking">
        <div class="card-body">
          <h2 class="card-title text-base">
            <.icon name="hero-rectangle-stack" class="w-5 h-5 text-base-content/60" /> Modelos
          </h2>
          <p class="text-xs text-base-content/60">
            Una fila por modelo con su consumo en el período
            ({Stats.period_label(@period)}). El podio va marcado con medalla y el
            nombre abre el detalle: sus métricas, los proveedores que lo sirven y
            quién lo usa.
          </p>
          <%= if Stats.has_data?(@breakdown_model) do %>
            <% model_total = Stats.breakdown_total(@breakdown_model) %>
            <%!-- Puesto = clasificación por consumo del período (completa), no la
                 del listado ordenado o filtrado. --%>
            <% ranks =
              @breakdown_model
              |> Enum.sort_by(& &1.request_count, :desc)
              |> Enum.map(& &1.model_id)
              |> Enum.with_index(1)
              |> Map.new() %>
            <% rows = Enum.filter(@breakdown_model, &Stats.matches?(@list_search, &1.model_name)) %>
            <div class="mt-3">
              <Stats.list_search
                id="model-list-search"
                value={@list_search}
                placeholder="Filtrar por modelo…"
              />
            </div>
            <%= if rows == [] do %>
              <p class="text-sm text-base-content/40 py-6 text-center" id="model-list-empty">
                Sin coincidencias.
              </p>
            <% else %>
              <div class="overflow-x-auto mt-3">
                <table class="table table-sm" id="model-table">
                  <thead>
                    <tr>
                      <th class="w-12">Puesto</th>
                      <th>
                        <button
                          phx-click="sort"
                          phx-value-field="model_name"
                          class="flex items-center gap-1 hover:text-primary"
                        >
                          Modelo
                          <.sort_icon
                            field={:model_name}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th class="text-right">
                        <button
                          phx-click="sort"
                          phx-value-field="request_count"
                          class="flex items-center justify-end gap-1 w-full hover:text-primary"
                        >
                          Requests
                          <.sort_icon
                            field={:request_count}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th class="text-right">
                        <button
                          phx-click="sort"
                          phx-value-field="cost_usd"
                          class="flex items-center justify-end gap-1 w-full hover:text-primary"
                        >
                          Costo
                          <.sort_icon
                            field={:cost_usd}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th class="text-right">
                        <button
                          phx-click="sort"
                          phx-value-field="prompt_tokens"
                          class="flex items-center justify-end gap-1 w-full hover:text-primary"
                        >
                          Tokens in
                          <.sort_icon
                            field={:prompt_tokens}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th class="text-right">
                        <button
                          phx-click="sort"
                          phx-value-field="completion_tokens"
                          class="flex items-center justify-end gap-1 w-full hover:text-primary"
                        >
                          Tokens out
                          <.sort_icon
                            field={:completion_tokens}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th class="text-right" title="Porcentaje de prompt tokens con cache hit">
                        Cache %
                      </th>
                      <th class="text-right">
                        <button
                          phx-click="sort"
                          phx-value-field="avg_tps"
                          class="flex items-center justify-end gap-1 w-full hover:text-primary"
                        >
                          TPS
                          <.sort_icon
                            field={:avg_tps}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={row <- rows}
                      id={"model-ranking-row-#{row.model_id || "unknown"}"}
                    >
                      <td>
                        <%= if rank = Map.get(ranks, row.model_id) do %>
                          <Stats.medal rank={rank} />
                        <% end %>
                      </td>
                      <td class="font-medium">
                        <%= if row.model_id do %>
                          <.link
                            patch={~p"/stats/models/#{row.model_id}?period=#{@period}"}
                            class="link link-hover inline-flex items-center gap-1"
                            id={"model-link-#{row.model_id}"}
                          >
                            {row.model_name}
                            <.icon name="hero-chevron-right" class="w-3.5 h-3.5 text-base-content/40" />
                          </.link>
                        <% else %>
                          {row.model_name}
                        <% end %>
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(row.request_count)}
                      </td>
                      <td class="text-right font-mono">
                        ${Stats.format_decimal(row.cost_usd)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(row.prompt_tokens)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(row.completion_tokens)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.cache_hit_pct(
                          row.prompt_tokens,
                          Map.get(row, :cache_read_tokens, 0)
                        )}
                      </td>
                      <td class="text-right font-mono">{Stats.format_tps(row.avg_tps)}</td>
                    </tr>
                  </tbody>
                  <tfoot>
                    <tr class="font-bold bg-base-200">
                      <td></td>
                      <td>Total · {length(rows)} modelos</td>
                      <td class="text-right font-mono">
                        {Stats.format_number(model_total.request_count)}
                      </td>
                      <td class="text-right font-mono">
                        ${Stats.format_decimal(model_total.cost_usd)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(model_total.prompt_tokens)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(model_total.completion_tokens)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.cache_hit_pct(
                          model_total.prompt_tokens,
                          Enum.reduce(@breakdown_model, 0, fn r, acc ->
                            acc + (Map.get(r, :cache_read_tokens, 0) || 0)
                          end)
                        )}
                      </td>
                      <td></td>
                    </tr>
                  </tfoot>
                </table>
              </div>
            <% end %>
          <% else %>
            <p class="text-sm text-base-content/40 py-6 text-center">
              Sin datos para este periodo.
            </p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
