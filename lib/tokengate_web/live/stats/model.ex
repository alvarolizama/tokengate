defmodule TokengateWeb.StatsLive.Model do
  @moduledoc """
  Detalle de un modelo (`/stats/models/:model_id`, action `:model`).

  Es el "interior" del ranking de modelos: las métricas del modelo en el
  período, los proveedores que lo sirven y los grupos y miembros que lo usan.
  Todo respeta el período elegido en el selector del hub.

  Gemelo de `TokengateWeb.StatsLive.Provider`: el tier/score/p95 salen de la
  misma clasificación que la tabla de modelos (`Rollup.model_ranking/2`), para
  que la fila de la tabla y el detalle no puedan decir cosas distintas.
  """
  use TokengateWeb, :html

  import TokengateWeb.KpiHelpers, only: [kpi_card: 1]
  import TokengateWeb.StatsHelpers, only: [sort_icon: 1]

  alias TokengateWeb.StatsHelpers, as: Stats

  attr :model, :any, required: true
  attr :model_ranking, :any, required: true
  attr :metrics, :any, required: true
  attr :breakdown_provider, :any, required: true
  attr :breakdown_group, :any, required: true
  attr :breakdown_member, :any, required: true
  attr :drilldown_series, :any, required: true
  attr :drilldown_series_labels, :any, required: true
  attr :period, :any, required: true
  attr :sort_field, :any, required: true
  attr :sort_direction, :any, required: true
  attr :per_page, :integer, default: 10
  attr :shown_counts, :map, required: true
  attr :stats_loading, :boolean, default: false

  def model(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between flex-wrap gap-3">
        <.link
          patch={~p"/stats/models?period=#{@period}"}
          class="btn btn-sm btn-ghost"
          id="model-back"
        >
          <.icon name="hero-arrow-left" class="w-4 h-4" /> Modelos
        </.link>
        <span class="text-xs text-base-content/60" id="model-metrics-period">
          Período: {Stats.period_label(@period)}
        </span>
      </div>

      <%= if @model == nil and not @stats_loading do %>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <p class="text-sm text-base-content/40 py-6 text-center" id="model-not-found">
              Modelo no encontrado.
            </p>
          </div>
        </div>
      <% end %>

      <%!-- El encabezado se pinta siempre; el nombre es null-safe porque el
           render estático (pre-async) todavía no trae :model. --%>
      <% row = @model && Enum.find(@model_ranking, &(&1.model_id == @model.id)) %>
      <div class="flex items-center gap-3 flex-wrap" id="model-detail-header">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-rectangle-stack" class="w-5 h-5 text-base-content/60" />
          {if @model, do: @model.name, else: "…"}
        </h2>
        <span :if={row} class={["badge badge-sm", Stats.tier_badge_class(row.tier)]}>
          {row.tier}
        </span>
        <span :if={row && row.score} class="text-xs text-base-content/50">
          score {row.score}
        </span>
        <span :if={@model && is_nil(row)} class="text-xs text-base-content/50">
          sin tráfico en el período
        </span>
      </div>

      <%= if @model do %>
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
          <.kpi_card
            id="model-kpi-requests"
            label="Requests"
            icon="hero-server-stack"
            accent="primary"
          >
            {Stats.format_number(@metrics.requests_total)}
          </.kpi_card>

          <.kpi_card
            id="model-kpi-cost"
            label="Costo"
            icon="hero-currency-dollar"
            accent="accent"
          >
            ${Stats.format_decimal(@metrics.cost_usd)}
          </.kpi_card>

          <.kpi_card
            id="model-kpi-tokens"
            label="Tokens"
            icon="hero-cpu-chip"
            accent="primary"
            title={
                      "#{Stats.format_number(@metrics.prompt_tokens)} in / #{Stats.format_number(@metrics.completion_tokens)} out"
                    }
          >
            <span class="flex items-baseline gap-2">
              {Stats.format_compact(@metrics.prompt_tokens)}
              <span class="text-sm text-base-content/50">in</span>
              <span class="text-base-content/30">/</span>
              {Stats.format_compact(@metrics.completion_tokens)}
              <span class="text-sm text-base-content/50">out</span>
            </span>
            <:sub>
              cache · {Stats.cache_hit_pct(@metrics.prompt_tokens, @metrics.cache_read_tokens)} hit
            </:sub>
          </.kpi_card>

          <.kpi_card id="model-kpi-tps" label="TPS" icon="hero-bolt" accent="accent">
            {Stats.format_tps(@metrics.avg_tps)}
          </.kpi_card>
        </div>

        <%!-- Daily usage sparkline: providers over time --%>
        <%= if @drilldown_series != [] do %>
          <% pivoted = Stats.pivot_daily_series(@drilldown_series) %>
          <% spark_max = Stats.daily_series_max(pivoted) %>
          <% labels = @drilldown_series_labels %>

          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4 gap-2">
              <div class="flex items-center justify-between">
                <h2 class="card-title text-base">
                  <.icon name="hero-chart-bar" class="w-5 h-5 text-base-content/60" />
                  Uso diario por proveedor
                </h2>
                <span class="text-[10px] text-base-content/40 hidden sm:inline">
                  {Stats.period_label(@period)}
                </span>
              </div>

              <div class="flex gap-4 mt-2">
                <%!-- Chart area --%>
                <div class="flex-1">
                  <div class="flex items-end gap-px h-32 relative">
                    <div
                      :for={day <- pivoted.days}
                      class="flex-1 flex flex-col items-center justify-end h-full group relative"
                    >
                      <%!-- Tooltip --%>
                      <div class="hidden group-hover:block absolute -top-1 -translate-y-full left-1/2 -translate-x-1/2 z-20 pointer-events-none">
                        <div class="bg-base-300 text-base-content text-[10px] rounded-md px-2 py-1 shadow-lg whitespace-nowrap">
                          <div class="font-semibold">
                            {Calendar.strftime(day, "%d %b")}
                          </div>
                          <div :for={label <- labels} class="flex justify-between gap-2">
                            <span class="truncate max-w-[100px]">{label}</span>
                            <span class="tabular-nums">
                              {Stats.format_number(Map.get(pivoted.series[label] || %{}, day, 0))}
                            </span>
                          </div>
                        </div>
                      </div>

                      <%!-- Stacked bar --%>
                      <div class="w-full flex flex-col-reverse rounded-t overflow-hidden">
                        <div
                          :for={label <- labels}
                          class={[
                            "w-full",
                            Stats.sparkline_color(Enum.find_index(labels, &(&1 == label)) || 0)
                          ]}
                          style={"height: #{Stats.sparkline_bar_height(Map.get(pivoted.series[label] || %{}, day, 0), spark_max)}%"}
                          title={"#{label}: #{Stats.format_number(Map.get(pivoted.series[label] || %{}, day, 0))}"}
                        />
                      </div>
                    </div>
                  </div>

                  <%!-- Day labels --%>
                  <div class="flex gap-px mt-1">
                    <span
                      :for={day <- pivoted.days}
                      class="flex-1 text-center text-[9px] text-base-content/40"
                    >
                      {Calendar.strftime(day, "%d")}
                    </span>
                  </div>
                </div>

                <%!-- Legend --%>
                <div class="w-40 shrink-0 border-l border-base-300 pl-3">
                  <div class="text-[10px] font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                    Proveedores
                  </div>
                  <div class="space-y-1.5">
                    <div
                      :for={{label, idx} <- Enum.with_index(labels)}
                      class="flex items-center gap-1.5"
                    >
                      <span class={["w-2 h-2 rounded-sm shrink-0", Stats.sparkline_color(idx)]} />
                      <span class="text-[10px] truncate flex-1">{label}</span>
                      <span class="text-[9px] text-base-content/50 shrink-0">
                        {Stats.format_number(
                          Stats.sparkline_label_total(pivoted.series[label] || %{})
                        )}
                      </span>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">
              <.icon name="hero-server-stack" class="w-5 h-5 text-base-content/60" />
              Proveedores que lo sirven
            </h2>
            <%= if Stats.has_data?(@breakdown_provider) do %>
              <% provider_total = Stats.breakdown_total(@breakdown_provider) %>
              <% provider_rows =
                Stats.shown_rows(@breakdown_provider, "model-providers", @shown_counts, @per_page) %>
              <div class="overflow-x-auto mt-3">
                <table class="table table-sm" id="model-providers">
                  <thead>
                    <tr>
                      <th>#</th>
                      <th>
                        <button
                          phx-click="sort"
                          phx-value-field="provider_name"
                          class="flex items-center gap-1 hover:text-primary"
                        >
                          Proveedor / Modelo
                          <.sort_icon
                            field={:provider_name}
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
                      <th
                        class="text-right"
                        title="Porcentaje de prompt tokens con cache hit"
                      >
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
                      :for={{row, idx} <- Enum.with_index(provider_rows, 1)}
                      id={"bd-provider-#{row.model_provider_id || "unknown"}"}
                    >
                      <td class="text-base-content/60">{idx}</td>
                      <td>
                        <div class="font-medium">
                          {row.provider_name}{if row.provider_model,
                            do: " · #{row.provider_model}"}
                        </div>
                        <div
                          :if={row.credential_name}
                          class="text-xs text-base-content/60"
                        >
                          {row.credential_name}
                        </div>
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
                      <td colspan="2">
                        Total · {Stats.distinct_providers(@breakdown_provider)} proveedores
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(provider_total.request_count)}
                      </td>
                      <td class="text-right font-mono">
                        ${Stats.format_decimal(provider_total.cost_usd)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(provider_total.prompt_tokens)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(provider_total.completion_tokens)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.cache_hit_pct(
                          provider_total.prompt_tokens,
                          provider_total.cache_read_tokens
                        )}
                      </td>
                      <td></td>
                    </tr>
                  </tfoot>
                </table>
              </div>
              <Stats.show_more
                key="model-providers"
                id="model-providers-more"
                top={length(provider_rows)}
                total={length(@breakdown_provider)}
              />
            <% else %>
              <p class="text-sm text-base-content/40 py-6 text-center">
                Sin datos para este periodo.
              </p>
            <% end %>
          </div>
        </div>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">
              <.icon name="hero-user-group" class="w-5 h-5 text-base-content/60" /> Grupos que lo usan
            </h2>
            <%= if Stats.has_data?(@breakdown_group) do %>
              <% group_total = Stats.breakdown_total(@breakdown_group) %>
              <% group_rows =
                Stats.shown_rows(@breakdown_group, "model-groups", @shown_counts, @per_page) %>
              <div class="overflow-x-auto mt-3">
                <table class="table table-sm" id="model-groups">
                  <thead>
                    <tr>
                      <th>
                        <button
                          phx-click="sort"
                          phx-value-field="group_name"
                          class="flex items-center gap-1 hover:text-primary"
                        >
                          Grupo
                          <.sort_icon
                            field={:group_name}
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
                      :for={row <- group_rows}
                      id={"bd-model-group-#{row.group_id}"}
                    >
                      <td class="font-medium">
                        <Stats.group_link
                          group_id={row.group_id}
                          name={row.group_name}
                          period={@period}
                          id={"bd-model-group-link-#{row.group_id}"}
                        />
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(row.request_count)}
                      </td>
                      <td class="text-right font-mono">
                        ${Stats.format_decimal(row.cost_usd)}
                      </td>
                      <td class="text-right font-mono">{Stats.format_tps(row.avg_tps)}</td>
                    </tr>
                  </tbody>
                  <tfoot>
                    <tr class="font-bold bg-base-200">
                      <td>Total · {length(@breakdown_group)} grupos</td>
                      <td class="text-right font-mono">
                        {Stats.format_number(group_total.request_count)}
                      </td>
                      <td class="text-right font-mono">
                        ${Stats.format_decimal(group_total.cost_usd)}
                      </td>
                      <td></td>
                    </tr>
                  </tfoot>
                </table>
              </div>
              <Stats.show_more
                key="model-groups"
                id="model-groups-more"
                top={length(group_rows)}
                total={length(@breakdown_group)}
              />
            <% else %>
              <p class="text-sm text-base-content/40 py-6 text-center">
                Sin datos para este periodo.
              </p>
            <% end %>
          </div>
        </div>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">
              <.icon name="hero-user" class="w-5 h-5 text-base-content/60" /> Miembros que lo usan
            </h2>
            <%= if Stats.has_data?(@breakdown_member) do %>
              <% member_total = Stats.breakdown_total(@breakdown_member) %>
              <% member_rows =
                Stats.shown_rows(@breakdown_member, "model-members", @shown_counts, @per_page) %>
              <div class="overflow-x-auto mt-3">
                <table class="table table-sm" id="model-members">
                  <thead>
                    <tr>
                      <th>
                        <button
                          phx-click="sort"
                          phx-value-field="group_name"
                          class="flex items-center gap-1 hover:text-primary"
                        >
                          Grupo
                          <.sort_icon
                            field={:group_name}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th>
                        <button
                          phx-click="sort"
                          phx-value-field="user_email"
                          class="flex items-center gap-1 hover:text-primary"
                        >
                          Usuario
                          <.sort_icon
                            field={:user_email}
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
                      :for={row <- member_rows}
                      id={"bd-model-member-#{row.group_member_id}"}
                    >
                      <td>
                        <Stats.group_link
                          group_id={row.group_id}
                          name={row.group_name}
                          period={@period}
                          id={"bd-model-member-group-#{row.group_member_id}"}
                        />
                      </td>
                      <td class="font-mono text-sm">
                        <.link
                          navigate={~p"/stats/users/#{row.user_id}"}
                          class="link link-hover"
                        >
                          {row.user_email}
                        </.link>
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(row.request_count)}
                      </td>
                      <td class="text-right font-mono">
                        ${Stats.format_decimal(row.cost_usd)}
                      </td>
                      <td class="text-right font-mono">{Stats.format_tps(row.avg_tps)}</td>
                    </tr>
                  </tbody>
                  <tfoot>
                    <tr class="font-bold bg-base-200">
                      <td colspan="2">
                        Total · {Stats.distinct_users(@breakdown_member)} usuarios
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(member_total.request_count)}
                      </td>
                      <td class="text-right font-mono">
                        ${Stats.format_decimal(member_total.cost_usd)}
                      </td>
                      <td></td>
                    </tr>
                  </tfoot>
                </table>
              </div>
              <Stats.show_more
                key="model-members"
                id="model-members-more"
                top={length(member_rows)}
                total={length(@breakdown_member)}
              />
            <% else %>
              <p class="text-sm text-base-content/40 py-6 text-center">
                Sin datos para este periodo.
              </p>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
