defmodule Tokengate.SmartRouter.Analytics do
  @moduledoc """
  Honest SmartRouter analytics over the partitioned `request_logs`.

  Every read here answers a *bounded* question: `Logs.ensure_window!/2` is the
  first thing each public function does, so a caller that forgets `:from`
  fails loudly in dev/test instead of receiving "whatever survived retention"
  presented as a total. In production the window is clamped to the retention
  cutoff with a warning — never silently widened.

  ## Why raw `request_logs`

  `request_metrics_hourly` does not carry `service_id` nor any router
  dimension (`router_use_case_key`, `router_effort_tier`,
  `router_decision_source`, `router_baseline_cost_usd`, …). Adding them would
  multiply the rollup cardinality and still miss services, so router analytics
  reads the raw table through the partial index
  `request_logs_routed_via_router_inserted_at_idx`
  (`(inserted_at) WHERE routed_via_router = true`). Attribution queries follow
  the two-pass shape of `Tokengate.Metrics.StatsQueries.raw_model_member_rows/3`:
  aggregate on raw ids inside a subquery, then join `users`, `services`,
  `group_members`, `groups` and `models` onto that (small) aggregate — never
  join the names into the aggregate, where the wide `GROUP BY` key spills to
  disk.

  ## Honest savings

    * `net_savings_usd = Σ router_baseline_cost_usd - Σ provider_cost_usd -
      Σ router_decision_cost_usd`, computed **strictly over rows where
      `router_baseline_cost_usd IS NOT NULL`**. No `GREATEST(0, …)`: a negative
      net is real information (the router escalated above the baseline) and is
      reported as such.
    * `baseline_coverage_pct` says how much of the routed traffic carried a
      counterfactual price, so an incomplete baseline is visible next to the
      number it decorates.
    * Cache hits are counted separately (`cache_hit_count`) instead of being
      folded into the baseline denominator: a `ResponseCache` hit is not a
      model-selection saving.
    * Raw USD totals travel with volume-normalized rates (`$/1M tokens`,
      `$/1K requests`) because a big total on tiny volume is not a saving.

  ## Conventions

    * Ratios are `nil` when their denominator is zero (the UI renders "—");
      `0.0` always means "measured, and it was zero".
    * Money is `Decimal` with 6 decimals; percentages/rates are floats rounded
      to 2 (percent) or 4 (rates) decimals.
    * `cache_read_pct` follows `TokengateWeb.StatsHelpers.cache_hit_pct/2`:
      `cache_read_tokens / prompt_tokens × 100`.
    * Throughput is `completion_tokens / (GREATEST(latency_ms - COALESCE(ttft_ms, 0), 1) / 1000.0)`,
      i.e. generated tokens over the generation window only, never over the
      full latency.

  ## Shadow versions

  Shadow reads answer "what would that candidate version have done?" over
  `router_shadow_evaluations`, a separate child table (never `request_logs`):
  the Default served the request, the Shadow re-decided it after the response
  left. Their shape mirrors the rest of the module:

    * `eval_count` = every recorded evaluation; `ok_count` = those with
      `error_reason IS NULL` (the only rows that carry a decision);
      `error_count` = the rest. Agreement/tier percentages divide by
      `ok_count`, so a version that mostly errored cannot look agreeable.
    * `priced_count` / `coverage_pct` say how many ok rows carried an
      estimated price. `default_served_cost_usd` sums the Default's real cost
      **only over priced rows**, so the delta compares the same requests on
      both sides instead of mixing priced shadows with unpriced defaults.
    * `estimated_delta_usd` is `shadow_total - default_served` over that same
      priced set and is **never clipped**: negative is the estimated saving,
      positive is the estimated premium.
    * `decision_cost_usd` (the Shadow classifier's own cost) is folded into
      `shadow_total_cost_usd` over the SAME priced ok rows, because a cheaper
      destination paid for with an expensive classifier is not cheaper.
  """

  import Ecto.Query, warn: false

  alias Tokengate.Accounts.GroupMember
  alias Tokengate.Accounts.Service
  alias Tokengate.Accounts.User
  alias Tokengate.Logs
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Providers.Model
  alias Tokengate.Repo
  alias Tokengate.SmartRouter.Config, as: RouterConfig
  alias Tokengate.SmartRouter.ShadowEvaluation
  alias Tokengate.SmartRouter.UseCase, as: RouterUseCase

  # Same budget-heavy env key the stats facades use: a cold window over
  # partitioned logs is a multi-second scan in production.
  @default_timeout 120_000

  # Filters this module understands (atom keys; the matching string keys are
  # accepted too, because callers sometimes hand over query params).
  @filter_keys [
    :from,
    :to,
    :model_id,
    :model_resolved,
    :service_id,
    :user_id,
    :user_ids,
    :group_member_id,
    :member_ids,
    :group_id,
    :router_use_case_key,
    :router_effort_tier,
    :router_decision_source,
    :shadow_config_id,
    :default_config_id
  ]

  # Thresholds behind `false_savings_signals/1` and `decision_insights/1`.
  # Warning levels follow the shaping (>10-15 % for classifier overhead).
  @switch_warn_pct 15.0
  @switch_crit_pct 30.0
  @classifier_share_warn_pct 10.0
  @classifier_share_crit_pct 20.0
  @fallback_warn_pct 15.0
  @fallback_crit_pct 30.0
  @cache_read_warn_pct 20.0
  @cache_read_crit_pct 5.0

  # ---------------------------------------------------------------------
  # Summary
  # ---------------------------------------------------------------------

  @doc """
  Period KPIs over the routed traffic: volume, honest net savings with its
  baseline coverage, volume-normalized rates, prompt tokens trimmed and the
  classifier's own cost/latency.

  `net_savings_usd` is `baseline - provider - decision` over the rows that
  actually carry a baseline price; a negative value is returned unchanged.
  """
  def summary(filters \\ []) do
    filters = window!(filters, "SmartRouter.Analytics.summary/1")

    row =
      filters
      |> routed_query()
      |> select([rl], %{
        request_count: count(rl.id),
        cache_hit_count: fragment("COUNT(*) FILTER (WHERE ?)", rl.cache_hit),
        error_count: fragment("COUNT(*) FILTER (WHERE COALESCE(?, 0) >= 400)", rl.status_code),
        fallback_count:
          fragment(
            "COUNT(*) FILTER (WHERE ? IN ('fallback_timeout', 'fallback_error'))",
            rl.router_decision_source
          ),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_read_tokens),
        prompt_tokens_saved:
          fragment("COALESCE(SUM(COALESCE(?, 0)), 0)::bigint", rl.prompt_tokens_saved_est),
        served_cost: fragment("COALESCE(SUM(COALESCE(?, 0)), 0)", rl.provider_cost_usd),
        decision_cost: fragment("COALESCE(SUM(COALESCE(?, 0)), 0)", rl.router_decision_cost_usd),
        baseline_cost: fragment("COALESCE(SUM(?), 0)", rl.router_baseline_cost_usd),
        covered_rows:
          fragment("COUNT(*) FILTER (WHERE ? IS NOT NULL)", rl.router_baseline_cost_usd),
        covered_cost:
          fragment(
            "COALESCE(SUM(COALESCE(?, 0) + COALESCE(?, 0)) FILTER (WHERE ? IS NOT NULL), 0)",
            rl.provider_cost_usd,
            rl.router_decision_cost_usd,
            rl.router_baseline_cost_usd
          ),
        covered_tokens:
          fragment(
            "COALESCE(SUM(COALESCE(?, 0) + COALESCE(?, 0)) FILTER (WHERE ? IS NOT NULL), 0)::bigint",
            rl.prompt_tokens,
            rl.completion_tokens,
            rl.router_baseline_cost_usd
          ),
        classifier_request_count:
          fragment("COUNT(*) FILTER (WHERE ? = 'classifier')", rl.router_decision_source),
        classifier_cost:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE ? = 'classifier'), 0)",
            rl.router_decision_cost_usd,
            rl.router_decision_source
          ),
        classifier_p50_ms:
          fragment(
            "percentile_cont(0.5) WITHIN GROUP (ORDER BY ?) FILTER (WHERE ? = 'classifier' AND ? > 0)",
            rl.router_decision_ms,
            rl.router_decision_source,
            rl.router_decision_ms
          ),
        classifier_p95_ms:
          fragment(
            "percentile_cont(0.95) WITHIN GROUP (ORDER BY ?) FILTER (WHERE ? = 'classifier' AND ? > 0)",
            rl.router_decision_ms,
            rl.router_decision_source,
            rl.router_decision_ms
          ),
        avg_decision_ms:
          fragment("AVG(?) FILTER (WHERE ? > 0)", rl.router_decision_ms, rl.router_decision_ms),
        decision_rows: fragment("COUNT(*) FILTER (WHERE ? > 0)", rl.router_decision_ms)
      })
      |> Repo.one(timeout: query_timeout())

    served = decimal(row.served_cost)
    decision = decimal(row.decision_cost)
    total_cost = Decimal.add(served, decision)
    baseline = decimal(row.baseline_cost)
    covered_cost = decimal(row.covered_cost)
    net = Decimal.sub(baseline, covered_cost)
    tokens = row.prompt_tokens + row.completion_tokens

    %{
      request_count: row.request_count,
      cache_hit_count: row.cache_hit_count,
      cache_hit_pct: percent(row.cache_hit_count, row.request_count),
      error_count: row.error_count,
      error_rate_pct: percent(row.error_count, row.request_count),
      fallback_count: row.fallback_count,
      fallback_rate_pct: percent(row.fallback_count, row.request_count),
      prompt_tokens: row.prompt_tokens,
      completion_tokens: row.completion_tokens,
      total_tokens: tokens,
      cache_read_tokens: row.cache_read_tokens,
      cache_read_pct: percent(row.cache_read_tokens, row.prompt_tokens),
      prompt_tokens_saved_est: row.prompt_tokens_saved,
      served_cost_usd: money(served),
      decision_cost_usd: money(decision),
      served_plus_decision_usd: money(total_cost),
      baseline_cost_usd: money(baseline),
      baseline_request_count: row.covered_rows,
      baseline_coverage_pct: percent(row.covered_rows, row.request_count),
      net_savings_usd: money(net),
      savings_pct: percent_of(net, baseline),
      usd_per_1k_requests: rate(total_cost, row.request_count, 1_000),
      # Over EVERY served token in the window: the classified request is paid
      # for whether or not that row carried a baseline price, so its rate must
      # not depend on baseline coverage. `covered_tokens` is reserved for the
      # baseline/savings pair below, which only exists for priced rows.
      served_plus_decision_usd_per_1m_tokens: rate(total_cost, tokens, 1_000_000),
      baseline_usd_per_1m_tokens: rate(baseline, row.covered_tokens, 1_000_000),
      savings_usd_per_1m_tokens:
        rate(Decimal.sub(baseline, covered_cost), row.covered_tokens, 1_000_000),
      classifier_request_count: row.classifier_request_count,
      classifier_cost_usd: money(decimal(row.classifier_cost)),
      classifier_cost_share_pct: percent_of(decimal(row.classifier_cost), total_cost),
      classifier_p50_ms: float_or_nil(row.classifier_p50_ms),
      classifier_p95_ms: float_or_nil(row.classifier_p95_ms),
      decision_request_count: row.decision_rows,
      avg_decision_ms: float_or_nil(row.avg_decision_ms)
    }
  end

  # ---------------------------------------------------------------------
  # Breakdowns (no name joins: source is a low-cardinality enum, the use case
  # key is denormalised on the row on purpose)
  # ---------------------------------------------------------------------

  @doc """
  Routed traffic grouped by `router_decision_source`: how many requests each
  path answered, what they cost (served + the decision step's own cost), how
  much baseline they covered and how often they escalated above it.

  Sorted by request count, descending.
  """
  def decision_source_breakdown(filters \\ []) do
    filters = window!(filters, "SmartRouter.Analytics.decision_source_breakdown/1")

    rows =
      filters
      |> routed_query()
      |> group_by([rl], fragment("COALESCE(?, 'unknown')", rl.router_decision_source))
      |> select([rl], %{
        decision_source: fragment("COALESCE(?, 'unknown')", rl.router_decision_source),
        request_count: count(rl.id),
        error_count: fragment("COUNT(*) FILTER (WHERE COALESCE(?, 0) >= 400)", rl.status_code),
        served_cost: fragment("COALESCE(SUM(COALESCE(?, 0)), 0)", rl.provider_cost_usd),
        decision_cost: fragment("COALESCE(SUM(COALESCE(?, 0)), 0)", rl.router_decision_cost_usd),
        baseline_cost: fragment("COALESCE(SUM(?), 0)", rl.router_baseline_cost_usd),
        covered_rows:
          fragment("COUNT(*) FILTER (WHERE ? IS NOT NULL)", rl.router_baseline_cost_usd),
        covered_cost:
          fragment(
            "COALESCE(SUM(COALESCE(?, 0) + COALESCE(?, 0)) FILTER (WHERE ? IS NOT NULL), 0)",
            rl.provider_cost_usd,
            rl.router_decision_cost_usd,
            rl.router_baseline_cost_usd
          ),
        covered_tokens:
          fragment(
            "COALESCE(SUM(COALESCE(?, 0) + COALESCE(?, 0)) FILTER (WHERE ? IS NOT NULL), 0)::bigint",
            rl.prompt_tokens,
            rl.completion_tokens,
            rl.router_baseline_cost_usd
          ),
        escalation_count:
          fragment(
            "COUNT(*) FILTER (WHERE ? IS NOT NULL AND (COALESCE(?, 0) + COALESCE(?, 0)) > ?)",
            rl.router_baseline_cost_usd,
            rl.provider_cost_usd,
            rl.router_decision_cost_usd,
            rl.router_baseline_cost_usd
          ),
        p50_decision_ms:
          fragment(
            "percentile_cont(0.5) WITHIN GROUP (ORDER BY ?) FILTER (WHERE ? > 0)",
            rl.router_decision_ms,
            rl.router_decision_ms
          ),
        p95_decision_ms:
          fragment(
            "percentile_cont(0.95) WITHIN GROUP (ORDER BY ?) FILTER (WHERE ? > 0)",
            rl.router_decision_ms,
            rl.router_decision_ms
          ),
        avg_decision_ms:
          fragment("AVG(?) FILTER (WHERE ? > 0)", rl.router_decision_ms, rl.router_decision_ms)
      })
      |> Repo.all(timeout: query_timeout())

    total_requests = Enum.reduce(rows, 0, &(&1.request_count + &2))

    total_cost =
      Enum.reduce(rows, Decimal.new(0), fn row, acc ->
        Decimal.add(acc, Decimal.add(decimal(row.served_cost), decimal(row.decision_cost)))
      end)

    rows
    |> Enum.map(fn row ->
      block = cost_block(row)
      row_cost = Decimal.add(decimal(row.served_cost), decimal(row.decision_cost))

      Map.merge(block, %{
        decision_source: row.decision_source,
        request_count: row.request_count,
        share_pct: percent(row.request_count, total_requests),
        fallback: row.decision_source in ["fallback_timeout", "fallback_error"],
        error_count: row.error_count,
        error_rate_pct: percent(row.error_count, row.request_count),
        escalation_count: row.escalation_count,
        escalation_pct: percent(row.escalation_count, row.covered_rows),
        cost_share_pct: percent_of(row_cost, total_cost),
        p50_decision_ms: float_or_nil(row.p50_decision_ms),
        p95_decision_ms: float_or_nil(row.p95_decision_ms),
        avg_decision_ms: float_or_nil(row.avg_decision_ms)
      })
    end)
    |> Enum.sort_by(&{-&1.request_count, &1.decision_source})
  end

  @doc """
  Routed traffic grouped by `router_use_case_key` × `router_effort_tier`.

  Reports spend, net savings (same honest definition as `summary/1`),
  escalation share (served+decision > baseline on priced rows), fallback
  rate, cache hit share and the prompt tokens the trimming knobs saved.
  Rows without a use case (`nil` use case / `nil` tier) are reported as
  `"unclassified"` / `"none"` so their spend is never invisible.

  The use case display name is resolved from `router_use_cases` in a second,
  tiny query — never inside the aggregation.
  """
  def use_case_breakdown(filters \\ []) do
    filters = window!(filters, "SmartRouter.Analytics.use_case_breakdown/1")

    rows =
      filters
      |> routed_query()
      |> group_by(
        [rl],
        [
          fragment("COALESCE(?, 'unclassified')", rl.router_use_case_key),
          fragment("COALESCE(?, 'none')", rl.router_effort_tier)
        ]
      )
      |> select([rl], %{
        use_case_key: fragment("COALESCE(?, 'unclassified')", rl.router_use_case_key),
        effort_tier: fragment("COALESCE(?, 'none')", rl.router_effort_tier),
        request_count: count(rl.id),
        cache_hit_count: fragment("COUNT(*) FILTER (WHERE ?)", rl.cache_hit),
        error_count: fragment("COUNT(*) FILTER (WHERE COALESCE(?, 0) >= 400)", rl.status_code),
        fallback_count:
          fragment(
            "COUNT(*) FILTER (WHERE ? IN ('fallback_timeout', 'fallback_error'))",
            rl.router_decision_source
          ),
        served_cost: fragment("COALESCE(SUM(COALESCE(?, 0)), 0)", rl.provider_cost_usd),
        decision_cost: fragment("COALESCE(SUM(COALESCE(?, 0)), 0)", rl.router_decision_cost_usd),
        baseline_cost: fragment("COALESCE(SUM(?), 0)", rl.router_baseline_cost_usd),
        covered_rows:
          fragment("COUNT(*) FILTER (WHERE ? IS NOT NULL)", rl.router_baseline_cost_usd),
        covered_cost:
          fragment(
            "COALESCE(SUM(COALESCE(?, 0) + COALESCE(?, 0)) FILTER (WHERE ? IS NOT NULL), 0)",
            rl.provider_cost_usd,
            rl.router_decision_cost_usd,
            rl.router_baseline_cost_usd
          ),
        covered_tokens:
          fragment(
            "COALESCE(SUM(COALESCE(?, 0) + COALESCE(?, 0)) FILTER (WHERE ? IS NOT NULL), 0)::bigint",
            rl.prompt_tokens,
            rl.completion_tokens,
            rl.router_baseline_cost_usd
          ),
        escalation_count:
          fragment(
            "COUNT(*) FILTER (WHERE ? IS NOT NULL AND (COALESCE(?, 0) + COALESCE(?, 0)) > ?)",
            rl.router_baseline_cost_usd,
            rl.provider_cost_usd,
            rl.router_decision_cost_usd,
            rl.router_baseline_cost_usd
          ),
        escalation_excess:
          fragment(
            "COALESCE(SUM((COALESCE(?, 0) + COALESCE(?, 0)) - ?) FILTER (WHERE ? IS NOT NULL AND (COALESCE(?, 0) + COALESCE(?, 0)) > ?), 0)",
            rl.provider_cost_usd,
            rl.router_decision_cost_usd,
            rl.router_baseline_cost_usd,
            rl.router_baseline_cost_usd,
            rl.provider_cost_usd,
            rl.router_decision_cost_usd,
            rl.router_baseline_cost_usd
          ),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_read_tokens),
        prompt_tokens_saved:
          fragment("COALESCE(SUM(COALESCE(?, 0)), 0)::bigint", rl.prompt_tokens_saved_est),
        avg_decision_ms:
          fragment("AVG(?) FILTER (WHERE ? > 0)", rl.router_decision_ms, rl.router_decision_ms)
      })
      |> Repo.all(timeout: query_timeout())

    names = use_case_names()
    total_requests = Enum.reduce(rows, 0, &(&1.request_count + &2))

    rows
    |> Enum.map(fn row ->
      block = cost_block(row)
      tokens = row.prompt_tokens + row.completion_tokens

      Map.merge(block, %{
        use_case_key: row.use_case_key,
        use_case_name: Map.get(names, row.use_case_key),
        effort_tier: row.effort_tier,
        request_count: row.request_count,
        share_pct: percent(row.request_count, total_requests),
        cache_hit_count: row.cache_hit_count,
        cache_hit_pct: percent(row.cache_hit_count, row.request_count),
        cache_read_pct: percent(row.cache_read_tokens, row.prompt_tokens),
        error_count: row.error_count,
        error_rate_pct: percent(row.error_count, row.request_count),
        fallback_count: row.fallback_count,
        fallback_rate_pct: percent(row.fallback_count, row.request_count),
        escalation_count: row.escalation_count,
        escalation_pct: percent(row.escalation_count, row.covered_rows),
        escalation_cost_usd: money(decimal(row.escalation_excess)),
        prompt_tokens_saved_est: row.prompt_tokens_saved,
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        total_tokens: tokens,
        tokens_per_request: ratio(tokens, row.request_count),
        avg_decision_ms: float_or_nil(row.avg_decision_ms)
      })
    end)
    |> Enum.sort_by(&{-Decimal.to_float(&1.total_cost_usd), &1.use_case_key, &1.effort_tier})
  end

  # ---------------------------------------------------------------------
  # Model performance
  # ---------------------------------------------------------------------

  @doc """
  Per resolved model: throughput (`tokens_per_sec`), TTFT/latency p50 & p95,
  `$/1M tokens`, tokens per request and error/fallback rates.

  Two passes: aggregate by `(model_id, model_resolved)` inside, join
  `models` outside for the display name (`model_resolved` is the fallback
  when the catalog row is gone).
  """
  def model_performance(filters \\ []) do
    filters = window!(filters, "SmartRouter.Analytics.model_performance/1")

    buckets =
      filters
      |> routed_query()
      |> group_by([rl], [rl.model_id, rl.model_resolved])
      |> select([rl], %{
        model_id: rl.model_id,
        model_resolved: rl.model_resolved,
        request_count: count(rl.id),
        error_count: fragment("COUNT(*) FILTER (WHERE COALESCE(?, 0) >= 400)", rl.status_code),
        fallback_count:
          fragment(
            "COUNT(*) FILTER (WHERE ? IN ('fallback_timeout', 'fallback_error'))",
            rl.router_decision_source
          ),
        served_cost: fragment("COALESCE(SUM(COALESCE(?, 0)), 0)", rl.provider_cost_usd),
        decision_cost: fragment("COALESCE(SUM(COALESCE(?, 0)), 0)", rl.router_decision_cost_usd),
        baseline_cost: fragment("COALESCE(SUM(?), 0)", rl.router_baseline_cost_usd),
        covered_rows:
          fragment("COUNT(*) FILTER (WHERE ? IS NOT NULL)", rl.router_baseline_cost_usd),
        covered_cost:
          fragment(
            "COALESCE(SUM(COALESCE(?, 0) + COALESCE(?, 0)) FILTER (WHERE ? IS NOT NULL), 0)",
            rl.provider_cost_usd,
            rl.router_decision_cost_usd,
            rl.router_baseline_cost_usd
          ),
        covered_tokens:
          fragment(
            "COALESCE(SUM(COALESCE(?, 0) + COALESCE(?, 0)) FILTER (WHERE ? IS NOT NULL), 0)::bigint",
            rl.prompt_tokens,
            rl.completion_tokens,
            rl.router_baseline_cost_usd
          ),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_read_tokens),
        prompt_tokens_saved:
          fragment("COALESCE(SUM(COALESCE(?, 0)), 0)::bigint", rl.prompt_tokens_saved_est),
        # Generation window only: tokens/sec must not be diluted by the queue
        # and TTFT. Same rows on both sides of the ratio.
        gen_tokens:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE ? > 0), 0)::bigint",
            rl.completion_tokens,
            rl.latency_ms
          ),
        gen_window_ms:
          fragment(
            "COALESCE(SUM(GREATEST(COALESCE(?, 0) - COALESCE(?, 0), 1)) FILTER (WHERE ? > 0), 0)::bigint",
            rl.latency_ms,
            rl.ttft_ms,
            rl.latency_ms
          ),
        latency_p50_ms:
          fragment(
            "percentile_cont(0.5) WITHIN GROUP (ORDER BY ?) FILTER (WHERE ? > 0)",
            rl.latency_ms,
            rl.latency_ms
          ),
        latency_p95_ms:
          fragment(
            "percentile_cont(0.95) WITHIN GROUP (ORDER BY ?) FILTER (WHERE ? > 0)",
            rl.latency_ms,
            rl.latency_ms
          ),
        ttft_p50_ms:
          fragment(
            "percentile_cont(0.5) WITHIN GROUP (ORDER BY ?) FILTER (WHERE ? > 0)",
            rl.ttft_ms,
            rl.ttft_ms
          ),
        ttft_p95_ms:
          fragment(
            "percentile_cont(0.95) WITHIN GROUP (ORDER BY ?) FILTER (WHERE ? > 0)",
            rl.ttft_ms,
            rl.ttft_ms
          )
      })
      |> subquery()

    from(b in buckets,
      left_join: m in Model,
      on: b.model_id == m.id,
      select: %{
        model_id: b.model_id,
        model_name: fragment("COALESCE(?, ?)", m.name, b.model_resolved),
        model_resolved: b.model_resolved,
        request_count: b.request_count,
        error_count: b.error_count,
        fallback_count: b.fallback_count,
        served_cost: b.served_cost,
        decision_cost: b.decision_cost,
        baseline_cost: b.baseline_cost,
        covered_rows: b.covered_rows,
        covered_cost: b.covered_cost,
        covered_tokens: b.covered_tokens,
        prompt_tokens: b.prompt_tokens,
        completion_tokens: b.completion_tokens,
        cache_read_tokens: b.cache_read_tokens,
        prompt_tokens_saved: b.prompt_tokens_saved,
        gen_tokens: b.gen_tokens,
        gen_window_ms: b.gen_window_ms,
        latency_p50_ms: b.latency_p50_ms,
        latency_p95_ms: b.latency_p95_ms,
        ttft_p50_ms: b.ttft_p50_ms,
        ttft_p95_ms: b.ttft_p95_ms
      }
    )
    |> Repo.all(timeout: query_timeout())
    |> Enum.map(fn row ->
      block = cost_block(row)
      tokens = row.prompt_tokens + row.completion_tokens

      Map.merge(block, %{
        model_id: row.model_id,
        model_name: row.model_name || row.model_resolved || "—",
        model_resolved: row.model_resolved,
        request_count: row.request_count,
        error_count: row.error_count,
        error_rate_pct: percent(row.error_count, row.request_count),
        fallback_count: row.fallback_count,
        fallback_rate_pct: percent(row.fallback_count, row.request_count),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        total_tokens: tokens,
        tokens_per_request: ratio(tokens, row.request_count),
        cache_read_pct: percent(row.cache_read_tokens, row.prompt_tokens),
        prompt_tokens_saved_est: row.prompt_tokens_saved,
        tokens_per_sec:
          ratio(row.gen_tokens, row.gen_window_ms)
          |> case do
            nil -> nil
            tokens_per_ms -> Float.round(tokens_per_ms * 1_000, 2)
          end,
        latency_p50_ms: float_or_nil(row.latency_p50_ms),
        latency_p95_ms: float_or_nil(row.latency_p95_ms),
        ttft_p50_ms: float_or_nil(row.ttft_p50_ms),
        ttft_p95_ms: float_or_nil(row.ttft_p95_ms)
      })
    end)
    |> Enum.sort_by(&{-Decimal.to_float(&1.total_cost_usd), &1.model_name})
  end

  # ---------------------------------------------------------------------
  # Router vs direct, per subject
  # ---------------------------------------------------------------------

  @doc """
  Router-vs-direct comparison per subject (user or service), split again by
  the membership the traffic was logged under.

  The direct half is the subject's own non-routed traffic in the same bound
  window, so the comparison answers "what did the router actually change for
  this subject". Router-dimension filters (`:router_use_case_key`,
  `:router_effort_tier`, `:router_decision_source`) are ignored here — a
  direct row has no decision source, and filtering by one would erase the
  whole direct column.

  Each row carries `router` and `direct` maps (`request_count`, `cost_usd`,
  `usd_per_request`, `usd_per_1m_tokens`, `tokens_per_request`,
  `cache_read_pct`) plus `usd_per_1m_delta_pct` (router relative to direct;
  negative = the router is cheaper) — `nil` whenever either side is empty.

  The routed half is NET: `provider_cost_usd + router_decision_cost_usd`, so
  the comparison prices the decision step instead of hiding it in the
  baseline. Classifier-billed `request_type == "router_decision"` rows are
  excluded (they are not served traffic) and subjects with no routed traffic
  are dropped: a direct-only subject has no router side to compare.
  """
  def router_vs_direct_by_subject(filters \\ []) do
    filters = window!(filters, "SmartRouter.Analytics.router_vs_direct_by_subject/1")

    buckets =
      RequestLog
      |> bound_query(filters)
      |> where([rl], rl.request_type != "router_decision")
      |> subject_filters(filters, router_dimensions?: false)
      |> group_by([rl], [
        rl.subject_type,
        rl.user_id,
        rl.service_id,
        rl.group_member_id,
        rl.routed_via_router
      ])
      |> select([rl], %{
        subject_type: rl.subject_type,
        user_id: rl.user_id,
        service_id: rl.service_id,
        group_member_id: rl.group_member_id,
        routed: rl.routed_via_router,
        request_count: count(rl.id),
        error_count: fragment("COUNT(*) FILTER (WHERE COALESCE(?, 0) >= 400)", rl.status_code),
        fallback_count:
          fragment(
            "COUNT(*) FILTER (WHERE ? IN ('fallback_timeout', 'fallback_error'))",
            rl.router_decision_source
          ),
        cost: fragment("COALESCE(SUM(COALESCE(?, 0)), 0)", rl.provider_cost_usd),
        decision_cost: fragment("COALESCE(SUM(COALESCE(?, 0)), 0)", rl.router_decision_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_read_tokens),
        prompt_tokens_saved:
          fragment("COALESCE(SUM(COALESCE(?, 0)), 0)::bigint", rl.prompt_tokens_saved_est)
      })
      |> subquery()

    rows =
      from(b in buckets,
        left_join: u in User,
        on: b.user_id == u.id,
        left_join: s in Service,
        on: b.service_id == s.id,
        left_join: tm in GroupMember,
        on: b.group_member_id == tm.id,
        left_join: g in assoc(tm, :group),
        select: %{
          subject_type: b.subject_type,
          user_id: b.user_id,
          user_name: u.name,
          user_email: u.email,
          service_id: b.service_id,
          service_name: s.name,
          group_member_id: b.group_member_id,
          group_name: g.name,
          routed: b.routed,
          request_count: b.request_count,
          error_count: b.error_count,
          fallback_count: b.fallback_count,
          cost: b.cost,
          decision_cost: b.decision_cost,
          prompt_tokens: b.prompt_tokens,
          completion_tokens: b.completion_tokens,
          cache_read_tokens: b.cache_read_tokens,
          prompt_tokens_saved: b.prompt_tokens_saved
        }
      )
      |> Repo.all(timeout: query_timeout())

    rows
    |> Enum.group_by(&{&1.subject_type, &1.user_id, &1.service_id, &1.group_member_id})
    |> Enum.map(fn {_key, [first | _] = entries} ->
      router = entries |> Enum.find(& &1.routed) |> subject_stats()
      direct = entries |> Enum.find(&(not &1.routed)) |> subject_stats()

      %{
        subject_type: first.subject_type,
        subject_id: first.user_id || first.service_id,
        subject_name: subject_label(first),
        group_member_id: first.group_member_id,
        group_name: first.group_name,
        router: router,
        direct: direct,
        usd_per_1m_delta_pct:
          delta_pct(get_in(router, [:usd_per_1m_tokens]), get_in(direct, [:usd_per_1m_tokens]))
      }
    end)
    # A direct-only subject has nothing to compare against: the router column
    # would be a zero row pretending to be a measurement.
    |> Enum.reject(&(&1.router.request_count == 0))
    |> Enum.sort_by(&{-Decimal.to_float(&1.router.cost_usd), &1.subject_name})
  end

  # ---------------------------------------------------------------------
  # Attribution: who spent on what
  # ---------------------------------------------------------------------

  @doc """
  Subject × resolved model matrix: who spent on what, separating traffic the
  subject could reach directly (`direct_access = true`) from traffic that only
  exists because of the router (`direct_access = false`, i.e.
  `router_direct_access = false` — the model is outside their direct ACL).

  Two passes: aggregate by `(subject, membership, model, direct_access)`
  inside on raw ids, join `users`/`services`/`group_members`/`groups`/`models`
  outside. `last_seen_at` is the newest row of the group, so a stale lane is
  visible without a second query. `direct_access: nil` means the row never
  recorded the flag (unknown, e.g. written before the column existed).
  """
  def who_spent_on_what(filters \\ []) do
    filters = window!(filters, "SmartRouter.Analytics.who_spent_on_what/1")

    buckets =
      filters
      |> routed_query()
      |> group_by([rl], [
        rl.subject_type,
        rl.user_id,
        rl.service_id,
        rl.group_member_id,
        rl.model_id,
        rl.router_direct_access
      ])
      |> select([rl], %{
        subject_type: rl.subject_type,
        user_id: rl.user_id,
        service_id: rl.service_id,
        group_member_id: rl.group_member_id,
        model_id: rl.model_id,
        model_resolved: fragment("MAX(?)", rl.model_resolved),
        direct_access: rl.router_direct_access,
        request_count: count(rl.id),
        cost: fragment("COALESCE(SUM(COALESCE(?, 0)), 0)", rl.provider_cost_usd),
        decision_cost: fragment("COALESCE(SUM(COALESCE(?, 0)), 0)", rl.router_decision_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_read_tokens),
        prompt_tokens_saved:
          fragment("COALESCE(SUM(COALESCE(?, 0)), 0)::bigint", rl.prompt_tokens_saved_est),
        last_seen_at: fragment("MAX(?)", rl.inserted_at)
      })
      |> subquery()

    from(b in buckets,
      left_join: u in User,
      on: b.user_id == u.id,
      left_join: s in Service,
      on: b.service_id == s.id,
      left_join: tm in GroupMember,
      on: b.group_member_id == tm.id,
      left_join: g in assoc(tm, :group),
      left_join: m in Model,
      on: b.model_id == m.id,
      select: %{
        subject_type: b.subject_type,
        user_id: b.user_id,
        user_name: u.name,
        user_email: u.email,
        service_id: b.service_id,
        service_name: s.name,
        group_name: g.name,
        model_id: b.model_id,
        model_name: fragment("COALESCE(?, ?)", m.name, b.model_resolved),
        model_resolved: b.model_resolved,
        direct_access: b.direct_access,
        request_count: b.request_count,
        cost: b.cost,
        decision_cost: b.decision_cost,
        prompt_tokens: b.prompt_tokens,
        completion_tokens: b.completion_tokens,
        cache_read_tokens: b.cache_read_tokens,
        prompt_tokens_saved: b.prompt_tokens_saved,
        last_seen_at: b.last_seen_at
      }
    )
    |> Repo.all(timeout: query_timeout())
    |> Enum.map(fn row ->
      tokens = row.prompt_tokens + row.completion_tokens
      total_cost = Decimal.add(decimal(row.cost), decimal(row.decision_cost))

      %{
        subject_type: row.subject_type,
        subject_id: row.user_id || row.service_id,
        subject_name: subject_label(row),
        group_name: row.group_name,
        model_id: row.model_id,
        model_name: row.model_name || row.model_resolved || "—",
        model_resolved: row.model_resolved,
        direct_access: row.direct_access,
        request_count: row.request_count,
        cost_usd: money(total_cost),
        served_cost_usd: money(decimal(row.cost)),
        decision_cost_usd: money(decimal(row.decision_cost)),
        total_tokens: tokens,
        tokens_per_request: ratio(tokens, row.request_count),
        usd_per_1m_tokens: rate(total_cost, tokens, 1_000_000),
        cache_read_pct: percent(row.cache_read_tokens, row.prompt_tokens),
        prompt_tokens_saved_est: row.prompt_tokens_saved,
        last_seen_at: utc_datetime(row.last_seen_at)
      }
    end)
    |> Enum.sort_by(&{-Decimal.to_float(&1.cost_usd), &1.subject_name, &1.model_name})
  end

  # ---------------------------------------------------------------------
  # Shadow versions (router_shadow_evaluations)
  # ---------------------------------------------------------------------

  @doc """
  Default-vs-Shadow comparison, one row per Shadow version, over the window
  bounded on `request_inserted_at`.

  ## Row shape

    * `shadow_config_id`, `shadow_config_name` — the version under evaluation
      (the name is the denormalised one written by the evaluator, `MAX` over
      the group, so a rename never splits the series). `shadow_enabled` /
      `archived_at` / `archived` are the version's **current** state, read
      through a left join to `router_configs`; they are `nil`/`false` only if
      the version row was deleted.
    * `eval_count` = all evaluations, `ok_count` = `error_reason IS NULL`,
      `error_count` = `error_reason IS NOT NULL`. Agreements divide by
      `ok_count`, never by `eval_count`.
    * `matches_model_count` / `matches_tier_count` — agreeing ok rows.
      `agreement_pct` / `tier_agreement_pct` are `nil` when `ok_count == 0`.
    * `downgrade_count` / `upgrade_count` — ok rows where the Shadow tier is
      below / above the Default tier on the `low < medium < high` order. A
      `nil` tier on either side is neither (it is unknown, not equal).
    * `priced_count` / `coverage_pct` — ok rows that carry an estimated price,
      and their share of `ok_count`. An unpriced row is counted in volume but
      excluded from the money block: coverage is stated next to the number it
      decorates.
    * `default_served_cost_usd` — the Default's real cost over the **same
      priced ok rows** (apple to apple), never over the whole window.
    * `shadow_estimated_cost_usd` — the priced destinations' estimated cost
      over the same priced ok rows; `shadow_decision_cost_usd` — the Shadow
      classifier's own cost **restricted to those same priced ok rows**, so the
      delta never adds a classifier price to a Default cost that was not
      counted; `shadow_total_cost_usd` = both summed.
    * `estimated_delta_usd` = `shadow_total - default_served`, **never
      clipped**: negative = estimated saving, positive = estimated premium.
      `estimated_delta_pct` is `nil` when nothing was priced.
    * `prompt_tokens_saved_est` — the Shadow's trimming would have saved this
      many prompt tokens.

  Sorted by `eval_count` descending.
  """
  def shadow_comparison(filters \\ []) do
    filters = window!(filters, "Tokengate.SmartRouter.Analytics.shadow_comparison/1")

    rows =
      from(se in ShadowEvaluation,
        left_join: c in RouterConfig,
        on: c.id == se.shadow_config_id,
        where: se.request_inserted_at >= ^filters.from,
        group_by: [se.shadow_config_id, c.shadow_enabled, c.archived_at],
        select: %{
          shadow_config_id: se.shadow_config_id,
          shadow_config_name: fragment("MAX(?)", se.shadow_config_name),
          shadow_enabled: c.shadow_enabled,
          archived_at: c.archived_at,
          eval_count: count(se.id),
          ok_count: fragment("COUNT(*) FILTER (WHERE ? IS NULL)", se.error_reason),
          error_count: fragment("COUNT(*) FILTER (WHERE ? IS NOT NULL)", se.error_reason),
          matches_model_count:
            fragment(
              "COUNT(*) FILTER (WHERE ? AND ? IS NULL)",
              se.matches_default_model,
              se.error_reason
            ),
          matches_tier_count:
            fragment(
              "COUNT(*) FILTER (WHERE ? AND ? IS NULL)",
              se.matches_default_tier,
              se.error_reason
            ),
          downgrade_count:
            fragment(
              """
              COUNT(*) FILTER (
                WHERE ? IS NULL
                  AND CASE ? WHEN 'low' THEN 1 WHEN 'medium' THEN 2 WHEN 'high' THEN 3 END
                    < CASE ? WHEN 'low' THEN 1 WHEN 'medium' THEN 2 WHEN 'high' THEN 3 END
              )
              """,
              se.error_reason,
              se.effort_tier,
              se.default_effort_tier
            ),
          upgrade_count:
            fragment(
              """
              COUNT(*) FILTER (
                WHERE ? IS NULL
                  AND CASE ? WHEN 'low' THEN 1 WHEN 'medium' THEN 2 WHEN 'high' THEN 3 END
                    > CASE ? WHEN 'low' THEN 1 WHEN 'medium' THEN 2 WHEN 'high' THEN 3 END
              )
              """,
              se.error_reason,
              se.effort_tier,
              se.default_effort_tier
            ),
          priced_count:
            fragment(
              "COUNT(*) FILTER (WHERE ? IS NOT NULL AND ? IS NULL)",
              se.estimated_served_cost_usd,
              se.error_reason
            ),
          default_served_cost:
            fragment(
              "COALESCE(SUM(COALESCE(?, 0)) FILTER (WHERE ? IS NOT NULL AND ? IS NULL), 0)",
              se.default_served_cost_usd,
              se.estimated_served_cost_usd,
              se.error_reason
            ),
          shadow_estimated_cost:
            fragment(
              "COALESCE(SUM(COALESCE(?, 0)) FILTER (WHERE ? IS NULL), 0)",
              se.estimated_served_cost_usd,
              se.error_reason
            ),
          # Same priced-ok row set as `default_served_cost` / the estimated
          # cost: an error row or an unpriced row has no Default cost to
          # compare against, so its classifier price must not enter the delta.
          shadow_decision_cost:
            fragment(
              "COALESCE(SUM(COALESCE(?, 0)) FILTER (WHERE ? IS NOT NULL AND ? IS NULL), 0)",
              se.decision_cost_usd,
              se.estimated_served_cost_usd,
              se.error_reason
            ),
          prompt_tokens_saved:
            fragment("COALESCE(SUM(COALESCE(?, 0)), 0)::bigint", se.prompt_tokens_saved_est)
        }
      )
      |> maybe_eq(:shadow_config_id, filters[:shadow_config_id])
      |> maybe_eq(:default_config_id, filters[:default_config_id])
      |> shadow_maybe_to(filters.to)
      |> Repo.all(timeout: query_timeout())

    rows
    |> Enum.map(fn row ->
      default_served = decimal(row.default_served_cost)
      shadow_estimated = decimal(row.shadow_estimated_cost)
      shadow_decision = decimal(row.shadow_decision_cost)
      shadow_total = Decimal.add(shadow_estimated, shadow_decision)
      delta = Decimal.sub(shadow_total, default_served)

      %{
        shadow_config_id: row.shadow_config_id,
        shadow_config_name: row.shadow_config_name,
        shadow_enabled: row.shadow_enabled == true,
        archived_at: utc_datetime(row.archived_at),
        archived: not is_nil(row.archived_at),
        eval_count: row.eval_count,
        ok_count: row.ok_count,
        error_count: row.error_count,
        matches_model_count: row.matches_model_count,
        matches_tier_count: row.matches_tier_count,
        agreement_pct: percent(row.matches_model_count, row.ok_count),
        tier_agreement_pct: percent(row.matches_tier_count, row.ok_count),
        downgrade_count: row.downgrade_count,
        upgrade_count: row.upgrade_count,
        priced_count: row.priced_count,
        coverage_pct: percent(row.priced_count, row.ok_count),
        default_served_cost_usd: money(default_served),
        shadow_estimated_cost_usd: money(shadow_estimated),
        shadow_decision_cost_usd: money(shadow_decision),
        shadow_total_cost_usd: money(shadow_total),
        estimated_delta_usd: money(delta),
        estimated_delta_pct: percent_of(delta, default_served),
        prompt_tokens_saved_est: row.prompt_tokens_saved
      }
    end)
    |> Enum.sort_by(&{-&1.eval_count, &1.shadow_config_name})
  end

  @doc """
  The rows behind one Shadow version's disagreement: ok evaluations where the
  Shadow did **not** match the Default's model or tier, grouped by the exact
  `(use_case_key, default_use_case_key, default_model_name, model_name,
  default_effort_tier, effort_tier)` migration they represent.

  Each row carries `eval_count`, `priced_count`, `default_served_cost_usd`
  (Default cost over the priced rows of the group), `shadow_estimated_cost_usd`,
  `shadow_decision_cost_usd`, `shadow_total_cost_usd`, `estimated_delta_usd`,
  `estimated_delta_pct` and `prompt_tokens_saved_est` — same honest money
  contract as `shadow_comparison/1`, at the migration level.

  Sorted by absolute impact (`abs(estimated_delta_usd)`) descending, then by
  volume, so the migration that moves the most money is first.
  """
  def shadow_migrations(shadow_config_id, filters \\ []) do
    filters = window!(filters, "Tokengate.SmartRouter.Analytics.shadow_migrations/2")

    rows =
      from(se in ShadowEvaluation,
        where: se.shadow_config_id == ^shadow_config_id,
        where: se.request_inserted_at >= ^filters.from,
        where: is_nil(se.error_reason),
        where: not se.matches_default_model or not se.matches_default_tier,
        group_by: [
          se.use_case_key,
          se.default_use_case_key,
          se.default_model_name,
          se.model_name,
          se.default_effort_tier,
          se.effort_tier
        ],
        select: %{
          use_case_key: se.use_case_key,
          default_use_case_key: se.default_use_case_key,
          default_model_name: se.default_model_name,
          model_name: se.model_name,
          default_effort_tier: se.default_effort_tier,
          effort_tier: se.effort_tier,
          eval_count: count(se.id),
          priced_count:
            fragment("COUNT(*) FILTER (WHERE ? IS NOT NULL)", se.estimated_served_cost_usd),
          default_served_cost:
            fragment(
              "COALESCE(SUM(COALESCE(?, 0)) FILTER (WHERE ? IS NOT NULL), 0)",
              se.default_served_cost_usd,
              se.estimated_served_cost_usd
            ),
          shadow_estimated_cost:
            fragment(
              "COALESCE(SUM(COALESCE(?, 0)) FILTER (WHERE ? IS NULL), 0)",
              se.estimated_served_cost_usd,
              se.error_reason
            ),
          # Only the priced-ok rows carry a Default cost, so only their
          # classifier price may enter `estimated_delta_usd` (apple to apple).
          shadow_decision_cost:
            fragment(
              "COALESCE(SUM(COALESCE(?, 0)) FILTER (WHERE ? IS NOT NULL AND ? IS NULL), 0)",
              se.decision_cost_usd,
              se.estimated_served_cost_usd,
              se.error_reason
            ),
          prompt_tokens_saved:
            fragment("COALESCE(SUM(COALESCE(?, 0)), 0)::bigint", se.prompt_tokens_saved_est)
        }
      )
      |> shadow_maybe_to(filters.to)
      |> Repo.all(timeout: query_timeout())

    rows
    |> Enum.map(fn row ->
      default_served = decimal(row.default_served_cost)
      shadow_estimated = decimal(row.shadow_estimated_cost)
      shadow_decision = decimal(row.shadow_decision_cost)
      shadow_total = Decimal.add(shadow_estimated, shadow_decision)
      delta = Decimal.sub(shadow_total, default_served)

      %{
        use_case_key: row.use_case_key,
        default_use_case_key: row.default_use_case_key,
        default_model_name: row.default_model_name,
        model_name: row.model_name,
        default_effort_tier: row.default_effort_tier,
        effort_tier: row.effort_tier,
        eval_count: row.eval_count,
        priced_count: row.priced_count,
        default_served_cost_usd: money(default_served),
        shadow_estimated_cost_usd: money(shadow_estimated),
        shadow_decision_cost_usd: money(shadow_decision),
        shadow_total_cost_usd: money(shadow_total),
        estimated_delta_usd: money(delta),
        estimated_delta_pct: percent_of(delta, default_served),
        prompt_tokens_saved_est: row.prompt_tokens_saved
      }
    end)
    |> Enum.sort_by(&{-absolute(&1.estimated_delta_usd), -&1.eval_count})
  end

  @doc """
  The Shadow evaluations of a batch of `request_logs` rows, keyed by
  `request_log_id` — the per-request Default-vs-Shadow detail.

  Accepts log ids or `{log_id, inserted_at}` pairs. When pairs are present the
  read is additionally bounded by `[min(inserted_at), max(inserted_at)]` on
  `request_inserted_at`, so it can lean on
  `router_shadow_evaluations_request_index` (`(request_log_id,
  request_inserted_at)`) instead of scanning the whole history of those ids.
  This read is keyed by exact ids, so it is already bounded and does **not**
  need `Logs.ensure_window!/2`.

  Returns `%{}` for an empty input — no query. Otherwise
  `%{request_log_id => [%ShadowEvaluation{}, ...]}`, each list ordered by
  `shadow_config_name` ascending (the version switcher's own order).
  """
  def shadow_for_logs(log_refs) when is_list(log_refs) do
    {ids, times} = split_log_refs(log_refs)

    if ids == [] do
      %{}
    else
      bounds = time_bounds(times)

      from(se in ShadowEvaluation,
        where: se.request_log_id in ^ids,
        order_by: [asc: se.shadow_config_name, asc: se.inserted_at]
      )
      |> shadow_maybe_bounds(bounds)
      |> Repo.all(timeout: query_timeout())
      |> Enum.group_by(& &1.request_log_id)
    end
  end

  # ---------------------------------------------------------------------
  # False-savings signals
  # ---------------------------------------------------------------------

  @doc """
  Traffic-light health checks that catch savings that are not savings:

    * `session_switch_rate_pct` — % of sessions (`session_id` persisted) whose
      model changed mid-session. A switch invalidates the upstream prompt
      cache and breaks `reasoning_content` inside a tool loop, so a high rate
      can eat the entire model-selection saving.
    * `avg_turns_per_session` — how much evidence the switch rate rests on.
    * `cache_read_pct` — prompt-cache reuse (`cache_read_tokens / prompt_tokens`).
      Savings obtained by losing cache reuse are not savings.
    * `classifier_cost_share_pct` — the classifier's own cost over total spend
      (served + decision).
    * `fallback_rate_pct` — decisions that never landed.

  `session_coverage_pct` says what share of routed rows actually carried a
  `session_id`, so an under-populated session column cannot masquerade as
  "no switches". Returns the numbers plus a `signals` list
  (`%{key, level, value, warn_at, critical_at, direction, message}`) and the
  worst `status` (`:ok | :warning | :critical`, `:unknown` signals are
  ignored).
  """
  def false_savings_signals(filters \\ []) do
    filters = window!(filters, "SmartRouter.Analytics.false_savings_signals/1")

    totals =
      filters
      |> routed_query()
      |> select([rl], %{
        request_count: count(rl.id),
        session_rows: fragment("COUNT(*) FILTER (WHERE ? IS NOT NULL)", rl.session_id),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.prompt_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_read_tokens),
        served_cost: fragment("COALESCE(SUM(COALESCE(?, 0)), 0)", rl.provider_cost_usd),
        decision_cost: fragment("COALESCE(SUM(COALESCE(?, 0)), 0)", rl.router_decision_cost_usd),
        classifier_cost:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE ? = 'classifier'), 0)",
            rl.router_decision_cost_usd,
            rl.router_decision_source
          ),
        fallback_count:
          fragment(
            "COUNT(*) FILTER (WHERE ? IN ('fallback_timeout', 'fallback_error'))",
            rl.router_decision_source
          ),
        error_count: fragment("COUNT(*) FILTER (WHERE COALESCE(?, 0) >= 400)", rl.status_code),
        prompt_tokens_saved:
          fragment("COALESCE(SUM(COALESCE(?, 0)), 0)::bigint", rl.prompt_tokens_saved_est)
      })
      |> Repo.one(timeout: query_timeout())

    sessions =
      filters
      |> routed_query()
      |> where([rl], not is_nil(rl.session_id))
      |> group_by([rl], rl.session_id)
      |> select([rl], %{
        session_id: rl.session_id,
        turns: count(rl.id),
        models: fragment("COUNT(DISTINCT ?)", rl.model_id)
      })
      |> subquery()
      |> then(fn q ->
        from(s in q,
          select: %{
            session_count: count(s.session_id),
            switched_sessions: fragment("COUNT(*) FILTER (WHERE ? > 1)", s.models),
            turns_total: fragment("COALESCE(SUM(?), 0)::bigint", s.turns)
          }
        )
      end)
      |> Repo.one(timeout: query_timeout())

    switch_rate = percent(sessions.switched_sessions, sessions.session_count)
    avg_turns = ratio(sessions.turns_total, sessions.session_count)
    cache_read_pct = percent(totals.cache_read_tokens, totals.prompt_tokens)
    total_cost = Decimal.add(decimal(totals.served_cost), decimal(totals.decision_cost))
    classifier_share = percent_of(decimal(totals.classifier_cost), total_cost)
    fallback_rate = percent(totals.fallback_count, totals.request_count)

    signals = [
      signal(
        :session_switches,
        switch_rate,
        @switch_warn_pct,
        @switch_crit_pct,
        :above,
        "Model changes inside a session invalidate the prompt cache and can erase the routing saving."
      ),
      signal(
        :classifier_overhead,
        classifier_share,
        @classifier_share_warn_pct,
        @classifier_share_crit_pct,
        :above,
        "The classifier's own cost is a large share of total routed spend."
      ),
      signal(
        :cache_read,
        cache_read_pct,
        @cache_read_warn_pct,
        @cache_read_crit_pct,
        :below,
        "Low prompt-cache reuse: reported savings may be paying for cache misses."
      ),
      signal(
        :fallback_rate,
        fallback_rate,
        @fallback_warn_pct,
        @fallback_crit_pct,
        :above,
        "Many decisions fell back before landing; the saving claimed was never really selected."
      )
    ]

    %{
      request_count: totals.request_count,
      session_coverage_pct: percent(totals.session_rows, totals.request_count),
      sessions_count: sessions.session_count,
      sessions_with_switch: sessions.switched_sessions,
      session_switch_rate_pct: switch_rate,
      avg_turns_per_session: avg_turns,
      cache_read_pct: cache_read_pct,
      prompt_tokens: totals.prompt_tokens,
      prompt_tokens_saved_est: totals.prompt_tokens_saved,
      fallback_count: totals.fallback_count,
      fallback_rate_pct: fallback_rate,
      error_count: totals.error_count,
      error_rate_pct: percent(totals.error_count, totals.request_count),
      served_plus_decision_usd: money(total_cost),
      classifier_cost_usd: money(decimal(totals.classifier_cost)),
      classifier_cost_share_pct: classifier_share,
      signals: signals,
      status: worst_status(signals)
    }
  end

  @doc """
  Deterministic business recommendations derived from thresholds — no LLM,
  no invented numbers: every insight is computed from `summary/1`,
  `false_savings_signals/1` and `use_case_breakdown/1` over the same window.

  Returns a list of `%{key, level, title, detail, metric}` sorted by severity
  (`:critical` first), so the UI can render the most actionable item on top.
  """
  def decision_insights(filters \\ []) do
    filters = window!(filters, "SmartRouter.Analytics.decision_insights/1")

    decision_insights_from(
      summary(filters),
      false_savings_signals(filters),
      use_case_breakdown(filters)
    )
  end

  @doc """
  The same insights derived from three reads the caller already has.

  A page that already renders the KPIs, the false-savings traffic light and
  the use-case mix has paid for those three scans; this entry point turns
  them into recommendations without re-running any of them (they are the
  heaviest reads in this module).
  """
  def decision_insights_from(summary, signals, use_cases) do
    [
      savings_insight(summary),
      coverage_insight(summary),
      switch_insight(signals),
      classifier_insight(summary, signals),
      cache_insight(signals),
      fallback_insight(signals),
      concentration_insight(use_cases, summary),
      trim_insight(summary),
      empty_insight(summary)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&severity_rank(&1.level))
  end

  # ---------------------------------------------------------------------
  # Insights (private)
  # ---------------------------------------------------------------------

  defp savings_insight(%{request_count: 0}), do: nil

  defp savings_insight(%{net_savings_usd: net} = summary) do
    cond do
      Decimal.negative?(net) ->
        %{
          key: :negative_net_savings,
          level: :critical,
          title: "The router is more expensive than the baseline",
          detail:
            "Net savings are #{money(net)} USD over #{summary.baseline_request_count} priced requests: " <>
              "the routed model plus the decision step cost more than the baseline lane.",
          metric: %{net_savings_usd: net, savings_pct: summary.savings_pct}
        }

      Decimal.positive?(net) ->
        %{
          key: :net_savings,
          level: :ok,
          title: "Router saves money over the baseline",
          detail:
            "#{money(net)} USD net (#{fmt_pct(summary.savings_pct)}) over the priced window, " <>
              "including the decision step's own cost.",
          metric: %{net_savings_usd: net, savings_pct: summary.savings_pct}
        }

      true ->
        nil
    end
  end

  defp coverage_insight(%{request_count: 0}), do: nil

  defp coverage_insight(%{baseline_coverage_pct: coverage} = summary) do
    cond do
      coverage == 0.0 ->
        %{
          key: :no_baseline,
          level: :critical,
          title: "No baseline price: savings cannot be measured",
          detail:
            "None of the routed requests carried router_baseline_cost_usd. Price the baseline lane " <>
              "(router_configs.baseline_model_id) or savings stay unmeasurable.",
          metric: %{baseline_coverage_pct: coverage}
        }

      coverage < 90.0 ->
        %{
          key: :partial_baseline,
          level: :warning,
          title: "Baseline coverage is incomplete",
          detail:
            "#{fmt_pct(coverage)} of the routed requests carry a baseline price " <>
              "(#{summary.baseline_request_count} of #{summary.request_count}); net savings only " <>
              "describe those rows.",
          metric: %{baseline_coverage_pct: coverage}
        }

      true ->
        nil
    end
  end

  defp switch_insight(%{session_switch_rate_pct: rate, avg_turns_per_session: avg_turns})
       when is_float(rate) do
    if rate >= @switch_warn_pct do
      %{
        key: :session_switches,
        level: if(rate >= @switch_crit_pct, do: :critical, else: :warning),
        title: "Models change inside sessions",
        detail:
          "#{fmt_pct(rate)} of sessions switched model mid-session (avg #{fmt_num(avg_turns)} " <>
            "turns per session). Keep `pin_session` on long use cases so the prompt cache " <>
            "survives the task.",
        metric: %{session_switch_rate_pct: rate, avg_turns_per_session: avg_turns}
      }
    end
  end

  defp switch_insight(_), do: nil

  defp classifier_insight(%{request_count: 0}, _signals), do: nil

  defp classifier_insight(summary, %{classifier_cost_share_pct: share}) when is_float(share) do
    if share >= @classifier_share_warn_pct do
      %{
        key: :classifier_overhead,
        level: if(share >= @classifier_share_crit_pct, do: :critical, else: :warning),
        title: "Classifier overhead is high",
        detail:
          "The decision step costs #{money(summary.classifier_cost_usd)} USD (#{fmt_pct(share)} of total). " <>
            "Prefer rules/fast-path for the frequent use cases and trim `decision_context_chars`.",
        metric: %{
          classifier_cost_share_pct: share,
          classifier_cost_usd: summary.classifier_cost_usd
        }
      }
    end
  end

  defp classifier_insight(_summary, _signals), do: nil

  defp cache_insight(%{cache_read_pct: pct}) when is_float(pct) do
    if pct < @cache_read_warn_pct do
      %{
        key: :cache_reuse,
        level: if(pct < @cache_read_crit_pct, do: :critical, else: :warning),
        title: "Prompt cache reuse is low",
        detail:
          "Only #{fmt_pct(pct)} of the prompt tokens were cache reads. Check the use case's " <>
            "history/image trimming and `pin_session`: trimming too aggressively trades cache hits " <>
            "for tokens and can invert the saving.",
        metric: %{cache_read_pct: pct}
      }
    end
  end

  defp cache_insight(_), do: nil

  defp fallback_insight(%{fallback_rate_pct: rate}) when is_float(rate) do
    if rate >= @fallback_warn_pct do
      %{
        key: :fallbacks,
        level: if(rate >= @fallback_crit_pct, do: :critical, else: :warning),
        title: "Many decisions fall back",
        detail:
          "#{fmt_pct(rate)} of the decisions ended in fallback_timeout/fallback_error. Raise " <>
            "`decision_timeout_ms` or register more candidates per effort tier before claiming " <>
            "the tier was served.",
        metric: %{fallback_rate_pct: rate}
      }
    end
  end

  defp fallback_insight(_), do: nil

  defp concentration_insight([], _summary), do: nil

  defp concentration_insight([top | _], %{served_plus_decision_usd: total}) do
    share = percent_of(top.total_cost_usd, total)

    if is_float(share) and share >= 50.0 do
      %{
        key: :spend_concentration,
        level: :info,
        title: "Spend is concentrated in one use case",
        detail:
          "#{fmt_pct(share)} of the routed spend is #{top.use_case_key}/#{top.effort_tier} " <>
            "(#{money(top.total_cost_usd)} USD over #{top.request_count} requests). It is the best " <>
            "place to tune prices and tiers first.",
        metric: %{use_case_key: top.use_case_key, effort_tier: top.effort_tier, share_pct: share}
      }
    end
  end

  defp trim_insight(%{prompt_tokens_saved_est: 0}), do: nil

  defp trim_insight(%{prompt_tokens_saved_est: saved, prompt_tokens: prompt}) do
    %{
      key: :prompt_trimming,
      level: :info,
      title: "Prompt trimming removed tokens",
      detail:
        "#{saved} prompt tokens were trimmed (over #{prompt + saved} before trimming). " <>
          "Watch model_performance/1: a cheap model whose prompt cache dies is not cheap.",
      metric: %{prompt_tokens_saved_est: saved}
    }
  end

  defp empty_insight(%{request_count: 0}) do
    %{
      key: :no_router_traffic,
      level: :info,
      title: "No routed traffic in this window",
      detail: "No request_logs row with routed_via_router = true falls in the selected window.",
      metric: %{}
    }
  end

  defp empty_insight(_summary), do: nil

  defp severity_rank(:critical), do: 0
  defp severity_rank(:warning), do: 1
  defp severity_rank(:info), do: 2
  defp severity_rank(:ok), do: 3

  # ---------------------------------------------------------------------
  # Cost block shared by the breakdowns
  # ---------------------------------------------------------------------

  # Every grouped query above selects the same six money/count columns; this
  # turns them into the honest savings block so the definition lives in ONE
  # place (and can never drift per breakdown).
  #
  # `usd_per_1m_tokens` is the group's OWN spend over its own tokens (no
  # baseline needed). The baseline and savings rates only exist for the priced
  # rows, so BOTH use `covered_tokens` (they are `nil` without coverage) and
  # are comparable to each other, never to the actual rate above.
  defp cost_block(row) do
    served = decimal(row.served_cost)
    decision = decimal(row.decision_cost)
    total_cost = Decimal.add(served, decision)
    baseline = decimal(row.baseline_cost)
    covered = decimal(row.covered_cost)
    net = Decimal.sub(baseline, covered)
    tokens = (row[:prompt_tokens] || 0) + (row[:completion_tokens] || 0)

    %{
      served_cost_usd: money(served),
      decision_cost_usd: money(decision),
      total_cost_usd: money(total_cost),
      baseline_cost_usd: money(baseline),
      baseline_request_count: row.covered_rows,
      baseline_coverage_pct: percent(row.covered_rows, row.request_count),
      net_savings_usd: money(net),
      savings_pct: percent_of(net, baseline),
      usd_per_1k_requests: rate(total_cost, row.request_count, 1_000),
      usd_per_1m_tokens: rate(total_cost, tokens, 1_000_000),
      baseline_usd_per_1m_tokens: rate(baseline, row.covered_tokens, 1_000_000),
      savings_usd_per_1m_tokens: rate(net, row.covered_tokens, 1_000_000)
    }
  end

  # ---------------------------------------------------------------------
  # Subject-relative stats (router vs direct)
  # ---------------------------------------------------------------------

  defp subject_stats(nil) do
    %{
      request_count: 0,
      cost_usd: money(Decimal.new(0)),
      served_cost_usd: money(Decimal.new(0)),
      decision_cost_usd: money(Decimal.new(0)),
      total_tokens: 0,
      usd_per_request: nil,
      usd_per_1k_requests: nil,
      usd_per_1m_tokens: nil,
      tokens_per_request: nil,
      cache_read_pct: nil,
      prompt_tokens_saved_est: 0,
      error_rate_pct: nil,
      fallback_rate_pct: nil
    }
  end

  # NET cost: the decision step is priced here too, or the router would look
  # cheaper than it is by the exact amount of the classifier it ran.
  defp subject_stats(row) do
    tokens = row.prompt_tokens + row.completion_tokens
    served = decimal(row.cost)
    decision = decimal(Map.get(row, :decision_cost))
    cost = Decimal.add(served, decision)

    %{
      request_count: row.request_count,
      cost_usd: money(cost),
      served_cost_usd: money(served),
      decision_cost_usd: money(decision),
      total_tokens: tokens,
      usd_per_request: ratio(Decimal.to_float(cost), row.request_count),
      usd_per_1k_requests: rate(cost, row.request_count, 1_000),
      usd_per_1m_tokens: rate(cost, tokens, 1_000_000),
      tokens_per_request: ratio(tokens, row.request_count),
      cache_read_pct: percent(row.cache_read_tokens, row.prompt_tokens),
      prompt_tokens_saved_est: row.prompt_tokens_saved,
      error_rate_pct: percent(row.error_count, row.request_count),
      fallback_rate_pct: percent(row.fallback_count, row.request_count)
    }
  end

  defp subject_label(%{subject_type: "service"} = row),
    do: row.service_name || "service #{short_id(row.service_id)}"

  defp subject_label(row),
    do: row.user_name || row.user_email || "user #{short_id(row.user_id)}"

  defp short_id(nil), do: "—"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  # ---------------------------------------------------------------------
  # Signals
  # ---------------------------------------------------------------------

  defp signal(key, nil, _warn, _crit, _direction, _message) do
    %{
      key: key,
      level: :unknown,
      value: nil,
      warn_at: nil,
      critical_at: nil,
      direction: nil,
      message: nil
    }
  end

  defp signal(key, value, warn, crit, direction, message) do
    level =
      cond do
        direction == :above and value >= crit -> :critical
        direction == :above and value >= warn -> :warning
        direction == :below and value <= crit -> :critical
        direction == :below and value <= warn -> :warning
        true -> :ok
      end

    %{
      key: key,
      level: level,
      value: value,
      warn_at: warn,
      critical_at: crit,
      direction: direction,
      message: message
    }
  end

  defp worst_status(signals) do
    cond do
      Enum.any?(signals, &(&1.level == :critical)) -> :critical
      Enum.any?(signals, &(&1.level == :warning)) -> :warning
      true -> :ok
    end
  end

  # ---------------------------------------------------------------------
  # Query plumbing
  # ---------------------------------------------------------------------

  defp query_timeout,
    do: Application.get_env(:tokengate, :stats_query_timeout_ms, @default_timeout)

  # `Logs.ensure_window!/2` is the retention contract: no `:from` is an
  # ArgumentError in dev/test, a warned clamp to the cutoff in production.
  defp window!(filters, fun) do
    filters
    |> normalize_filters()
    |> Logs.ensure_window!(fun)
    |> normalize_bounds(fun)
  end

  defp normalize_filters(filters) when is_list(filters), do: normalize_filters(Map.new(filters))

  defp normalize_filters(filters) when is_map(filters) do
    Enum.reduce(@filter_keys, %{}, fn key, acc ->
      case Map.fetch(filters, key) do
        {:ok, value} ->
          Map.put(acc, key, value)

        :error ->
          case Map.fetch(filters, Atom.to_string(key)) do
            {:ok, value} -> Map.put(acc, key, value)
            :error -> acc
          end
      end
    end)
  end

  defp normalize_bounds(filters, fun) do
    filters
    |> Map.put(:from, bound!(filters[:from], :start, fun))
    |> Map.put(:to, bound!(filters[:to], :end, fun))
  end

  defp bound!(nil, _edge, _fun), do: nil

  defp bound!(%DateTime{} = dt, _edge, _fun), do: DateTime.truncate(dt, :second)

  defp bound!(%NaiveDateTime{} = ndt, _edge, _fun),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)

  defp bound!(%Date{} = date, edge, _fun) do
    case edge do
      :start -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      :end -> DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
    end
  end

  defp bound!(value, edge, fun) when is_binary(value) do
    trimmed = String.trim(value)

    case DateTime.from_iso8601(trimmed) do
      {:ok, dt, _offset} ->
        DateTime.truncate(dt, :second)

      _ ->
        case Date.from_iso8601(trimmed) do
          {:ok, date} -> bound!(date, edge, fun)
          _ -> raise ArgumentError, "#{fun}: invalid :#{edge} bound #{inspect(value)}"
        end
    end
  end

  defp bound!(value, edge, fun) do
    raise ArgumentError, "#{fun}: invalid :#{edge} bound #{inspect(value)}"
  end

  # Routed rows only — the partial index is the whole point.
  #
  # `request_type == "router_decision"` rows are marked `routed_via_router`
  # too (they are the classifier's own billed call), but they are NOT served
  # traffic: counting them would double the request count and let the
  # classifier pay itself out of the savings it reports.
  defp routed_query(filters) do
    RequestLog
    |> where([rl], rl.routed_via_router == true)
    |> where([rl], rl.request_type != "router_decision")
    |> bound_query(filters)
    |> subject_filters(filters)
  end

  # Time window only (used by the router-vs-direct read, which needs both
  # sides).
  defp bound_query(query, filters) do
    query
    |> where([rl], rl.inserted_at >= ^filters.from)
    |> maybe_to(filters.to)
  end

  defp maybe_to(query, nil), do: query
  defp maybe_to(query, %DateTime{} = to), do: where(query, [rl], rl.inserted_at <= ^to)

  # Shadow rows are bounded on `request_inserted_at` (the log's partition day,
  # copied onto the row) so a read follows the same window as the log it
  # describes.
  defp shadow_maybe_to(query, nil), do: query

  defp shadow_maybe_to(query, %DateTime{} = to),
    do: where(query, [se], se.request_inserted_at <= ^to)

  defp shadow_maybe_bounds(query, nil), do: query

  defp shadow_maybe_bounds(query, {min, max}) do
    where(query, [se], se.request_inserted_at >= ^min and se.request_inserted_at <= ^max)
  end

  # `{log_id, inserted_at}` pairs carry the partition key the composite index
  # `(request_log_id, request_inserted_at)` wants; bare ids still work, they
  # just cannot bound the time range.
  defp split_log_refs(refs) do
    {ids, times} =
      Enum.reduce(refs, {[], []}, fn
        {id, inserted_at}, {ids, times} when is_binary(id) ->
          {[id | ids], [log_ref_datetime(inserted_at) | times]}

        id, {ids, times} when is_binary(id) ->
          {[id | ids], times}

        other, _acc ->
          raise ArgumentError,
                "shadow_for_logs/1 expects log ids or {log_id, inserted_at} pairs, got: " <>
                  inspect(other)
      end)

    {ids |> Enum.reverse() |> Enum.uniq(), times}
  end

  defp log_ref_datetime(%DateTime{} = value), do: DateTime.truncate(value, :second)

  defp log_ref_datetime(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)

  defp log_ref_datetime(other) do
    raise ArgumentError,
          "shadow_for_logs/1 expects DateTime/NaiveDateTime timestamps, got: #{inspect(other)}"
  end

  defp time_bounds([]), do: nil

  defp time_bounds(times) do
    {min, max} = Enum.min_max(times)
    {min, max}
  end

  defp absolute(%Decimal{} = value) do
    case Decimal.compare(value, 0) do
      :lt -> Decimal.negate(value)
      _ -> value
    end
    |> Decimal.to_float()
  end

  defp subject_filters(query, filters, opts \\ []) do
    query =
      Enum.reduce(
        [
          model_id: filters[:model_id],
          model_resolved: filters[:model_resolved],
          service_id: filters[:service_id],
          user_id: filters[:user_id],
          group_member_id: filters[:group_member_id]
        ],
        query,
        fn {field, value}, acc -> maybe_eq(acc, field, value) end
      )

    query =
      Enum.reduce(
        [user_id: filters[:user_ids], group_member_id: filters[:member_ids]],
        query,
        fn {field, ids}, acc -> maybe_in(acc, field, ids) end
      )

    query = maybe_group(query, filters[:group_id])

    if Keyword.get(opts, :router_dimensions?, true) do
      Enum.reduce(
        [
          router_use_case_key: filters[:router_use_case_key],
          router_effort_tier: filters[:router_effort_tier],
          router_decision_source: filters[:router_decision_source]
        ],
        query,
        fn {field, value}, acc -> maybe_eq(acc, field, value) end
      )
    else
      query
    end
  end

  defp maybe_eq(query, _field, nil), do: query
  defp maybe_eq(query, field, value), do: where(query, [rl], field(rl, ^field) == ^value)

  defp maybe_in(query, _field, ids) when ids in [nil, []], do: query
  defp maybe_in(query, field, ids), do: where(query, [rl], field(rl, ^field) in ^ids)

  defp maybe_group(query, nil), do: query

  defp maybe_group(query, group_id) do
    member_ids = from(gm in GroupMember, where: gm.group_id == ^group_id, select: gm.id)
    where(query, [rl], rl.group_member_id in subquery(member_ids))
  end

  # Names come from the SERVING Default only. A clone may rename a use case
  # (an experimental label for the same key), and letting it win the `Map.new`
  # would relabel the Default's traffic in `use_case_breakdown/1`.
  defp use_case_names do
    from(uc in RouterUseCase,
      join: c in RouterConfig,
      on: uc.router_config_id == c.id and c.is_default == true,
      select: {uc.key, uc.name}
    )
    |> Repo.all(timeout: query_timeout())
    |> Map.new()
  end

  # ---------------------------------------------------------------------
  # Numbers (nil = undefined denominator; 0.0 = measured and zero)
  # ---------------------------------------------------------------------

  defp utc_datetime(%DateTime{} = value), do: value
  defp utc_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp utc_datetime(nil), do: nil

  defp decimal(nil), do: Decimal.new(0)
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_binary(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp money(%Decimal{} = value), do: Decimal.round(value, 6)

  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(value) when is_float(value), do: value
  defp to_float(nil), do: 0.0

  defp float_or_nil(nil), do: nil
  defp float_or_nil(value), do: Float.round(to_float(value), 2)

  defp ratio(_numerator, nil), do: nil

  defp ratio(numerator, denominator) when is_number(numerator) and is_number(denominator) do
    if denominator > 0, do: numerator / denominator
  end

  defp ratio(_numerator, _denominator), do: nil

  defp rate(numerator, denominator, multiplier) do
    case ratio(to_float(numerator), denominator) do
      nil -> nil
      value -> Float.round(value * multiplier, 4)
    end
  end

  defp percent(_part, nil), do: nil
  defp percent(_part, 0), do: nil

  defp percent(part, whole) when is_number(part) and is_number(whole) and whole > 0 do
    Float.round(part / whole * 100, 2)
  end

  defp percent(_part, _whole), do: nil

  # Percentage OF a Decimal total (money ratios), same nil-on-zero contract.
  defp percent_of(%Decimal{} = part, %Decimal{} = whole) do
    case Decimal.compare(whole, 0) do
      :gt -> Float.round(Decimal.to_float(part) / Decimal.to_float(whole) * 100, 2)
      _ -> nil
    end
  end

  defp delta_pct(nil, _baseline), do: nil
  defp delta_pct(_value, nil), do: nil
  defp delta_pct(_value, baseline) when is_number(baseline) and baseline == 0, do: nil

  defp delta_pct(value, baseline) when is_number(value) and is_number(baseline) do
    Float.round((value - baseline) / baseline * 100, 2)
  end

  defp fmt_pct(nil), do: "—"
  defp fmt_pct(value) when is_float(value), do: "#{Float.round(value, 1)}%"

  defp fmt_num(value) when is_float(value), do: "#{Float.round(value, 1)}"
  defp fmt_num(nil), do: "—"
end
