defmodule TokengateWeb.StatsLive.Group do
  @moduledoc """
  Detalle de un perfil de límites (`/stats/profiles/:group_id`, action `:group`).

  Es el "interior" del listado de perfiles de límites: las métricas del perfil
  en el período, su presupuesto mensual, la tendencia diaria por modelo, los
  modelos que consume y sus miembros. Todo respeta el período elegido en el
  selector del hub.

  Gemelo de `TokengateWeb.StatsLive.Model`, `TokengateWeb.StatsLive.Provider`
  y `TokengateWeb.StatsLive.Agent`.
  """
  use TokengateWeb, :html

  import TokengateWeb.KpiHelpers,
    only: [
      kpi_card: 1,
      cache_hit_rate: 2,
      format_hit_rate: 1
    ]

  alias TokengateWeb.StatsHelpers, as: Stats
  alias TokengateWeb.StatsLive.DailyStackedChart

  attr :group, :any, required: true
  attr :group_budget, :any, default: nil
  attr :metrics, :any, required: true
  attr :breakdown_member, :any, required: true
  attr :breakdown_model, :any, required: true
  attr :drilldown_series, :any, required: true
  attr :drilldown_series_labels, :any, required: true
  attr :chart_metric, :string, default: "requests"
  attr :period, :any, required: true
  attr :sort_field, :any, required: true
  attr :sort_direction, :any, required: true
  attr :per_page, :integer, default: 10
  attr :shown_counts, :map, required: true
  attr :stats_loading, :boolean, default: false

  def group(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between flex-wrap gap-3">
        <.link
          patch={~p"/stats/profiles?period=#{@period}"}
          class="btn btn-sm btn-ghost"
          id="group-back"
        >
          <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Limit profiles")}
        </.link>
        <div class="flex items-center gap-2">
          <.link
            :if={@group}
            href={"/stats/export?type=groups&period=#{@period}&group_id=#{@group.id}"}
            class="btn btn-sm btn-ghost"
            id="csv-groups"
          >
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> CSV
          </.link>
          <span class="text-xs text-base-content/60" id="group-metrics-period">
            {gettext("Period: %{period}", period: Stats.period_label(@period))}
          </span>
        </div>
      </div>

      <%= if @group == nil and not @stats_loading do %>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <p class="text-sm text-base-content/40 py-6 text-center" id="group-not-found">
              {gettext("Limit profile not found.")}
            </p>
          </div>
        </div>
      <% end %>

      <%!-- El encabezado se pinta siempre; el nombre es null-safe porque el
           render estático (pre-async) todavía no trae :group. --%>
      <div class="flex items-center justify-between flex-wrap gap-3" id="group-detail-header">
        <div class="flex items-center gap-3 flex-wrap">
          <h2 class="text-lg font-semibold flex items-center gap-2">
            <.icon name="hero-user-group" class="w-5 h-5 text-base-content/60" />
            {if @group, do: @group.name, else: "…"}
          </h2>
          <span
            :if={@group && @metrics.requests_total == 0 && not @stats_loading}
            class="text-xs text-base-content/50"
          >
            {gettext("no traffic in the period")}
          </span>
        </div>

        <%= if @group && @group_budget do %>
          <div class="w-full max-w-xs" id="group-budget-bar">
            <span class="text-xs text-base-content/50 block mb-1">
              {gettext("Budget · month")} {if(@group_budget.has_unlimited?,
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

      <%= if @group do %>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <.kpi_card
            id="group-kpi-requests"
            label="Requests"
            icon="hero-arrow-trending-up"
            accent="primary"
          >
            {Stats.format_number(@metrics.requests_total)}
          </.kpi_card>

          <.kpi_card
            id="group-kpi-cost"
            label={gettext("Cost")}
            icon="hero-currency-dollar"
            accent="accent"
          >
            ${Stats.format_decimal(@metrics.cost_usd)}
            <:sub>
              <span :if={@metrics.requests_total > 0} class="tabular-nums">
                {Stats.cost_per_request(@metrics.cost_usd, @metrics.requests_total)}/req · {Stats.effective_cost_per_1m(
                  @metrics.cost_usd,
                  @metrics.prompt_tokens,
                  @metrics.completion_tokens
                )}/1M
              </span>
            </:sub>
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
            <span class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
              {Stats.format_compact(@metrics.prompt_tokens)}
              <span class="text-sm text-base-content/50">in</span>
              <span class="text-base-content/30">/</span>
              {Stats.format_compact(@metrics.completion_tokens)}
              <span class="text-sm text-base-content/50">out</span>
            </span>
            <:sub>
              cache · {format_hit_rate(
                cache_hit_rate(@metrics.cache_read_tokens, @metrics.prompt_tokens)
              )} hit · out/in {Stats.out_in_ratio(
                @metrics.completion_tokens,
                @metrics.prompt_tokens
              )}
            </:sub>
          </.kpi_card>

          <.kpi_card id="group-kpi-tps" label="TPS" icon="hero-bolt" accent="accent">
            {Stats.format_tps(@metrics.avg_tps)}
          </.kpi_card>
        </div>

        <%!-- Daily usage sparkline: models over time --%>
        <DailyStackedChart.daily_stacked_chart
          id="group-daily-chart"
          title={gettext("Daily usage per model")}
          period={@period}
          series={@drilldown_series}
          labels={@drilldown_series_labels}
          metric={@chart_metric}
          toggle_event="set_chart_metric"
        />

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
              <div class="mt-3 overflow-x-auto">
                <.table
                  id="group-models"
                  rows={model_rows}
                  row_id={fn row -> "bd-group-model-#{row.model_id || "unknown"}" end}
                  sort_field={@sort_field}
                  sort_direction={@sort_direction}
                  sort_event="sort"
                >
                  <:col :let={row} label={gettext("Model")} field={:model_name}>
                    <%= if row.model_id do %>
                      <.link
                        patch={~p"/stats/models/#{row.model_id}?period=#{@period}"}
                        class="link link-hover font-medium"
                      >{row.model_name}</.link>
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
                  <:col :let={row} label={gettext("Cost / req")} align="right">
                    <span class="font-mono tabular-nums text-base-content/70">
                      {Stats.cost_per_request(row.cost_usd, row.request_count)}
                    </span>
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
                  <:col :let={row} label={gettext("Errors")} field={:error_count} align="right">
                    <% errs = Map.get(row, :error_count, 0) %>
                    <span class={["font-mono tabular-nums", errs > 0 && "text-warning"]}>
                      {Stats.format_number(errs)}
                    </span>
                  </:col>
                  <:col :let={row} label={gettext("TPS")} field={:avg_tps} align="right">
                    <span class="font-mono tabular-nums">{Stats.format_tps(row.avg_tps)}</span>
                  </:col>
                </.table>
              </div>
              <div
                id="group-models-totals"
                class="mt-3 flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1 text-xs"
              >
                <span class="font-semibold text-base-content/70">
                  {gettext("Total · %{count} models", count: length(@breakdown_model))}
                </span>
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
                      {Stats.cache_hit_pct(model_total.prompt_tokens, model_total.cache_read_tokens)}
                    </span>
                  </span>
                </div>
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
              <div class="mt-3 overflow-x-auto">
                <.table
                  id="group-members"
                  rows={member_rows}
                  row_id={fn row -> "bd-group-member-#{row.group_member_id}" end}
                  sort_field={@sort_field}
                  sort_direction={@sort_direction}
                  sort_event="sort"
                >
                  <:col :let={row} label={gettext("User")} field={:user_email}>
                    <.link
                      navigate={~p"/stats/users/#{row.user_id}"}
                      class="link link-hover font-mono text-sm"
                    >
                      {row.user_email}
                    </.link>
                  </:col>
                  <:col :let={row} label={gettext("Requests")} field={:request_count} align="right">
                    <span class="font-mono tabular-nums">{Stats.format_number(row.request_count)}</span>
                  </:col>
                  <:col :let={row} label={gettext("Cost")} field={:cost_usd} align="right">
                    <span class="font-mono tabular-nums">${Stats.format_decimal(row.cost_usd)}</span>
                  </:col>
                  <:col :let={row} label={gettext("Share")} align="right">
                    <span class="font-mono tabular-nums text-base-content/70">
                      {Stats.cost_share_pct(row.cost_usd, member_total.cost_usd)}%
                    </span>
                  </:col>
                  <:col :let={row} label={gettext("Cost / req")} align="right">
                    <span class="font-mono tabular-nums text-base-content/70">
                      {Stats.cost_per_request(row.cost_usd, row.request_count)}
                    </span>
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
                </.table>
              </div>
              <div
                id="group-members-totals"
                class="mt-3 flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1 text-xs"
              >
                <span class="font-semibold text-base-content/70">
                  {gettext("Total · %{count} users", count: Stats.distinct_users(@breakdown_member))}
                </span>
                <div class="flex flex-wrap items-baseline gap-x-5 gap-y-1 font-mono tabular-nums text-base-content/80">
                  <span>
                    <span class="text-base-content/40">{gettext("Requests")}</span>
                    <span class="ml-1">{Stats.format_number(member_total.request_count)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Cost")}</span>
                    <span class="ml-1">${Stats.format_decimal(member_total.cost_usd)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Tokens in")}</span>
                    <span class="ml-1">{Stats.format_number(member_total.prompt_tokens)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Tokens out")}</span>
                    <span class="ml-1">{Stats.format_number(member_total.completion_tokens)}</span>
                  </span>
                  <span>
                    <span class="text-base-content/40">{gettext("Cache %")}</span>
                    <span class="ml-1">
                      {Stats.cache_hit_pct(
                        member_total.prompt_tokens,
                        member_total.cache_read_tokens
                      )}
                    </span>
                  </span>
                </div>
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
      <% end %>
    </div>
    """
  end
end
