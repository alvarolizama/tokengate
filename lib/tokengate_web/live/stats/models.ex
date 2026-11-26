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

  attr :breakdown_model, :any, required: true
  attr :period, :any, required: true
  attr :sort_field, :any, required: true
  attr :sort_direction, :any, required: true
  attr :list_search, :any, default: ""
  attr :per_page, :integer, default: 10
  attr :shown_counts, :map, required: true

  def models(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 border border-base-300 shadow-sm" id="model-ranking">
        <div class="card-body">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div class="min-w-0">
              <h2 class="card-title text-base">
                <.icon name="hero-rectangle-stack" class="w-5 h-5 text-base-content/60 shrink-0" />
                {gettext("Models")}
              </h2>
              <p class="text-xs text-base-content/60 mt-1">
                {gettext(
                  "One row per model with its consumption in the period (%{period}). The podium is marked with a medal and the name opens the detail: its metrics, the providers that serve it and who uses it.",
                  period: Stats.period_label(@period)
                )}
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-2 shrink-0">
              <Stats.list_search
                :if={Stats.has_data?(@breakdown_model)}
                id="model-list-search"
                value={@list_search}
                placeholder={gettext("Filter by model…")}
              />
              <.link
                href={"/stats/export?type=models&period=#{@period}"}
                class="btn btn-sm btn-ghost"
                id="csv-models"
              >
                <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> CSV
              </.link>
            </div>
          </div>
          <%= if Stats.has_data?(@breakdown_model) do %>
            <%!-- Puesto = clasificación por consumo del período (completa), no la
                 del listado ordenado o filtrado. --%>
            <% ranks =
              @breakdown_model
              |> Enum.sort_by(& &1.request_count, :desc)
              |> Enum.map(& &1.model_id)
              |> Enum.with_index(1)
              |> Map.new() %>
            <% rows = Enum.filter(@breakdown_model, &Stats.matches?(@list_search, &1.model_name)) %>
            <% model_total = Stats.breakdown_total(rows) %>
            <% list_rows = Stats.shown_rows(rows, "model-list", @shown_counts, @per_page) %>
            <div class="mt-3 overflow-x-auto">
              <.table
                id="model-table"
                rows={list_rows}
                row_id={fn row -> "model-ranking-row-#{row.model_id || "unknown"}" end}
                sort_field={@sort_field}
                sort_direction={@sort_direction}
                sort_event="sort"
              >
                <:col :let={row} label={gettext("Rank")} align="center">
                  <span class="inline-flex w-6 justify-center">
                    <%= if rank = Map.get(ranks, row.model_id) do %>
                      <Stats.medal rank={rank} />
                    <% end %>
                  </span>
                </:col>
                <:col :let={row} label={gettext("Model")} field={:model_name}>
                  <%= if row.model_id do %>
                    <.link
                      patch={~p"/stats/models/#{row.model_id}?period=#{@period}"}
                      class="link link-hover font-medium inline-flex items-center gap-1"
                      id={"model-link-#{row.model_id}"}
                    >
                      {row.model_name}
                      <.icon name="hero-chevron-right" class="w-3.5 h-3.5 text-base-content/40" />
                    </.link>
                  <% else %>
                    <span class="font-medium">{row.model_name}</span>
                  <% end %>
                </:col>
                <:col :let={row} label={gettext("Requests")} field={:request_count} align="right">
                  <span class="font-mono tabular-nums">{Stats.format_number(row.request_count)}</span>
                </:col>
                <:col :let={row} label={gettext("Cost")} field={:cost_usd} align="right">
                  <span class="font-mono tabular-nums">${Stats.format_decimal(row.cost_usd)}</span>
                </:col>
                <:col :let={row} label={gettext("Tokens in")} field={:prompt_tokens} align="right">
                  <span class="font-mono tabular-nums">{Stats.format_number(row.prompt_tokens)}</span>
                </:col>
                <:col
                  :let={row}
                  label={gettext("Tokens out")}
                  field={:completion_tokens}
                  align="right"
                >
                  <span class="font-mono tabular-nums">{Stats.format_number(row.completion_tokens)}</span>
                </:col>
                <:col
                  :let={row}
                  label={gettext("Cache %")}
                  align="right"
                  tooltip={gettext("Percentage of prompt tokens with cache hit")}
                >
                  <span class="font-mono tabular-nums">
                    {Stats.cache_hit_pct(row.prompt_tokens, Map.get(row, :cache_read_tokens, 0))}
                  </span>
                </:col>
                <:col :let={row} label={gettext("TPS")} field={:avg_tps} align="right">
                  <span class="font-mono tabular-nums">{Stats.format_tps(row.avg_tps)}</span>
                </:col>
                <:empty>
                  <div id="model-list-empty">
                    <.icon name="hero-magnifying-glass" class="w-10 h-10 mx-auto mb-2 opacity-40" />
                    <p>{gettext("No matches.")}</p>
                  </div>
                </:empty>
              </.table>
            </div>
            <div
              id="model-table-totals"
              class="mt-3 flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1 text-xs"
            >
              <span class="font-semibold text-base-content/70">
                {gettext("Total · %{count} models", count: length(rows))}
              </span>
              <%= if model_total do %>
                <div class="flex flex-wrap items-baseline gap-x-5 gap-y-1 font-mono tabular-nums text-base-content/80">
                  <span>
                    <span class="text-base-content/40">{gettext("Requests")}</span>
                    <span class="ml-1">{Stats.format_number(model_total.request_count)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Cost")}</span>
                    <span class="ml-1">${Stats.format_decimal(model_total.cost_usd)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Tokens in")}</span>
                    <span class="ml-1">{Stats.format_number(model_total.prompt_tokens)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Tokens out")}</span>
                    <span class="ml-1">{Stats.format_number(model_total.completion_tokens)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Cache %")}</span>
                    <span class="ml-1">
                      {Stats.cache_hit_pct(
                        model_total.prompt_tokens,
                        model_total.cache_read_tokens
                      )}
                    </span>
                  </span>
                </div>
              <% end %>
            </div>
            <Stats.show_more
              key="model-list"
              id="model-list-more"
              top={length(list_rows)}
              total={length(rows)}
            />
          <% else %>
            <p class="text-sm text-base-content/40 py-6 text-center">
              {gettext("No data for this period.")}
            </p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
