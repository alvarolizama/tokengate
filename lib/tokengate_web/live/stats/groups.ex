defmodule TokengateWeb.StatsLive.Groups do
  @moduledoc """
  Sección groups de /stats. Template renderizado por
  `TokengateWeb.StatsLive` vía `<.live_component>`; helpers de formato
  vía `TokengateWeb.StatsHelpers`.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  import TokengateWeb.KpiHelpers,
    only: [
      kpi_card: 1,
      cache_hit_rate: 2,
      format_cache_value: 2,
      format_hit_rate: 1
    ]

  import TokengateWeb.StatsHelpers, only: [sort_icon: 1]

  attr :metrics, :any, required: true
  attr :breakdown_group, :any, required: true
  attr :breakdown_member, :any, required: true
  attr :breakdown_model, :any, required: true
  attr :drilldown_series, :any, required: true
  attr :drilldown_series_labels, :any, required: true
  attr :group_filter, :any, required: true
  attr :group, :any, default: nil
  attr :group_budgets, :any, default: []
  attr :group_budget, :any, default: nil
  attr :list_search, :any, default: ""
  attr :period, :any, required: true
  attr :sort_field, :any, required: true
  attr :sort_direction, :any, required: true
  attr :per_page, :integer, default: 10
  attr :shown_counts, :map, required: true

  def groups(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-end flex-wrap gap-3">
        <.link
          href={
            if @group_filter,
              do: "/stats/export?type=groups&period=#{@period}&group_id=#{@group_filter}",
              else: "/stats/export?type=groups&period=#{@period}"
          }
          class="btn btn-sm btn-ghost"
          id="csv-groups"
        >
          <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> CSV
        </.link>
      </div>

      <%= if @group_filter do %>
        <div class="space-y-6">
          <%!-- Breadcrumb — el hub vive en /stats/profiles/:id (action :group);
               el drill-down ?group_id= de :groups usa el mismo template --%>
          <div class="flex items-center justify-between flex-wrap gap-2">
            <div class="flex items-center gap-2 text-xs text-base-content/60">
              <.link navigate={~p"/stats/profiles?period=#{@period}"} class="hover:underline">
                {gettext("Limit profiles")}
              </.link>
              <span>›</span>
              <span class="font-medium text-base-content/80">
                <%!-- null-safe: el render estático (pre-async) aún no trae :group --%>
                {if @group, do: @group.name, else: "…"}
              </span>
            </div>

            <%= if @group_budget do %>
              <div class="w-full max-w-xs" id="group-budget-bar">
                <span class="text-xs text-base-content/50 block mb-1">
                  Presupuesto · mes {if(@group_budget.has_unlimited?,
                    do: gettext("· some member without a budget"),
                    else: ""
                  )}
                </span>
                <Stats.budget_bar
                  spend={@group_budget.monthly_spend_usd}
                  limit={@group_budget.monthly_limit_usd}
                  pct={@group_budget.monthly_pct}
                />
              </div>
            <% end %>
          </div>

          <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
            <.kpi_card
              id="group-kpi-cost"
              label="Costo"
              icon="hero-currency-dollar"
              accent="accent"
            >
              ${Stats.format_decimal(@metrics.cost_usd)}
            </.kpi_card>

            <.kpi_card
              id="group-kpi-requests"
              label="Requests"
              icon="hero-arrow-trending-up"
              accent="primary"
            >
              {Stats.format_number(@metrics.requests_total)}
            </.kpi_card>

            <.kpi_card
              id="group-kpi-tokens"
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
                <span class="text-base-content/30">/</span>
                {format_cache_value(@metrics.cache_read_tokens, @metrics.cache_creation_tokens)}
                <span class="text-sm text-base-content/50">cache</span>
              </span>
              <:sub>
                {format_hit_rate(cache_hit_rate(@metrics.cache_read_tokens, @metrics.prompt_tokens))} hit
              </:sub>
            </.kpi_card>

            <.kpi_card id="group-kpi-tps" label="TPS" icon="hero-bolt" accent="accent">
              {Stats.format_tps(@metrics.avg_tps)}
            </.kpi_card>
          </div>

          <%!-- Daily usage sparkline: models over time --%>
          <%= if @drilldown_series != [] do %>
            <% pivoted = Stats.pivot_daily_series(@drilldown_series) %>
            <% spark_max = Stats.daily_series_max(pivoted) %>
            <% labels = @drilldown_series_labels %>

            <div class="card bg-base-100 border border-base-300 shadow-sm">
              <div class="card-body p-4 gap-2">
                <div class="flex items-center justify-between">
                  <h2 class="card-title text-base">
                    <.icon name="hero-chart-bar" class="w-5 h-5 text-base-content/60" />
                    {gettext("Daily usage per model")}
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
                      {gettext("Models")}
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
                <.icon name="hero-rectangle-stack" class="w-5 h-5 text-base-content/60" />
                {gettext("Models used")}
              </h2>
              <%= if Stats.has_data?(@breakdown_model) do %>
                <% model_total = Stats.breakdown_total(@breakdown_model) %>
                <% model_rows =
                  Stats.shown_rows(
                    @breakdown_model,
                    "group-detail-models",
                    @shown_counts,
                    @per_page
                  ) %>
                <div class="overflow-x-auto mt-3">
                  <table class="table table-sm" id="group-models">
                    <thead>
                      <tr>
                        <th>
                          <button
                            phx-click="sort"
                            phx-value-field="model_name"
                            class="flex items-center gap-1 hover:text-primary"
                          >
                            {gettext("Model")}
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
                            {gettext("Requests")}
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
                            {gettext("Cost")}
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
                            {gettext("Tokens in")}
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
                            {gettext("Tokens out")}
                            <.sort_icon
                              field={:completion_tokens}
                              current={@sort_field}
                              direction={@sort_direction}
                            />
                          </button>
                        </th>
                        <th
                          class="text-right"
                          title={gettext("Percentage of prompt tokens with cache hit")}
                        >
                          {gettext("Cache %")}
                        </th>
                        <th class="text-right">
                          <button
                            phx-click="sort"
                            phx-value-field="avg_tps"
                            class="flex items-center justify-end gap-1 w-full hover:text-primary"
                          >
                            {gettext("TPS")}
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
                        :for={row <- model_rows}
                        id={"bd-group-model-#{row.model_id || "unknown"}"}
                      >
                        <td class="font-medium">
                          <%= if row.model_id do %>
                            <.link
                              patch={~p"/stats/models?period=#{@period}&model_id=#{row.model_id}"}
                              class="link link-hover"
                            >{row.model_name}</.link>
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
                        <td>Total · {length(@breakdown_model)} modelos</td>
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
                            model_total.cache_read_tokens
                          )}
                        </td>
                        <td></td>
                      </tr>
                    </tfoot>
                  </table>
                </div>
                <Stats.show_more
                  key="group-detail-models"
                  id="group-detail-models-more"
                  top={length(model_rows)}
                  total={length(@breakdown_model)}
                />
              <% else %>
                <p class="text-sm text-base-content/40 py-6 text-center">
                  {gettext("No data for this period.")}
                </p>
              <% end %>
            </div>
          </div>
          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-base">
                <.icon name="hero-user" class="w-5 h-5 text-base-content/60" />
                {gettext("Limit profile members")}
              </h2>
              <%= if Stats.has_data?(@breakdown_member) do %>
                <% member_total = Stats.breakdown_total(@breakdown_member) %>
                <% member_rows =
                  Stats.shown_rows(
                    @breakdown_member,
                    "group-detail-members",
                    @shown_counts,
                    @per_page
                  ) %>
                <div class="overflow-x-auto mt-3">
                  <table class="table table-sm" id="group-members">
                    <thead>
                      <tr>
                        <th>
                          <button
                            phx-click="sort"
                            phx-value-field="user_email"
                            class="flex items-center gap-1 hover:text-primary"
                          >
                            {gettext("User")}
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
                            {gettext("Requests")}
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
                            {gettext("Cost")}
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
                            {gettext("Tokens in")}
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
                            {gettext("Tokens out")}
                            <.sort_icon
                              field={:completion_tokens}
                              current={@sort_field}
                              direction={@sort_direction}
                            />
                          </button>
                        </th>
                        <th
                          class="text-right"
                          title={gettext("Percentage of prompt tokens with cache hit")}
                        >
                          {gettext("Cache %")}
                        </th>
                        <th class="text-right">
                          <button
                            phx-click="sort"
                            phx-value-field="avg_tps"
                            class="flex items-center justify-end gap-1 w-full hover:text-primary"
                          >
                            {gettext("TPS")}
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
                        id={"bd-group-member-#{row.group_member_id}"}
                      >
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
                        <td>Total · {Stats.distinct_users(@breakdown_member)} usuarios</td>
                        <td class="text-right font-mono">
                          {Stats.format_number(member_total.request_count)}
                        </td>
                        <td class="text-right font-mono">
                          ${Stats.format_decimal(member_total.cost_usd)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.format_number(member_total.prompt_tokens)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.format_number(member_total.completion_tokens)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.cache_hit_pct(
                            member_total.prompt_tokens,
                            member_total.cache_read_tokens
                          )}
                        </td>
                        <td></td>
                      </tr>
                    </tfoot>
                  </table>
                </div>
                <Stats.show_more
                  key="group-detail-members"
                  id="group-detail-members-more"
                  top={length(member_rows)}
                  total={length(@breakdown_member)}
                />
              <% else %>
                <p class="text-sm text-base-content/40 py-6 text-center">
                  {gettext("No data for this period.")}
                </p>
              <% end %>
            </div>
          </div>
          <button
            phx-click="clear_group_filter"
            class="btn btn-sm btn-ghost"
            id="clear-group-filter"
          >
            <.icon name="hero-x-mark" class="w-4 h-4" /> Quitar filtro de perfil de límites
          </button>
        </div>
      <% else %>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">
              <.icon name="hero-user-group" class="w-5 h-5 text-base-content/60" />
              {gettext("Limit profiles")}
            </h2>
            <p class="text-xs text-base-content/60">
              Una fila por perfil de límites con su información básica en el período
              ({Stats.period_label(@period)}). El nombre abre el detalle: sus métricas,
              sus miembros y los modelos que consume.
            </p>
            <%= if Stats.has_data?(@breakdown_group) do %>
              <% group_total = Stats.breakdown_total(@breakdown_group) %>
              <%!-- El buscador filtra las filas en el render: no toca la DB ni las
                   claves del DashboardCache. --%>
              <% rows = Enum.filter(@breakdown_group, &Stats.matches?(@list_search, &1.group_name)) %>
              <% list_rows = Stats.shown_rows(rows, "group-list", @shown_counts, @per_page) %>
              <div class="mt-3">
                <Stats.list_search
                  id="group-list-search"
                  value={@list_search}
                  placeholder={gettext("Filter by limit profile…")}
                />
              </div>
              <%= if rows == [] do %>
                <p class="text-sm text-base-content/40 py-6 text-center" id="group-list-empty">
                  {gettext("No matches.")}
                </p>
              <% else %>
                <div class="overflow-x-auto mt-3">
                  <table class="table table-sm" id="group-table">
                    <thead>
                      <tr>
                        <th>
                          <button
                            phx-click="sort"
                            phx-value-field="group_name"
                            class="flex items-center gap-1 hover:text-primary"
                          >
                            {gettext("Limit profile")}
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
                            {gettext("Requests")}
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
                            {gettext("Cost")}
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
                            {gettext("Tokens in")}
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
                            {gettext("Tokens out")}
                            <.sort_icon
                              field={:completion_tokens}
                              current={@sort_field}
                              direction={@sort_direction}
                            />
                          </button>
                        </th>
                        <th
                          class="text-right"
                          title={gettext("Percentage of prompt tokens with cache hit")}
                        >
                          {gettext("Cache %")}
                        </th>
                        <th class="text-right">
                          <button
                            phx-click="sort"
                            phx-value-field="avg_tps"
                            class="flex items-center justify-end gap-1 w-full hover:text-primary"
                          >
                            {gettext("TPS")}
                            <.sort_icon
                              field={:avg_tps}
                              current={@sort_field}
                              direction={@sort_direction}
                            />
                          </button>
                        </th>
                        <th title={
                          gettext("Calendar-month spend vs the aggregate cap of its members")
                        }>
                          Presupuesto · mes
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={row <- list_rows} id={"bd-group-#{row.group_id}"}>
                        <td class="font-medium">
                          <.link
                            patch={~p"/stats/profiles/#{row.group_id}?period=#{@period}"}
                            class="link link-hover"
                          >{row.group_name}</.link>
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
                        <td class="min-w-[150px]">
                          <%= if budget = group_budget_for(@group_budgets, row.group_id) do %>
                            <div class="flex items-center gap-2">
                              <Stats.budget_bar
                                compact
                                spend={budget.monthly_spend_usd}
                                limit={budget.monthly_limit_usd}
                                pct={budget.monthly_pct}
                              />
                              <Stats.budget_badge pct={budget.monthly_pct} />
                            </div>
                          <% else %>
                            <span class="text-base-content/30">—</span>
                          <% end %>
                        </td>
                      </tr>
                    </tbody>
                    <tfoot>
                      <tr class="font-bold bg-base-200">
                        <td>Total · {length(rows)} perfiles de límites</td>
                        <td class="text-right font-mono">
                          {Stats.format_number(group_total.request_count)}
                        </td>
                        <td class="text-right font-mono">
                          ${Stats.format_decimal(group_total.cost_usd)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.format_number(group_total.prompt_tokens)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.format_number(group_total.completion_tokens)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.cache_hit_pct(
                            group_total.prompt_tokens,
                            group_total.cache_read_tokens
                          )}
                        </td>
                        <td></td>
                        <td></td>
                      </tr>
                    </tfoot>
                  </table>
                </div>
              <% end %>
              <Stats.show_more
                key="group-list"
                id="group-list-more"
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
      <% end %>
    </div>
    """
  end

  defp group_budget_for(rows, group_id) do
    Enum.find(rows, fn row -> row.group.id == group_id end)
  end
end
