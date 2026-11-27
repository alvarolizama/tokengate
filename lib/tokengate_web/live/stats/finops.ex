defmodule TokengateWeb.StatsLive.Finops do
  @moduledoc """
  Pestaña FinOps (`/stats/finops`): la economía del gasto del período.

  Compara Usuarios contra Servicios (cuánto ponen y cuánto consumen), enseña
  a dónde fue cada dólar (útil, impuesto de pensamiento, desperdicio por
  error, overhead del router), qué capacidad lo consumió y quién lo gastó.

  Todas las cifras salen de los agregados de `Tokengate.Metrics.Rollup`
  cargados por `TokengateWeb.StatsLive`:

    * `finops_overview`       — `Rollup.finops_overview/1`
    * `finops_series`         — `Rollup.finops_subject_series/1`
    * `finops_request_types`  — `Rollup.finops_request_type_breakdown/1`
    * `finops_scatter`        — `Rollup.finops_subject_scatter/1`

  Las gráficas viven en `TokengateWeb.StatsLive.FinopsCharts`.
  """

  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats
  alias TokengateWeb.StatsLive.FinopsCharts

  attr :overview, :any, default: nil
  attr :series, :list, default: []
  attr :request_types, :list, default: []
  attr :scatter, :list, default: []
  attr :metric, :string, default: "cost"
  attr :scatter_y, :string, default: "cpr"
  attr :period, :any, required: true

  def finops(assigns) do
    overview = assigns.overview || empty_overview()
    overall = overview.overall
    users = overview.users
    services = overview.services

    total_cost = overall.cost_usd
    total_requests = overall.requests

    users_cost_share = Stats.cost_share_pct(users.cost_usd, total_cost)
    services_cost_share = Stats.cost_share_pct(services.cost_usd, total_cost)
    users_req_share = Stats.share_pct(users.requests, total_requests)
    services_req_share = Stats.share_pct(services.requests, total_requests)

    top_users =
      assigns.scatter
      |> Enum.filter(&(&1.subject_type == "user"))
      |> Enum.take(5)

    top_services =
      assigns.scatter
      |> Enum.filter(&(&1.subject_type == "service"))
      |> Enum.take(5)

    hourly? = assigns.period in ["today", "yesterday"]

    assigns =
      assigns
      |> assign(:overall, overall)
      |> assign(:users, users)
      |> assign(:services, services)
      |> assign(:total_cost, total_cost)
      |> assign(:total_requests, total_requests)
      |> assign(:users_cost_share, users_cost_share)
      |> assign(:services_cost_share, services_cost_share)
      |> assign(:users_req_share, users_req_share)
      |> assign(:services_req_share, services_req_share)
      |> assign(:top_users, top_users)
      |> assign(:top_services, top_services)
      |> assign(:hourly?, hourly?)

    ~H"""
    <div id="finops-stats" class="space-y-6">
      <div class="flex items-center justify-between flex-wrap gap-2">
        <div>
          <h2 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide">
            {gettext("FinOps")}
          </h2>
          <p class="text-xs text-base-content/50">
            {gettext("Where the spend goes, who generates it and what it buys · %{period}",
              period: Stats.period_label(@period)
            )}
          </p>
        </div>
        <a
          href={"/stats/export?type=finops&period=#{@period}"}
          id="csv-finops"
          class="btn btn-xs btn-ghost"
          download
        >
          <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> {gettext("CSV")}
        </a>
      </div>

      <%!-- Proporción Usuarios vs Servicios: quién paga el período --%>
      <div
        class="card bg-base-100 border border-base-300 shadow-sm"
        id="finops-proportion"
      >
        <div class="card-body p-4 gap-3">
          <div class="flex items-center justify-between flex-wrap gap-2">
            <h2 class="card-title text-base">
              <.icon name="hero-scale" class="w-5 h-5 text-base-content/60" />
              {gettext("Users vs services")}
            </h2>
            <span class="text-xs text-base-content/50 tabular-nums">
              {Stats.money(@total_cost)} · {Stats.format_number(@total_requests)} req
            </span>
          </div>

          <div class="space-y-2">
            <div>
              <div class="flex items-center justify-between text-[11px] text-base-content/60">
                <span>{gettext("Share of spend")}</span>
                <span class="tabular-nums">
                  {gettext("Users %{users}% · Services %{services}%",
                    users: @users_cost_share,
                    services: @services_cost_share
                  )}
                </span>
              </div>
              <div
                class="flex h-2.5 w-full overflow-hidden rounded-full bg-base-300/30 mt-1"
                id="finops-proportion-spend"
              >
                <div class="h-full bg-primary" style={"width: #{@users_cost_share}%"} />
                <div class="h-full bg-warning" style={"width: #{@services_cost_share}%"} />
              </div>
            </div>

            <div>
              <div class="flex items-center justify-between text-[11px] text-base-content/60">
                <span>{gettext("Share of requests")}</span>
                <span class="tabular-nums">
                  {gettext("Users %{users}% · Services %{services}%",
                    users: @users_req_share,
                    services: @services_req_share
                  )}
                </span>
              </div>
              <div
                class="flex h-2.5 w-full overflow-hidden rounded-full bg-base-300/30 mt-1"
                id="finops-proportion-requests"
              >
                <div class="h-full bg-primary" style={"width: #{@users_req_share}%"} />
                <div class="h-full bg-warning" style={"width: #{@services_req_share}%"} />
              </div>
            </div>
          </div>

          <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-[10px] text-base-content/50">
            <span class="flex items-center gap-1.5">
              <span class="w-2 h-2 rounded-sm bg-primary" /> {gettext("Users")}
            </span>
            <span class="flex items-center gap-1.5">
              <span class="w-2 h-2 rounded-sm bg-warning" /> {gettext("Services")}
            </span>
          </div>
        </div>
      </div>

      <%!-- Doble marcador: la misma economía, lado a lado --%>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4" id="finops-scorecards">
        <.scorecard
          id="finops-users-card"
          icon="hero-users"
          label={gettext("Users")}
          block={@users}
          total_cost={@total_cost}
          total_requests={@total_requests}
          per_subject_label={gettext("$/active user")}
        />
        <.scorecard
          id="finops-services-card"
          icon="hero-wrench-screwdriver"
          label={gettext("Services")}
          block={@services}
          total_cost={@total_cost}
          total_requests={@total_requests}
          per_subject_label={gettext("$/active service")}
        />
      </div>

      <FinopsCharts.dual_trend_chart
        id="finops-trend-chart"
        title={gettext("Spend trend")}
        hint={
          if @hourly?,
            do: gettext("hourly buckets · users vs services · the money of the period"),
            else: gettext("daily buckets · users vs services · the money of the period")
        }
        series={@series}
        metric={@metric}
        toggle_event="set_finops_metric"
      />

      <FinopsCharts.spend_anatomy_bar
        id="finops-anatomy"
        overview={@overview}
        title={gettext("Where every dollar went")}
      />

      <FinopsCharts.capability_bars
        id="finops-capabilities"
        rows={@request_types}
        title={gettext("Cost by capability")}
      />

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4" id="finops-efficiency">
        <FinopsCharts.efficiency_scatter
          id="finops-scatter"
          rows={@scatter}
          y_metric={@scatter_y}
          toggle_event="set_finops_scatter_y"
          period={@period}
          title={gettext("Efficiency map")}
        />

        <div class="space-y-4">
          <.top_subjects_table
            id="finops-top-users"
            title={gettext("Top 5 users by cost")}
            subject="user"
            rows={@top_users}
            period={@period}
          />
          <.top_subjects_table
            id="finops-top-services"
            title={gettext("Top 5 services by cost")}
            subject="service"
            rows={@top_services}
            period={@period}
          />
        </div>
      </div>
    </div>
    """
  end

  ## Marcador (usuarios / servicios) ---------------------------------------

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :block, :any, required: true
  attr :total_cost, :any, required: true
  attr :total_requests, :integer, required: true
  attr :per_subject_label, :string, required: true

  defp scorecard(assigns) do
    block = assigns.block

    assigns =
      assigns
      |> assign(:cost_share, Stats.cost_share_pct(block.cost_usd, assigns.total_cost))
      |> assign(:req_share, Stats.share_pct(block.requests, assigns.total_requests))
      |> assign(:per_subject, per_active(block.cost_usd, block.active_subjects))
      |> assign(:avg_in, avg_tokens(block.prompt_tokens, block.requests))
      |> assign(:avg_out, avg_tokens(block.completion_tokens, block.requests))

    ~H"""
    <div id={@id} class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body p-4 gap-3">
        <div class="flex items-center justify-between gap-2">
          <h2 class="card-title text-base">
            <.icon name={@icon} class="w-5 h-5 text-base-content/60" />
            {@label}
          </h2>
          <span class="text-[10px] text-base-content/40">
            {gettext("%{count} active", count: Stats.format_number(@block.active_subjects))}
          </span>
        </div>

        <div class="flex items-baseline gap-2">
          <span class="text-2xl font-bold tabular-nums">{Stats.money(@block.cost_usd)}</span>
          <span class="text-xs text-base-content/50 tabular-nums">
            {gettext("%{share}% of spend", share: @cost_share)}
          </span>
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-1">
          <.score_row label={gettext("Requests")} value={Stats.format_number(@block.requests)} />
          <.score_row
            label={gettext("Share of requests")}
            value={"#{@req_share}%"}
          />
          <.score_row
            label={gettext("$/req")}
            value={Stats.cost_per_request(@block.cost_usd, @block.requests)}
          />
          <.score_row
            label={gettext("$/1M tok")}
            value={
              Stats.effective_cost_per_1m(
                @block.cost_usd,
                @block.prompt_tokens,
                @block.completion_tokens
              )
            }
          />
          <.score_row
            label={gettext("Out/In")}
            value={Stats.out_in_ratio(@block.completion_tokens, @block.prompt_tokens)}
          />
          <.score_row label={gettext("Avg in tokens/req")} value={@avg_in} />
          <.score_row label={gettext("Avg out tokens/req")} value={@avg_out} />
          <.score_row
            label={@per_subject_label}
            value={@per_subject}
          />
          <.score_row
            label={gettext("Cache hit %")}
            value={Stats.cache_hit_pct(@block.prompt_tokens, @block.cache_read_tokens)}
          />
          <.score_row
            label={gettext("Error waste")}
            value={Stats.money(@block.error_cost_usd)}
            class="text-error"
          />
          <.score_row
            label={gettext("Thinking tax")}
            value={Stats.money(@block.think_cost_usd)}
            class="text-accent"
          />
        </div>

        <p class="text-[10px] text-base-content/40 tabular-nums">
          {gettext("%{errors} failed of %{total} requests · %{recovered} recovered",
            errors: Stats.format_number(@block.error_requests),
            total: Stats.format_number(@block.requests),
            recovered: Stats.format_number(@block.fallback_recovered_count)
          )}
        </p>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :class, :string, default: nil

  defp score_row(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-2 text-xs">
      <span class="text-base-content/50 truncate">{@label}</span>
      <span class={["font-medium tabular-nums shrink-0", @class]}>{@value}</span>
    </div>
    """
  end

  ## Top 5 ----------------------------------------------------------------

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subject, :string, required: true
  attr :rows, :list, required: true
  attr :period, :any, required: true

  defp top_subjects_table(assigns) do
    ~H"""
    <div id={@id} class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body p-4 gap-2">
        <h2 class="card-title text-sm">{@title}</h2>

        <p :if={@rows == []} class="text-sm text-base-content/40 py-4 text-center">
          {gettext("No data in this period.")}
        </p>

        <div :if={@rows != []} class="overflow-x-auto">
          <table class="table table-xs" id={"#{@id}-table"}>
            <thead>
              <tr>
                <th>{if @subject == "user", do: gettext("User"), else: gettext("Service")}</th>
                <th class="text-right">{gettext("Cost")}</th>
                <th class="text-right">{gettext("$/req")}</th>
                <th class="text-right">{gettext("Cache %")}</th>
                <th class="text-right">{gettext("Error waste")}</th>
                <th class="text-right">{gettext("Top-ups")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{row, index} <- Enum.with_index(@rows, 1)} id={"#{@id}-row-#{index}"}>
                <td class="max-w-[180px] truncate">
                  <a
                    :if={row.subject_id}
                    href={subject_href(row, @period)}
                    class="link link-hover"
                    title={row.label}
                  >
                    {row.label}
                  </a>
                  <span :if={!row.subject_id}>{row.label}</span>
                </td>
                <td class="text-right tabular-nums">{Stats.money(row.cost_usd)}</td>
                <td class="text-right tabular-nums">
                  {Stats.cost_per_request(row.cost_usd, row.request_count)}
                </td>
                <td class="text-right tabular-nums">
                  {Stats.cache_hit_pct(row.prompt_tokens, row.cache_read_tokens)}
                </td>
                <td class="text-right tabular-nums text-error">
                  {Stats.money(row.error_cost_usd)}
                </td>
                <td class="text-right tabular-nums">{Stats.money(row.topup_cost_usd)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  ## Helpers ---------------------------------------------------------------

  defp per_active(_cost, active) when active in [0, nil], do: "—"

  defp per_active(cost, active) do
    cost |> Decimal.div(Decimal.new(active)) |> Stats.money()
  end

  defp avg_tokens(_tokens, requests) when requests in [0, nil], do: "—"

  defp avg_tokens(tokens, requests) do
    tokens |> div(requests) |> Stats.format_compact()
  end

  defp subject_href(%{subject_type: "user", subject_id: id}, period) when is_binary(id),
    do: "/stats/users/#{id}?period=#{period}"

  defp subject_href(%{subject_type: "service", subject_id: id}, period) when is_binary(id),
    do: "/stats/services/#{id}?period=#{period}"

  defp subject_href(_row, _period), do: "#"

  defp empty_overview do
    zero = zero_block()

    %{
      overall: zero,
      users: Map.put(zero, :active_subjects, 0),
      services: Map.put(zero, :active_subjects, 0)
    }
  end

  defp zero_block do
    %{
      requests: 0,
      cost_usd: Decimal.new(0),
      prompt_tokens: 0,
      completion_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      error_requests: 0,
      error_cost_usd: Decimal.new(0),
      fallback_recovered_count: 0,
      think_requests: 0,
      think_cost_usd: Decimal.new(0),
      local_cache_hits: 0,
      router_decision_cost_usd: Decimal.new(0),
      prompt_tokens_saved_est: 0,
      topup_requests: 0,
      topup_cost_usd: Decimal.new(0)
    }
  end
end
