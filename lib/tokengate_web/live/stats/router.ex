defmodule TokengateWeb.StatsLive.Router do
  @moduledoc """
  Business-decision view of the SmartRouter (`/stats/router`, action `:router`).

  Everything here comes from `Tokengate.SmartRouter.Analytics` over the
  canonical `Tokengate.Periods` window chosen in the hub's period selector:
  the four honest ROI KPIs (served, classifier overhead, baseline and net
  savings — negative values included), the volume-normalized rates, the
  use-case × effort mix, model `tok/s`/TTFT performance, the router-vs-direct
  comparison, the false-savings traffic light, the actionable insights and the
  «who spent on what» matrix with its `no direct access` badge.

  It never recomputes a saving: `net_savings_usd` is whatever the analytics
  module returned, so the page cannot disagree with the API.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  attr :summary, :any, required: true
  attr :use_cases, :any, required: true
  attr :model_perf, :any, required: true
  attr :vs_direct, :any, required: true
  attr :attribution, :any, required: true
  attr :signals, :any, required: true
  attr :insights, :any, required: true
  attr :sources, :any, required: true
  attr :shadow_comparison, :list, default: []
  attr :shadow_migrations, :list, default: []
  attr :shadow_selected_id, :any, default: nil
  attr :period, :any, required: true
  attr :per_page, :integer, default: 10
  attr :shown_counts, :map, required: true
  attr :stats_loading, :boolean, default: false

  def router(assigns) do
    ~H"""
    <div class="space-y-6" id="router-stats">
      <%= if @summary do %>
        <div
          class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-5"
          id="router-kpis"
        >
          <div class="rounded-box border border-base-300 bg-base-100 p-4">
            <p class="text-xs text-base-content/50">{gettext("Routed requests")}</p>
            <p class="text-2xl font-semibold tabular-nums" id="router-kpi-requests">
              {Stats.format_number(@summary.request_count)}
            </p>
            <p class="text-xs text-base-content/50 mt-1">
              {gettext("cache hits %{cache} · errors %{errors}",
                cache: pct(@summary.cache_hit_pct),
                errors: pct(@summary.error_rate_pct)
              )}
            </p>
          </div>

          <div class="rounded-box border border-base-300 bg-base-100 p-4">
            <p class="text-xs text-base-content/50">{gettext("Served cost")}</p>
            <p class="text-2xl font-semibold tabular-nums" id="router-kpi-served">
              {Stats.money(@summary.served_cost_usd)}
            </p>
            <p class="text-xs text-base-content/50 mt-1">
              {gettext("model spend before the decision step")}
            </p>
          </div>

          <div class="rounded-box border border-base-300 bg-base-100 p-4">
            <p class="text-xs text-base-content/50">{gettext("Classifier overhead")}</p>
            <p class="text-2xl font-semibold tabular-nums" id="router-kpi-classifier">
              {Stats.money(@summary.classifier_cost_usd)}
            </p>
            <p class="text-xs text-base-content/50 mt-1">
              {gettext("%{share} of total · p50 %{p50} · p95 %{p95}",
                share: pct(@summary.classifier_cost_share_pct),
                p50: Stats.format_ms(@summary.classifier_p50_ms),
                p95: Stats.format_ms(@summary.classifier_p95_ms)
              )}
            </p>
          </div>

          <div class="rounded-box border border-base-300 bg-base-100 p-4">
            <p class="text-xs text-base-content/50">{gettext("Baseline (counterfactual)")}</p>
            <p class="text-2xl font-semibold tabular-nums" id="router-kpi-baseline">
              {Stats.money(@summary.baseline_cost_usd)}
            </p>
            <p class="text-xs text-base-content/50 mt-1" id="router-kpi-coverage">
              {gettext("coverage %{coverage} (%{count} priced)",
                coverage: pct(@summary.baseline_coverage_pct),
                count: Stats.format_number(@summary.baseline_request_count)
              )}
            </p>
          </div>

          <div class="rounded-box border border-base-300 bg-base-100 p-4">
            <p class="text-xs text-base-content/50">
              {gettext("Net savings (incl. decision cost)")}
            </p>
            <p
              id="router-kpi-net-savings"
              class={[
                "text-2xl font-semibold tabular-nums",
                net_class(@summary.net_savings_usd)
              ]}
            >
              {Stats.money(@summary.net_savings_usd)}
            </p>
            <p class="text-xs text-base-content/50 mt-1">
              {gettext("%{savings} over the priced baseline", savings: pct(@summary.savings_pct))}
            </p>
          </div>
        </div>

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4" id="router-rates">
          <div class="rounded-box border border-base-300 bg-base-100 p-3">
            <p class="text-xs text-base-content/50">{gettext("Prompt tokens saved (est.)")}</p>
            <p class="text-lg font-semibold tabular-nums" id="router-prompt-tokens-saved">
              {Stats.format_number(@summary.prompt_tokens_saved_est)}
            </p>
          </div>
          <div class="rounded-box border border-base-300 bg-base-100 p-3">
            <p class="text-xs text-base-content/50">{gettext("Served + decision $/1M tokens")}</p>
            <p class="text-lg font-semibold tabular-nums" id="router-usd-per-1m">
              {money_rate(@summary.served_plus_decision_usd_per_1m_tokens)}
            </p>
          </div>
          <div class="rounded-box border border-base-300 bg-base-100 p-3">
            <p class="text-xs text-base-content/50">{gettext("Spend $/1K requests")}</p>
            <p class="text-lg font-semibold tabular-nums" id="router-usd-per-1k">
              {money_rate(@summary.usd_per_1k_requests)}
            </p>
          </div>
          <div class="rounded-box border border-base-300 bg-base-100 p-3">
            <p class="text-xs text-base-content/50">{gettext("Avg decision time")}</p>
            <p class="text-lg font-semibold tabular-nums" id="router-avg-decision">
              {Stats.format_ms(@summary.avg_decision_ms)}
            </p>
          </div>
        </div>
      <% else %>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <p class="text-sm text-base-content/50 py-6 text-center" id="router-stats-loading">
              {gettext("Loading router metrics…")}
            </p>
          </div>
        </div>
      <% end %>

      <%!-- False-savings traffic light --%>
      <div class="card bg-base-100 border border-base-300 shadow-sm" id="router-signals">
        <div class="card-body">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="card-title text-base">
              <.icon name="hero-shield-exclamation" class="w-5 h-5 text-base-content/60" />
              {gettext("False-savings signals")}
            </h2>
            <span :if={@signals} class={["badge badge-sm", status_badge(@signals.status)]}>
              {status_label(@signals.status)}
            </span>
          </div>
          <p class="text-xs text-base-content/60">
            {gettext(
              "A saving obtained by losing cache reuse, switching models mid-session or falling back is not a saving."
            )}
          </p>

          <div :if={@signals} class="mt-3 overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("Signal")}</th>
                  <th class="text-right">{gettext("Value")}</th>
                  <th class="text-right">{gettext("Warn")}</th>
                  <th class="text-right">{gettext("Critical")}</th>
                  <th>{gettext("State")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={signal <- @signals.signals} id={"router-signal-#{signal.key}"}>
                  <td>
                    <p class="text-sm">{signal_label(signal.key)}</p>
                    <p class="text-xs text-base-content/50">{signal.message}</p>
                  </td>
                  <td class="text-right tabular-nums text-sm">{pct(signal.value)}</td>
                  <td class="text-right tabular-nums text-xs text-base-content/50">
                    {pct(signal.warn_at)}
                  </td>
                  <td class="text-right tabular-nums text-xs text-base-content/50">
                    {pct(signal.critical_at)}
                  </td>
                  <td>
                    <span class={["badge badge-xs", status_badge(signal.level)]}>
                      {status_label(signal.level)}
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
            <p class="text-xs text-base-content/50 mt-2">
              {gettext("Session coverage: %{coverage} · %{sessions} sessions",
                coverage: pct(@signals.session_coverage_pct),
                sessions: Stats.format_number(@signals.sessions_count)
              )}
            </p>
          </div>
        </div>
      </div>

      <%!-- Actionable insights --%>
      <div
        :if={@insights != []}
        class="card bg-base-100 border border-base-300 shadow-sm"
        id="router-insights"
      >
        <div class="card-body">
          <h2 class="card-title text-base">
            <.icon name="hero-light-bulb" class="w-5 h-5 text-base-content/60" />
            {gettext("Decision insights")}
          </h2>
          <ul class="mt-2 space-y-3">
            <li :for={insight <- @insights} id={"router-insight-#{insight.key}"} class="flex gap-3">
              <span class={["badge badge-sm shrink-0", status_badge(insight.level)]}>
                {status_label(insight.level)}
              </span>
              <div class="min-w-0">
                <p class="text-sm font-medium">{insight.title}</p>
                <p class="text-xs text-base-content/60">{insight.detail}</p>
              </div>
            </li>
          </ul>
        </div>
      </div>

      <%!-- Default vs Shadow: what a candidate version would have decided over
           the traffic the Default already served. --%>
      <div
        :if={@shadow_comparison != []}
        class="card bg-base-100 border border-base-300 shadow-sm"
        id="router-shadow-comparison"
      >
        <div class="card-body">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="card-title text-base">
              <.icon name="hero-beaker" class="w-5 h-5 text-base-content/60" />
              {gettext("Default vs Shadow")}
            </h2>
            <span class="badge badge-sm badge-ghost" id="router-shadow-count">
              {gettext("%{count} shadow versions", count: length(@shadow_comparison))}
            </span>
          </div>
          <p class="text-xs text-base-content/60">
            {gettext(
              "A Shadow version estimates the input and its own decision with the real tokens of each request the Default already served. Nothing was sent upstream twice and nothing extra was billed."
            )}
          </p>

          <div class="mt-3 overflow-x-auto">
            <table class="table table-sm" id="router-shadow-table">
              <thead>
                <tr>
                  <th>{gettext("Version")}</th>
                  <th class="text-right">{gettext("Evaluations")}</th>
                  <th class="text-right">{gettext("Model agreement")}</th>
                  <th class="text-right">{gettext("Tier agreement")}</th>
                  <th class="text-right">{gettext("Changes")}</th>
                  <th class="text-right">{gettext("Default vs estimated")}</th>
                  <th class="text-right">{gettext("Estimated delta")}</th>
                  <th class="text-right">{gettext("Tokens trimmed")}</th>
                  <th class="text-right">{gettext("Action")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @shadow_comparison} id={"router-shadow-#{row.shadow_config_id}"}>
                  <td>
                    <p class="text-sm font-medium flex flex-wrap items-center gap-1.5">
                      {row.shadow_config_name}
                      <span
                        :if={row.shadow_enabled}
                        class="badge badge-xs badge-success"
                        id={"router-shadow-live-#{row.shadow_config_id}"}
                      >
                        {gettext("Active shadow")}
                      </span>
                      <span :if={row.archived} class="badge badge-xs badge-ghost">
                        {gettext("Archived")}
                      </span>
                    </p>
                  </td>
                  <td class="text-right tabular-nums text-sm">
                    {Stats.format_number(row.ok_count)}
                    <span
                      :if={row.error_count > 0}
                      class="text-xs text-error"
                      title={gettext("Evaluations that could not decide")}
                    >
                      +{Stats.format_number(row.error_count)}
                    </span>
                  </td>
                  <td class="text-right tabular-nums text-sm">{pct(row.agreement_pct)}</td>
                  <td class="text-right tabular-nums text-sm">{pct(row.tier_agreement_pct)}</td>
                  <td class="text-right tabular-nums text-xs whitespace-nowrap">
                    <span class="text-error">↓{Stats.format_number(row.downgrade_count)}</span>
                    <span class="text-base-content/40"> · </span>
                    <span class="text-warning">↑{Stats.format_number(row.upgrade_count)}</span>
                  </td>
                  <td class="text-right tabular-nums text-sm whitespace-nowrap">
                    {Stats.money(row.default_served_cost_usd)}
                    <span class="text-base-content/40">→</span>
                    {Stats.money(row.shadow_total_cost_usd)}
                    <p class="text-xs text-base-content/50">
                      {gettext("%{coverage} priced", coverage: pct(row.coverage_pct))} ({Stats.format_number(
                        row.priced_count
                      )})
                    </p>
                  </td>
                  <td class={[
                    "text-right tabular-nums text-sm whitespace-nowrap",
                    delta_money_class(row.estimated_delta_usd)
                  ]}>
                    {Stats.money(row.estimated_delta_usd)}
                    <p class="text-xs">{delta_pct(row.estimated_delta_pct)}</p>
                  </td>
                  <td class="text-right tabular-nums text-xs">
                    {Stats.format_number(row.prompt_tokens_saved_est)}
                  </td>
                  <td class="text-right">
                    <.link
                      navigate={~p"/catalog/router?tab=versions"}
                      class="btn btn-xs btn-ghost"
                      id={"router-shadow-open-#{row.shadow_config_id}"}
                    >
                      {gettext("Open in Router")}
                    </.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <%!-- The version selector sits OUTSIDE the migration block on purpose:
               a version that agreed on 100% of the window has no migrations,
               yet the operator must still be able to switch to another one. --%>
          <div
            :if={length(@shadow_comparison) > 1}
            class="mt-3 join"
            id="router-shadow-switcher"
          >
            <button
              :for={row <- @shadow_comparison}
              type="button"
              id={"router-shadow-select-#{row.shadow_config_id}"}
              phx-click="select_shadow_version"
              phx-value-shadow_config_id={row.shadow_config_id}
              class={[
                "btn btn-xs join-item",
                if(row.shadow_config_id == @shadow_selected_id,
                  do: "btn-primary",
                  else: "btn-ghost"
                )
              ]}
            >
              {row.shadow_config_name}
            </button>
          </div>

          <%!-- The migration breakdown answers "which decisions would change",
               for ONE version at a time. --%>
          <div
            :if={@shadow_migrations != []}
            class="mt-4 rounded-box border border-base-300 bg-base-200/40 p-3"
            id="router-shadow-migrations"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div>
                <p class="text-sm font-medium">
                  {gettext("Top migrations · %{version}",
                    version: shadow_name(@shadow_comparison, @shadow_selected_id)
                  )}
                </p>
                <p class="text-xs text-base-content/50">
                  {gettext(
                    "Only the evaluations where the Shadow differed, grouped by the exact use case, model and tier it would have served."
                  )}
                </p>
              </div>
            </div>

            <div class="mt-3 overflow-x-auto">
              <table class="table table-xs" id="router-shadow-migration-table">
                <thead>
                  <tr>
                    <th>{gettext("Migration")}</th>
                    <th class="text-right">{gettext("Evaluations")}</th>
                    <th class="text-right">{gettext("Default vs estimated")}</th>
                    <th class="text-right">{gettext("Estimated delta")}</th>
                    <th class="text-right">{gettext("Tokens trimmed")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @shadow_migrations}>
                    <td class="text-xs">
                      <p class="font-mono">
                        {row.use_case_key}: {row.default_model_name || "—"}
                        <span class="text-base-content/40">→</span>
                        {row.model_name || "—"}
                      </p>
                      <p class="font-mono text-base-content/50">
                        {row.default_effort_tier || "—"} → {row.effort_tier || "—"}
                      </p>
                    </td>
                    <td class="text-right tabular-nums text-xs">
                      {Stats.format_number(row.eval_count)}
                    </td>
                    <td class="text-right tabular-nums text-xs whitespace-nowrap">
                      {Stats.money(row.default_served_cost_usd)}
                      <span class="text-base-content/40">→</span>
                      {Stats.money(row.shadow_total_cost_usd)}
                    </td>
                    <td class={[
                      "text-right tabular-nums text-xs whitespace-nowrap",
                      delta_money_class(row.estimated_delta_usd)
                    ]}>
                      {Stats.money(row.estimated_delta_usd)}
                      <span class="text-base-content/50">
                        ({delta_pct(row.estimated_delta_pct)})
                      </span>
                    </td>
                    <td class="text-right tabular-nums text-xs">
                      {Stats.format_number(row.prompt_tokens_saved_est)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <p
            :if={@shadow_migrations == []}
            class="text-xs text-base-content/50 mt-3"
            id="router-shadow-agreement"
          >
            {gettext(
              "The selected Shadow version agreed with the Default on every evaluation in this window: there is no migration to show."
            )}
          </p>
        </div>
      </div>

      <%!-- Use case × effort mix --%>
      <div class="card bg-base-100 border border-base-300 shadow-sm" id="router-use-case-mix">
        <div class="card-body">
          <h2 class="card-title text-base">
            <.icon name="hero-squares-2x2" class="w-5 h-5 text-base-content/60" />
            {gettext("Use case × effort mix")}
          </h2>
          <p class="text-xs text-base-content/60">
            {gettext(
              "Spend, honest net savings and escalation share per use case and effort tier over %{period}.",
              period: Stats.period_label(@period)
            )}
          </p>

          <div :if={@use_cases != []} class="mt-3 overflow-x-auto">
            <% rows = @use_cases %>
            <% list_rows = Stats.shown_rows(rows, "router-use-cases", @shown_counts, @per_page) %>
            <table class="table table-sm" id="router-use-case-table">
              <thead>
                <tr>
                  <th>{gettext("Use case")}</th>
                  <th>{gettext("Tier")}</th>
                  <th class="text-right">{gettext("Requests")}</th>
                  <th class="text-right">{gettext("Share")}</th>
                  <th class="text-right">{gettext("Spend")}</th>
                  <th class="text-right">{gettext("$/1M")}</th>
                  <th class="text-right">{gettext("Net savings")}</th>
                  <th class="text-right">{gettext("Escalated")}</th>
                  <th class="text-right">{gettext("Fallbacks")}</th>
                  <th class="text-right">{gettext("Tokens saved")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- list_rows} id={"router-uc-#{row.use_case_key}-#{row.effort_tier}"}>
                  <td>
                    <p class="text-sm font-medium">{row.use_case_name || row.use_case_key}</p>
                    <p class="text-xs text-base-content/50 font-mono">{row.use_case_key}</p>
                  </td>
                  <td><span class="badge badge-sm badge-ghost">{row.effort_tier}</span></td>
                  <td class="text-right tabular-nums text-sm">
                    {Stats.format_number(row.request_count)}
                  </td>
                  <td class="text-right tabular-nums text-xs">{pct(row.share_pct)}</td>
                  <td class="text-right tabular-nums text-sm">{Stats.money(row.total_cost_usd)}</td>
                  <td class="text-right tabular-nums text-xs">{money_rate(row.usd_per_1m_tokens)}</td>
                  <td class={[
                    "text-right tabular-nums text-sm",
                    net_class(row.net_savings_usd)
                  ]}>
                    {Stats.money(row.net_savings_usd)}
                  </td>
                  <td class="text-right tabular-nums text-xs">{pct(row.escalation_pct)}</td>
                  <td class="text-right tabular-nums text-xs">{pct(row.fallback_rate_pct)}</td>
                  <td class="text-right tabular-nums text-xs">
                    {Stats.format_number(row.prompt_tokens_saved_est)}
                  </td>
                </tr>
              </tbody>
            </table>
            <Stats.show_more
              key="router-use-cases"
              id="router-use-cases-more"
              top={length(list_rows)}
              total={length(rows)}
            />
          </div>

          <p :if={@use_cases == []} class="text-sm text-base-content/50 py-3">
            {gettext("No routed traffic in this window.")}
          </p>
        </div>
      </div>

      <%!-- Model performance --%>
      <div class="card bg-base-100 border border-base-300 shadow-sm" id="router-model-performance">
        <div class="card-body">
          <h2 class="card-title text-base">
            <.icon name="hero-cpu-chip" class="w-5 h-5 text-base-content/60" />
            {gettext("Model performance on routed traffic")}
          </h2>
          <p class="text-xs text-base-content/60">
            {gettext(
              "Throughput measured over the generation window only, TTFT/latency percentiles and normalized cost."
            )}
          </p>

          <div :if={@model_perf != []} class="mt-3 overflow-x-auto">
            <% rows = @model_perf %>
            <% list_rows = Stats.shown_rows(rows, "router-models", @shown_counts, @per_page) %>
            <table class="table table-sm" id="router-model-table">
              <thead>
                <tr>
                  <th>{gettext("Model")}</th>
                  <th class="text-right">{gettext("Requests")}</th>
                  <th class="text-right">{gettext("tok/s")}</th>
                  <th class="text-right">{gettext("TTFT p50 / p95")}</th>
                  <th class="text-right">{gettext("Latency p50 / p95")}</th>
                  <th class="text-right">{gettext("Spend")}</th>
                  <th class="text-right">{gettext("$/1M")}</th>
                  <th class="text-right">{gettext("Fallbacks")}</th>
                  <th class="text-right">{gettext("Errors")}</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={{row, idx} <- Enum.with_index(list_rows)}
                  id={"router-model-#{idx}"}
                >
                  <td>
                    <p class="text-sm font-medium">{row.model_name}</p>
                    <p
                      :if={row.model_resolved && row.model_resolved != row.model_name}
                      class="text-xs text-base-content/50"
                    >
                      {row.model_resolved}
                    </p>
                  </td>
                  <td class="text-right tabular-nums text-sm">
                    {Stats.format_number(row.request_count)}
                  </td>
                  <td class="text-right tabular-nums text-sm">
                    {Stats.format_tps(row.tokens_per_sec)}
                  </td>
                  <td class="text-right tabular-nums text-xs">
                    {Stats.format_ms(row.ttft_p50_ms)} / {Stats.format_ms(row.ttft_p95_ms)}
                  </td>
                  <td class="text-right tabular-nums text-xs">
                    {Stats.format_ms(row.latency_p50_ms)} / {Stats.format_ms(row.latency_p95_ms)}
                  </td>
                  <td class="text-right tabular-nums text-sm">{Stats.money(row.total_cost_usd)}</td>
                  <td class="text-right tabular-nums text-xs">{money_rate(row.usd_per_1m_tokens)}</td>
                  <td class="text-right tabular-nums text-xs">{pct(row.fallback_rate_pct)}</td>
                  <td class="text-right tabular-nums text-xs">{pct(row.error_rate_pct)}</td>
                </tr>
              </tbody>
            </table>
            <Stats.show_more
              key="router-models"
              id="router-models-more"
              top={length(list_rows)}
              total={length(rows)}
            />
          </div>
        </div>
      </div>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <%!-- Router vs direct --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm" id="router-vs-direct">
          <div class="card-body">
            <h2 class="card-title text-base">
              <.icon name="hero-arrows-right-left" class="w-5 h-5 text-base-content/60" />
              {gettext("Router vs direct")}
            </h2>
            <p class="text-xs text-base-content/60">
              {gettext(
                "The same subject's routed traffic against its own non-routed traffic in the window."
              )}
            </p>

            <div :if={@vs_direct != []} class="mt-3 overflow-x-auto">
              <% rows = @vs_direct %>
              <% list_rows = Stats.shown_rows(rows, "router-vs-direct", @shown_counts, @per_page) %>
              <table class="table table-sm" id="router-vs-direct-table">
                <thead>
                  <tr>
                    <th>{gettext("Subject")}</th>
                    <th class="text-right">{gettext("Router $/1M")}</th>
                    <th class="text-right">{gettext("Direct $/1M")}</th>
                    <th class="text-right">{gettext("Δ")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- list_rows}>
                    <td>
                      <p class="text-sm font-medium">{row.subject_name}</p>
                      <p class="text-xs text-base-content/50">
                        {row.group_name || "—"} · {gettext("router")} {Stats.format_number(
                          row.router.request_count
                        )} · {gettext("direct")} {Stats.format_number(row.direct.request_count)}
                      </p>
                    </td>
                    <td class="text-right tabular-nums text-sm">
                      {money_rate(row.router.usd_per_1m_tokens)}
                    </td>
                    <td class="text-right tabular-nums text-sm">
                      {money_rate(row.direct.usd_per_1m_tokens)}
                    </td>
                    <td class={[
                      "text-right tabular-nums text-sm",
                      delta_class(row.usd_per_1m_delta_pct)
                    ]}>
                      {delta_pct(row.usd_per_1m_delta_pct)}
                    </td>
                  </tr>
                </tbody>
              </table>
              <Stats.show_more
                key="router-vs-direct"
                id="router-vs-direct-more"
                top={length(list_rows)}
                total={length(rows)}
              />
            </div>

            <p :if={@vs_direct == []} class="text-sm text-base-content/50 py-3">
              {gettext("No subject has both routed and direct traffic in this window.")}
            </p>
          </div>
        </div>

        <%!-- Decision sources --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm" id="router-sources">
          <div class="card-body">
            <h2 class="card-title text-base">{gettext("Decision sources")}</h2>
            <p class="text-xs text-base-content/60">
              {gettext("How each routed request was decided, and what that path cost.")}
            </p>

            <div :if={@sources != []} class="mt-3 overflow-x-auto">
              <table class="table table-sm" id="router-sources-table">
                <thead>
                  <tr>
                    <th>{gettext("Source")}</th>
                    <th class="text-right">{gettext("Requests")}</th>
                    <th class="text-right">{gettext("Spend")}</th>
                    <th class="text-right">{gettext("Escalated")}</th>
                    <th class="text-right">{gettext("Decision p50")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @sources}>
                    <td class="font-mono text-xs">{row.decision_source}</td>
                    <td class="text-right tabular-nums text-sm">
                      {Stats.format_number(row.request_count)}
                    </td>
                    <td class="text-right tabular-nums text-sm">{Stats.money(row.total_cost_usd)}</td>
                    <td class="text-right tabular-nums text-xs">{pct(row.escalation_pct)}</td>
                    <td class="text-right tabular-nums text-xs">
                      {Stats.format_ms(row.p50_decision_ms)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>

      <%!-- Who spent on what --%>
      <div class="card bg-base-100 border border-base-300 shadow-sm" id="router-attribution">
        <div class="card-body">
          <h2 class="card-title text-base">
            <.icon name="hero-user-group" class="w-5 h-5 text-base-content/60" />
            {gettext("Who spent on what")}
          </h2>
          <p class="text-xs text-base-content/60">
            {gettext(
              "Subject × resolved model. Requests the subject could only reach through the router are flagged: that spend exists because of the router."
            )}
          </p>

          <div :if={@attribution != []} class="mt-3 overflow-x-auto">
            <% rows = @attribution %>
            <% list_rows = Stats.shown_rows(rows, "router-attribution", @shown_counts, @per_page) %>
            <table class="table table-sm" id="router-attribution-table">
              <thead>
                <tr>
                  <th>{gettext("Subject")}</th>
                  <th>{gettext("Limit profile")}</th>
                  <th>{gettext("Model")}</th>
                  <th class="text-right">{gettext("Requests")}</th>
                  <th class="text-right">{gettext("Spend")}</th>
                  <th class="text-right">{gettext("$/1M")}</th>
                  <th class="text-right">{gettext("Last seen")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{row, idx} <- Enum.with_index(list_rows)}>
                  <td>
                    <p class="text-sm font-medium">{row.subject_name}</p>
                    <p class="text-xs text-base-content/50">{row.subject_type}</p>
                  </td>
                  <td class="text-sm">{row.group_name || "—"}</td>
                  <td>
                    <p class="text-sm">{row.model_name}</p>
                    <span
                      :if={row.direct_access == false}
                      class="badge badge-xs badge-warning"
                      id={"router-no-direct-#{idx}"}
                    >
                      {gettext("no direct access")}
                    </span>
                  </td>
                  <td class="text-right tabular-nums text-sm">
                    {Stats.format_number(row.request_count)}
                  </td>
                  <td class="text-right tabular-nums text-sm">{Stats.money(row.cost_usd)}</td>
                  <td class="text-right tabular-nums text-xs">{money_rate(row.usd_per_1m_tokens)}</td>
                  <td class="text-right tabular-nums text-xs">
                    {Stats.format_dt(row.last_seen_at)}
                  </td>
                </tr>
              </tbody>
            </table>
            <Stats.show_more
              key="router-attribution"
              id="router-attribution-more"
              top={length(list_rows)}
              total={length(rows)}
            />
          </div>

          <p :if={@attribution == []} class="text-sm text-base-content/50 py-3">
            {gettext("No routed spend to attribute in this window.")}
          </p>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Formatting
  # ---------------------------------------------------------------------------

  # Analytics returns percentages already multiplied (12.5 = 12.5%).
  defp pct(nil), do: "—"
  defp pct(value) when is_float(value), do: "#{Float.round(value, 1)}%"
  defp pct(value) when is_integer(value), do: "#{value}%"
  defp pct(_), do: "—"

  defp money_rate(nil), do: "—"

  defp money_rate(value) when is_float(value) do
    "$" <> :erlang.float_to_binary(value, decimals: 2)
  end

  defp money_rate(value), do: "$#{value}"

  defp delta_pct(nil), do: "—"

  defp delta_pct(value) when is_float(value) do
    prefix = if value > 0, do: "+", else: ""
    "#{prefix}#{Float.round(value, 1)}%"
  end

  defp delta_pct(value), do: to_string(value)

  defp delta_class(nil), do: "text-base-content/50"

  defp delta_class(value) when is_float(value) do
    cond do
      value < 0 -> "text-success"
      value > 0 -> "text-error"
      true -> "text-base-content/50"
    end
  end

  defp delta_class(_), do: "text-base-content/50"

  # Negative net savings is real information (the router escalated above the
  # baseline): it is painted red, never clipped to zero.
  defp net_class(%Decimal{} = value) do
    cond do
      Decimal.negative?(value) -> "text-error"
      Decimal.positive?(value) -> "text-success"
      true -> ""
    end
  end

  defp net_class(value) when is_number(value) do
    cond do
      value < 0 -> "text-error"
      value > 0 -> "text-success"
      true -> ""
    end
  end

  defp net_class(_), do: ""

  # A Shadow delta is `shadow - default`: positive means the candidate would
  # have been MORE expensive (red), negative is the estimated saving (green).
  # Same convention as `delta_class/1`, for Decimals.
  defp delta_money_class(%Decimal{} = value) do
    cond do
      Decimal.positive?(value) -> "text-error"
      Decimal.negative?(value) -> "text-success"
      true -> "text-base-content/50"
    end
  end

  defp delta_money_class(_), do: "text-base-content/50"

  # Which version's migrations are on screen (the selected one, falling back to
  # whatever the row says).
  defp shadow_name(rows, id) do
    Enum.find_value(rows, "—", fn row ->
      if row.shadow_config_id == id, do: row.shadow_config_name
    end)
  end

  defp status_badge(:ok), do: "badge-success"
  defp status_badge(:warning), do: "badge-warning"
  defp status_badge(:critical), do: "badge-error"
  defp status_badge(_), do: "badge-ghost"

  defp status_label(:ok), do: gettext("OK")
  defp status_label(:warning), do: gettext("Warning")
  defp status_label(:critical), do: gettext("Critical")
  defp status_label(:info), do: gettext("Info")
  defp status_label(_), do: gettext("Unknown")

  defp signal_label(:session_switches), do: gettext("Model switches inside a session")
  defp signal_label(:classifier_overhead), do: gettext("Classifier cost share")
  defp signal_label(:cache_read), do: gettext("Prompt-cache reuse")
  defp signal_label(:fallback_rate), do: gettext("Fallback rate")
  defp signal_label(other), do: to_string(other)
end
