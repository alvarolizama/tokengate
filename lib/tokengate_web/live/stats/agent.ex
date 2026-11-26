defmodule TokengateWeb.StatsLive.Agent do
  @moduledoc """
  Detalle de un agente de código (`/stats/agents/:agent_key`, action `:agent`).

  Muestra qué modelos usa ese agente, quién lo está ejecutando (usuarios y
  servicios), su distribución por `effort_applied` / `think`, y la tendencia
  diaria en el período seleccionado.
  """
  use TokengateWeb, :html

  import TokengateWeb.KpiHelpers, only: [kpi_card: 1]
  alias TokengateWeb.StatsHelpers, as: Stats
  alias TokengateWeb.StatsLive.DailyStackedChart

  attr :agent_key, :any, required: true
  attr :agent_detail, :any, required: true
  attr :period, :any, required: true
  attr :chart_metric, :string, default: "requests"
  attr :per_page, :integer, default: 10
  attr :shown_counts, :map, required: true
  attr :stats_loading, :boolean, default: false

  def agent(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between flex-wrap gap-3">
        <.link
          patch={~p"/stats/agents?period=#{@period}"}
          class="btn btn-sm btn-ghost"
          id="agent-back"
        >
          <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Agents")}
        </.link>
        <span class="text-xs text-base-content/60" id="agent-metrics-period">
          {gettext("Period: %{period}", period: Stats.period_label(@period))}
        </span>
      </div>

      <%= if @agent_detail == nil and not @stats_loading do %>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <p class="text-sm text-base-content/40 py-6 text-center" id="agent-not-found">
              {gettext("No traffic for this agent in the selected period.")}
            </p>
          </div>
        </div>
      <% end %>

      <%= if @agent_detail do %>
        <% ident = @agent_detail.identity %>
        <% sum = @agent_detail.summary %>
        <% series_labels =
          @agent_detail.daily_series |> Enum.map(& &1.label) |> Enum.uniq() |> Enum.sort() %>

        <div class="flex items-center gap-3 flex-wrap" id="agent-detail-header">
          <img :if={ident.logo} src={ident.logo} alt="" class="w-6 h-6 object-contain shrink-0" />
          <.icon :if={!ident.logo} name={ident.icon} class="w-6 h-6 text-base-content/70 shrink-0" />
          <h2 class="text-lg font-semibold">{ident.label}</h2>
          <span class="badge badge-sm badge-ghost uppercase">{ident.family}</span>
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <.kpi_card
            id="agent-kpi-cost"
            label={gettext("Cost")}
            icon="hero-currency-dollar"
            accent="accent"
          >
            ${Stats.format_decimal(sum.cost_usd)}
            <:sub>
              {Stats.cost_per_request(sum.cost_usd, sum.request_count)}/req · {Stats.effective_cost_per_1m(
                sum.cost_usd,
                sum.prompt_tokens,
                sum.completion_tokens
              )}/1M
            </:sub>
          </.kpi_card>

          <.kpi_card
            id="agent-kpi-requests"
            label="Requests"
            icon="hero-arrow-trending-up"
            accent="primary"
          >
            {Stats.format_number(sum.request_count)}
            <:sub>
              {gettext("%{errors} errors (%{pct})",
                errors: Stats.format_number(sum.error_count),
                pct: Stats.format_percent(sum.error_rate)
              )}
            </:sub>
          </.kpi_card>

          <.kpi_card
            id="agent-kpi-tokens"
            label="Tokens"
            icon="hero-cpu-chip"
            accent="primary"
            title={"#{Stats.format_number(sum.prompt_tokens)} in / #{Stats.format_number(sum.completion_tokens)} out"}
          >
            <span class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
              {Stats.format_compact(sum.prompt_tokens)}
              <span class="text-sm text-base-content/50">in</span>
              <span class="text-base-content/30">/</span>
              {Stats.format_compact(sum.completion_tokens)}
              <span class="text-sm text-base-content/50">out</span>
            </span>
            <:sub>
              cache · {Stats.cache_hit_pct(sum.prompt_tokens, sum.cache_read_tokens)} hit · out/in {Stats.out_in_ratio(
                sum.completion_tokens,
                sum.prompt_tokens
              )}
            </:sub>
          </.kpi_card>

          <.kpi_card
            id="agent-kpi-latency"
            label={gettext("Latency")}
            icon="hero-clock"
            accent="warning"
          >
            {Stats.format_ms(sum.avg_latency_ms)}
            <:sub>TPS: {Stats.format_tps(sum.avg_tps)}</:sub>
          </.kpi_card>
        </div>

        <DailyStackedChart.daily_stacked_chart
          id="agent-daily-chart"
          title={gettext("Daily usage per model")}
          period={@period}
          series={@agent_detail.daily_series}
          labels={series_labels}
          metric={@chart_metric}
          toggle_event="set_chart_metric"
        />

        <%!-- Effort / thinking breakdown --%>
        <div
          :if={@agent_detail.effort_breakdown != []}
          class="card bg-base-100 border border-base-300 shadow-sm"
          id="agent-effort-breakdown"
        >
          <div class="card-body">
            <h3 class="card-title text-base">
              <.icon name="hero-sparkles" class="w-5 h-5 text-base-content/60" />
              {gettext("Reasoning & effort distribution")}
            </h3>
            <div class="mt-2 overflow-x-auto">
              <.table
                id="agent-effort-table"
                rows={@agent_detail.effort_breakdown}
                row_id={fn row -> "agent-effort-#{row.effort}" end}
              >
                <:col :let={row} label={gettext("Effort")}>
                  <span class="badge badge-sm badge-ghost font-mono">{row.effort}</span>
                </:col>
                <:col :let={row} label={gettext("Requests")} align="right">
                  <span class="font-mono tabular-nums">{Stats.format_number(row.request_count)}</span>
                </:col>
                <:col :let={row} label={gettext("Tokens out")} align="right">
                  <span class="font-mono tabular-nums">
                    {Stats.format_number(row.completion_tokens)}
                  </span>
                </:col>
                <:col :let={row} label={gettext("Cost")} align="right">
                  <span class="font-mono tabular-nums">${Stats.format_decimal(row.cost_usd)}</span>
                </:col>
                <:col :let={row} label={gettext("Share")} align="right">
                  <span class="font-mono tabular-nums">
                    {Stats.cost_share_pct(row.cost_usd, sum.cost_usd)}%
                  </span>
                </:col>
              </.table>
            </div>
          </div>
        </div>

        <%!-- Models used by this agent --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <h3 class="card-title text-base">
              <.icon name="hero-rectangle-stack" class="w-5 h-5 text-base-content/60" />
              {gettext("Models used")}
            </h3>
            <%= if @agent_detail.models != [] do %>
              <% model_rows =
                Stats.shown_rows(@agent_detail.models, "agent-models", @shown_counts, @per_page) %>
              <div class="mt-3 overflow-x-auto">
                <.table
                  id="agent-models"
                  rows={model_rows}
                  row_id={fn row -> "agent-model-#{row.model_id || "unknown"}" end}
                >
                  <:col :let={row} label={gettext("Model")}>
                    <%= if row.model_id do %>
                      <.link
                        patch={~p"/stats/models/#{row.model_id}?period=#{@period}"}
                        class="link link-hover font-medium"
                      >
                        {row.model_name}
                      </.link>
                    <% else %>
                      <span class="font-medium">{row.model_name}</span>
                    <% end %>
                  </:col>
                  <:col :let={row} label={gettext("Requests")} align="right">
                    <span class="font-mono tabular-nums">{Stats.format_number(row.request_count)}</span>
                  </:col>
                  <:col :let={row} label={gettext("Cost")} align="right">
                    <span class="font-mono tabular-nums">${Stats.format_decimal(row.cost_usd)}</span>
                  </:col>
                  <:col :let={row} label={gettext("Share")} align="right">
                    <span class="font-mono tabular-nums">
                      {Stats.cost_share_pct(row.cost_usd, sum.cost_usd)}%
                    </span>
                  </:col>
                  <:col :let={row} label={gettext("Cost / req")} align="right">
                    <span class="font-mono tabular-nums">
                      {Stats.cost_per_request(row.cost_usd, row.request_count)}
                    </span>
                  </:col>
                  <:col :let={row} label={gettext("Cache %")} align="right">
                    <span class="font-mono tabular-nums">
                      {Stats.cache_hit_pct(row.prompt_tokens, row.cache_read_tokens)}
                    </span>
                  </:col>
                </.table>
              </div>
              <Stats.show_more
                key="agent-models"
                id="agent-models-more"
                top={length(model_rows)}
                total={length(@agent_detail.models)}
              />
            <% else %>
              <p class="text-sm text-base-content/40 py-6 text-center">
                {gettext("No data for this period.")}
              </p>
            <% end %>
          </div>
        </div>

        <%!-- Consumers running this agent --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <h3 class="card-title text-base">
              <.icon name="hero-users" class="w-5 h-5 text-base-content/60" />
              {gettext("Users and services")}
            </h3>
            <%= if @agent_detail.consumers != [] do %>
              <% consumer_rows =
                Stats.shown_rows(
                  @agent_detail.consumers,
                  "agent-consumers",
                  @shown_counts,
                  @per_page
                ) %>
              <div class="mt-3 overflow-x-auto">
                <.table
                  id="agent-consumers"
                  rows={consumer_rows}
                  row_id={
                    fn row -> "agent-consumer-#{row.subject_type}-#{row.subject_id || "none"}" end
                  }
                >
                  <:col :let={row} label={gettext("Consumer")}>
                    <%= cond do %>
                      <% row.subject_type == "user" and row.subject_id -> %>
                        <.link
                          navigate={~p"/stats/users/#{row.subject_id}"}
                          class="link link-hover font-medium"
                        >
                          {row.label}
                        </.link>
                        <div
                          :if={row.sublabel && row.sublabel != row.label}
                          class="text-xs text-base-content/50"
                        >
                          {row.sublabel}
                        </div>
                      <% row.subject_type == "service" and row.subject_id -> %>
                        <.link
                          navigate={~p"/stats/services/#{row.subject_id}"}
                          class="link link-hover font-medium"
                        >
                          {row.label}
                        </.link>
                        <span class="ml-1.5 badge badge-xs badge-ghost">{gettext("Service")}</span>
                      <% true -> %>
                        <span>{row.label}</span>
                    <% end %>
                  </:col>
                  <:col :let={row} label={gettext("Requests")} align="right">
                    <span class="font-mono tabular-nums">{Stats.format_number(row.request_count)}</span>
                  </:col>
                  <:col :let={row} label={gettext("Cost")} align="right">
                    <span class="font-mono tabular-nums">${Stats.format_decimal(row.cost_usd)}</span>
                  </:col>
                  <:col :let={row} label={gettext("Share")} align="right">
                    <span class="font-mono tabular-nums">
                      {Stats.cost_share_pct(row.cost_usd, sum.cost_usd)}%
                    </span>
                  </:col>
                  <:col :let={row} label={gettext("Cache %")} align="right">
                    <span class="font-mono tabular-nums">
                      {Stats.cache_hit_pct(row.prompt_tokens, row.cache_read_tokens)}
                    </span>
                  </:col>
                </.table>
              </div>
              <Stats.show_more
                key="agent-consumers"
                id="agent-consumers-more"
                top={length(consumer_rows)}
                total={length(@agent_detail.consumers)}
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
