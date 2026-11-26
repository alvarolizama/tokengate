defmodule Tokengate.SmartRouter.AnalyticsTest do
  @moduledoc """
  Integration tests for `Tokengate.SmartRouter.Analytics`.

  Fixtures live INSIDE today's UTC day (`request_logs` is partitioned by day
  and pruned by retention) and always set `routed_via_router: true`, so the
  partial index is what the reads actually exercise.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Providers
  alias Tokengate.Repo
  alias Tokengate.SmartRouter.Analytics
  alias Tokengate.SmartRouter.UseCase

  @public_functions [
    summary: 1,
    decision_source_breakdown: 1,
    use_case_breakdown: 1,
    model_performance: 1,
    router_vs_direct_by_subject: 1,
    false_savings_signals: 1,
    who_spent_on_what: 1,
    decision_insights: 1
  ]

  # ---------------------------------------------------------------------
  # Fixtures (today's UTC partition only)
  # ---------------------------------------------------------------------

  defp at(hour, minute \\ 0, second \\ 0) do
    DateTime.new!(Date.utc_today(), Time.new!(hour, minute, second), "Etc/UTC")
  end

  defp window, do: [from: at(0), to: at(23, 59, 59)]

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp user_subject do
    {:ok, group} = Accounts.create_group(%{name: unique("Analytics Group")})

    {:ok, user} =
      Accounts.register_user(%{
        email: "#{unique("analytics")}@example.com",
        name: "Analytics User",
        password: "ValidPassword123"
      })

    {:ok, member} = Accounts.create_group_member(%{group_id: group.id, user_id: user.id})
    {member, user, group}
  end

  defp service_subject do
    {:ok, service} = Accounts.create_service(%{name: unique("Analytics Service")})
    service
  end

  defp model_fixture(name) do
    {:ok, model} = Providers.create_model(%{"name" => name, "context_window" => 128_000})
    model
  end

  defp use_case_fixture(key, name) do
    {:ok, use_case} =
      %UseCase{}
      |> UseCase.changeset(%{key: key, name: name})
      |> Repo.insert()

    use_case
  end

  defp base_attrs do
    %{
      model_requested: "router",
      subject_type: "user",
      status_code: 200,
      inserted_at: at(10),
      routed_via_router: true,
      prompt_tokens: 100,
      completion_tokens: 50,
      provider_cost_usd: Decimal.new("0.100000"),
      router_decision_cost_usd: Decimal.new("0.000000"),
      prompt_tokens_saved_est: 0
    }
  end

  defp log!(member_id, attrs) when is_binary(member_id) do
    {:ok, row} =
      Logs.log_request(Map.merge(base_attrs(), Map.put(attrs, :group_member_id, member_id)))

    row
  end

  defp log_service!(service_id, attrs) do
    attrs =
      base_attrs()
      |> Map.merge(%{subject_type: "service", inserted_at: at(10), prompt_tokens: 100})
      |> Map.merge(attrs)
      |> Map.put(:service_id, service_id)

    {:ok, row} = Logs.log_request(attrs)
    row
  end

  defp money(value), do: Decimal.new(value)

  # ---------------------------------------------------------------------
  # Window contract
  # ---------------------------------------------------------------------

  describe "window contract" do
    test "every public function raises ArgumentError without :from" do
      for {fun, arity} <- @public_functions do
        assert_raise ArgumentError, fn -> apply(Analytics, fun, List.duplicate([], arity)) end
      end
    end

    test "rows outside the requested window are excluded" do
      {member, _user, _group} = user_subject()
      log!(member.id, %{inserted_at: at(1), provider_cost_usd: money("1.000000")})
      log!(member.id, %{inserted_at: at(12), provider_cost_usd: money("2.000000")})

      summary = Analytics.summary(from: at(11), to: at(13))

      assert summary.request_count == 1
      assert Decimal.equal?(summary.served_cost_usd, money("2.000000"))
    end

    test "non-routed rows never enter the routed reads" do
      {member, _user, _group} = user_subject()
      log!(member.id, %{provider_cost_usd: money("1.000000")})
      log!(member.id, %{provider_cost_usd: money("5.000000"), routed_via_router: false})

      assert Analytics.summary(window()).request_count == 1
    end

    test "classifier-billed router_decision rows are never served traffic" do
      {member, _user, _group} = user_subject()

      log!(member.id, %{
        provider_cost_usd: money("1.000000"),
        router_decision_cost_usd: money("0.050000")
      })

      # The classifier's own call: `routed_via_router` is true (it is the
      # router's spend) but it is NOT a served request. Counting it would
      # double the traffic and let the decision pay itself out of the saving.
      log!(member.id, %{
        request_type: "router_decision",
        provider_cost_usd: money("0.050000"),
        router_decision_cost_usd: money("0.050000"),
        router_decision_source: "classifier",
        router_decision_ms: 90
      })

      summary = Analytics.summary(window())

      assert summary.request_count == 1
      assert Decimal.equal?(summary.served_cost_usd, money("1.000000"))
      assert Decimal.equal?(summary.decision_cost_usd, money("0.050000"))
      assert summary.classifier_request_count == 0

      # Same exclusion in every other read over the partial index.
      assert Analytics.decision_source_breakdown(window())
             |> Enum.map(& &1.request_count)
             |> Enum.sum() == 1

      assert Analytics.model_performance(window()) |> Enum.map(& &1.request_count) |> Enum.sum() ==
               1

      assert Analytics.who_spent_on_what(window()) |> Enum.map(& &1.request_count) |> Enum.sum() ==
               1
    end
  end

  # ---------------------------------------------------------------------
  # summary/1
  # ---------------------------------------------------------------------

  describe "summary/1" do
    test "computes honest net savings, coverage and normalized rates" do
      {member, _user, _group} = user_subject()

      # Priced row, cheaper than baseline.
      log!(member.id, %{
        prompt_tokens: 1_000,
        completion_tokens: 500,
        provider_cost_usd: money("0.400000"),
        router_decision_cost_usd: money("0.010000"),
        router_baseline_cost_usd: money("1.000000"),
        router_decision_source: "classifier",
        router_decision_ms: 120,
        prompt_tokens_saved_est: 200
      })

      # Priced row, MORE expensive than baseline: its negative saving must
      # subtract from the total (never GREATEST(0, ...)).
      log!(member.id, %{
        prompt_tokens: 1_000,
        completion_tokens: 500,
        provider_cost_usd: money("0.800000"),
        router_decision_cost_usd: money("0.000000"),
        router_baseline_cost_usd: money("0.500000"),
        router_decision_source: "rule",
        router_decision_ms: 5
      })

      # Unpriced row (no baseline) + cache hit: counted in volume, NEVER in
      # the savings denominator.
      log!(member.id, %{
        prompt_tokens: 100,
        completion_tokens: 100,
        provider_cost_usd: money("0.200000"),
        router_decision_source: "fast_path",
        cache_hit: true
      })

      summary = Analytics.summary(window())

      assert summary.request_count == 3
      assert summary.cache_hit_count == 1
      assert_in_delta 33.33, summary.cache_hit_pct, 0.01
      assert summary.error_count == 0
      assert summary.fallback_count == 0

      # served 1.40 + decision 0.01; baseline 1.50; covered cost 0.41 + 0.80.
      assert Decimal.equal?(summary.served_cost_usd, money("1.400000"))
      assert Decimal.equal?(summary.decision_cost_usd, money("0.010000"))
      assert Decimal.equal?(summary.served_plus_decision_usd, money("1.410000"))
      assert Decimal.equal?(summary.baseline_cost_usd, money("1.500000"))
      assert summary.baseline_request_count == 2
      assert_in_delta 66.67, summary.baseline_coverage_pct, 0.01

      # net = 1.50 - (0.41 + 0.80) = 0.29
      assert Decimal.equal?(summary.net_savings_usd, money("0.290000"))
      assert_in_delta 19.33, summary.savings_pct, 0.01

      # Volume normalization: USD/1K req over every routed request; the
      # served+decision $/1M rate over EVERY served token (3_200), while the
      # baseline/savings pair only exists for the priced rows (3_000 tokens).
      assert_in_delta 470.0, summary.usd_per_1k_requests, 0.01
      assert_in_delta 440.625, summary.served_plus_decision_usd_per_1m_tokens, 0.01
      assert_in_delta 500.0, summary.baseline_usd_per_1m_tokens, 0.01
      assert_in_delta 96.6667, summary.savings_usd_per_1m_tokens, 0.01

      assert summary.prompt_tokens_saved_est == 200
      assert summary.prompt_tokens == 2_100
      assert summary.completion_tokens == 1_100

      # Classifier keeps its own cost and latency, split from the served cost.
      assert summary.classifier_request_count == 1
      assert Decimal.equal?(summary.classifier_cost_usd, money("0.010000"))
      assert_in_delta 0.71, summary.classifier_cost_share_pct, 0.01
      assert summary.classifier_p50_ms == 120.0
      assert summary.classifier_p95_ms == 120.0
    end

    test "keeps negative net savings instead of clamping to zero" do
      {member, _user, _group} = user_subject()

      log!(member.id, %{
        provider_cost_usd: money("2.000000"),
        router_decision_cost_usd: money("0.500000"),
        router_baseline_cost_usd: money("1.000000")
      })

      summary = Analytics.summary(window())

      assert Decimal.equal?(summary.net_savings_usd, money("-1.500000"))
      assert_in_delta(-150.0, summary.savings_pct, 0.01)
      assert_in_delta 100.0, summary.baseline_coverage_pct, 0.01
    end

    test "the served + decision $/1M rate does not depend on baseline coverage" do
      {member, _user, _group} = user_subject()

      log!(member.id, %{
        prompt_tokens: 1_000,
        completion_tokens: 0,
        provider_cost_usd: money("0.500000"),
        router_decision_cost_usd: money("0.100000")
      })

      summary = Analytics.summary(window())

      # No baseline price anywhere: the saving stays unmeasurable…
      assert summary.baseline_coverage_pct == 0.0
      assert summary.baseline_usd_per_1m_tokens == nil
      assert summary.savings_usd_per_1m_tokens == nil
      # …but what was actually served is measured over its OWN tokens
      # (0.60 USD / 1_000 tokens), never gated behind a baseline.
      assert_in_delta 600.0, summary.served_plus_decision_usd_per_1m_tokens, 0.01
    end

    test "classifier p50/p95 use percentile_cont over classifier rows only" do
      {member, _user, _group} = user_subject()

      for {ms, source} <- [
            {100, "classifier"},
            {200, "classifier"},
            {400, "classifier"},
            {9_000, "rule"}
          ] do
        log!(member.id, %{router_decision_ms: ms, router_decision_source: source})
      end

      summary = Analytics.summary(window())

      assert summary.classifier_request_count == 3
      assert summary.classifier_p50_ms == 200.0
      assert summary.classifier_p95_ms == 380.0
      assert summary.decision_request_count == 4
      assert_in_delta 2_425.0, summary.avg_decision_ms, 0.01
    end

    test "an empty window reports zeroes, not invented savings" do
      summary = Analytics.summary(window())

      assert summary.request_count == 0
      assert Decimal.equal?(summary.net_savings_usd, money("0"))
      assert summary.baseline_coverage_pct == nil
      assert summary.usd_per_1k_requests == nil
      assert summary.classifier_p50_ms == nil
    end

    test "filters by service and by group" do
      {member, _user, group} = user_subject()
      service = service_subject()

      log!(member.id, %{provider_cost_usd: money("1.000000")})
      log_service!(service.id, %{provider_cost_usd: money("3.000000")})

      assert Analytics.summary(window() ++ [group_id: group.id]).request_count == 1

      service_summary = Analytics.summary(window() ++ [service_id: service.id])
      assert service_summary.request_count == 1
      assert Decimal.equal?(service_summary.served_cost_usd, money("3.000000"))
    end
  end

  # ---------------------------------------------------------------------
  # decision_source_breakdown/1
  # ---------------------------------------------------------------------

  describe "decision_source_breakdown/1" do
    test "groups by decision source with share, spend and escalation" do
      {member, _user, _group} = user_subject()

      log!(member.id, %{
        router_decision_source: "classifier",
        provider_cost_usd: money("0.400000"),
        router_decision_cost_usd: money("0.020000"),
        router_baseline_cost_usd: money("1.000000"),
        router_decision_ms: 80
      })

      log!(member.id, %{
        router_decision_source: "classifier",
        provider_cost_usd: money("0.800000"),
        router_decision_cost_usd: money("0.020000"),
        router_baseline_cost_usd: money("0.500000"),
        router_decision_ms: 120
      })

      log!(member.id, %{
        router_decision_source: "fallback_error",
        provider_cost_usd: money("0.300000"),
        status_code: 500
      })

      # nil source is labelled, never dropped.
      log!(member.id, %{provider_cost_usd: money("0.100000")})

      rows = Analytics.decision_source_breakdown(window())
      by_source = Map.new(rows, &{&1.decision_source, &1})

      assert length(rows) == 3

      classifier = by_source["classifier"]
      assert classifier.request_count == 2
      assert_in_delta 50.0, classifier.share_pct, 0.01
      assert Decimal.equal?(classifier.served_cost_usd, money("1.200000"))
      assert Decimal.equal?(classifier.decision_cost_usd, money("0.040000"))
      assert Decimal.equal?(classifier.baseline_cost_usd, money("1.500000"))
      assert_in_delta 100.0, classifier.baseline_coverage_pct, 0.01
      # 1.24 spent vs 1.50 baseline.
      assert Decimal.equal?(classifier.net_savings_usd, money("0.260000"))
      # One of the two classifier rows escalated above its baseline (0.82 > 0.50).
      assert classifier.escalation_count == 1
      assert_in_delta 50.0, classifier.escalation_pct, 0.01
      assert classifier.p50_decision_ms == 100.0

      fallback = by_source["fallback_error"]
      assert fallback.request_count == 1
      assert fallback.fallback
      assert fallback.error_count == 1
      assert_in_delta 100.0, fallback.error_rate_pct, 0.01
      # That source has rows but none priced: coverage is a measured 0 %.
      assert fallback.baseline_coverage_pct == 0.0

      assert by_source["unknown"].request_count == 1
      refute by_source["unknown"].fallback
    end
  end

  # ---------------------------------------------------------------------
  # use_case_breakdown/1
  # ---------------------------------------------------------------------

  describe "use_case_breakdown/1" do
    test "groups by use case × effort tier and reports escalation and fallback" do
      {member, _user, _group} = user_subject()

      use_case_fixture("coding_implement", "Coding — implement")

      log!(member.id, %{
        router_use_case_key: "coding_implement",
        router_effort_tier: "high",
        provider_cost_usd: money("1.000000"),
        router_decision_cost_usd: money("0.050000"),
        router_baseline_cost_usd: money("2.000000"),
        prompt_tokens: 1_000,
        completion_tokens: 500,
        prompt_tokens_saved_est: 300,
        cache_hit: true
      })

      log!(member.id, %{
        router_use_case_key: "coding_implement",
        router_effort_tier: "high",
        provider_cost_usd: money("3.000000"),
        router_decision_cost_usd: money("0.000000"),
        router_baseline_cost_usd: money("1.000000"),
        router_decision_source: "fallback_timeout",
        prompt_tokens: 1_000,
        completion_tokens: 500
      })

      log!(member.id, %{
        router_use_case_key: "chat_qa",
        router_effort_tier: "low",
        provider_cost_usd: money("0.200000"),
        prompt_tokens: 100,
        completion_tokens: 100
      })

      # Rows with no use case are not discarded.
      log!(member.id, %{provider_cost_usd: money("0.100000")})

      rows = Analytics.use_case_breakdown(window())
      keyed = Map.new(rows, &{{&1.use_case_key, &1.effort_tier}, &1})

      assert length(rows) == 3

      coding = keyed[{"coding_implement", "high"}]
      assert coding.use_case_name == "Coding — implement"
      assert coding.request_count == 2
      assert_in_delta 50.0, coding.share_pct, 0.01
      assert Decimal.equal?(coding.served_cost_usd, money("4.000000"))
      assert Decimal.equal?(coding.decision_cost_usd, money("0.050000"))
      assert Decimal.equal?(coding.total_cost_usd, money("4.050000"))
      assert Decimal.equal?(coding.baseline_cost_usd, money("3.000000"))
      # 3.00 baseline - (1.05 + 3.00) = -1.05 (honest negative)
      assert Decimal.equal?(coding.net_savings_usd, money("-1.050000"))
      assert coding.escalation_count == 1
      assert_in_delta 50.0, coding.escalation_pct, 0.01
      assert Decimal.equal?(coding.escalation_cost_usd, money("2.000000"))
      assert coding.fallback_count == 1
      assert_in_delta 50.0, coding.fallback_rate_pct, 0.01
      assert_in_delta 50.0, coding.cache_hit_pct, 0.01
      assert coding.prompt_tokens_saved_est == 300
      assert coding.total_tokens == 3_000
      assert_in_delta 1_500.0, coding.tokens_per_request, 0.01

      assert keyed[{"chat_qa", "low"}].use_case_name == nil
      assert keyed[{"unclassified", "none"}].request_count == 1

      # Sorted by spend, descending: coding/high (4.05) before chat_qa (0.20).
      assert [%{use_case_key: "coding_implement"} | _] = rows
    end
  end

  # ---------------------------------------------------------------------
  # model_performance/1
  # ---------------------------------------------------------------------

  describe "model_performance/1" do
    test "computes tok/s over the generation window and ttft percentiles" do
      {member, _user, _group} = user_subject()
      fast = model_fixture(unique("model-fast"))
      slow = model_fixture(unique("model-slow"))

      # 100 completion tokens over (1000 - 200) ms = 125 tok/s.
      log!(member.id, %{
        model_id: fast.id,
        model_resolved: fast.name,
        completion_tokens: 100,
        latency_ms: 1_000,
        ttft_ms: 200,
        provider_cost_usd: money("0.100000")
      })

      # Second row with no ttft: window is the whole latency (500 ms).
      log!(member.id, %{
        model_id: fast.id,
        model_resolved: fast.name,
        completion_tokens: 50,
        latency_ms: 500,
        provider_cost_usd: money("0.300000")
      })

      log!(member.id, %{
        model_id: slow.id,
        model_resolved: slow.name,
        completion_tokens: 10,
        latency_ms: 2_000,
        ttft_ms: 1_800,
        status_code: 502,
        router_decision_source: "fallback_error",
        provider_cost_usd: money("0.900000")
      })

      rows = Analytics.model_performance(window())
      by_name = Map.new(rows, &{&1.model_name, &1})

      fast_row = by_name[fast.name]
      assert fast_row.request_count == 2
      # 100 prompt + 100 completion, then 100 prompt + 50 completion.
      assert fast_row.total_tokens == 350
      # (100 + 50) tokens / ((800 + 500) ms / 1000) = 115.38 tok/s
      assert_in_delta 115.38, fast_row.tokens_per_sec, 0.01
      assert fast_row.ttft_p50_ms == 200.0
      assert_in_delta 175.0, fast_row.tokens_per_request, 0.01
      # 0.40 USD over 350 tokens.
      assert_in_delta 1_142.8571, fast_row.usd_per_1m_tokens, 0.01
      assert fast_row.error_rate_pct == 0.0

      slow_row = by_name[slow.name]
      assert slow_row.error_count == 1
      assert_in_delta 100.0, slow_row.error_rate_pct, 0.01
      assert_in_delta 100.0, slow_row.fallback_rate_pct, 0.01
      assert slow_row.ttft_p50_ms == 1_800.0
      assert slow_row.ttft_p95_ms == 1_800.0
      # 10 tokens over 200 ms.
      assert_in_delta 50.0, slow_row.tokens_per_sec, 0.01

      # Sorted by spend: slow (0.90) before fast (0.40).
      assert [%{model_name: first} | _] = rows
      assert first == slow.name
    end

    test "resolves the display name from the catalog and falls back to model_resolved" do
      {member, _user, _group} = user_subject()
      model = model_fixture(unique("model-catalog"))

      log!(member.id, %{
        model_id: model.id,
        model_resolved: "stale-alias",
        completion_tokens: 10,
        latency_ms: 100
      })

      log!(member.id, %{
        model_id: Ecto.UUID.generate(),
        model_resolved: "external-model",
        completion_tokens: 10,
        latency_ms: 100
      })

      rows = Analytics.model_performance(window())
      names = Enum.map(rows, & &1.model_name)

      assert model.name in names
      assert "external-model" in names
      refute "stale-alias" in names
    end
  end

  # ---------------------------------------------------------------------
  # router_vs_direct_by_subject/1
  # ---------------------------------------------------------------------

  describe "router_vs_direct_by_subject/1" do
    test "compares a subject's routed and direct traffic side by side" do
      {member, user, _group} = user_subject()

      # Routed: 2 requests, 0.40 USD, 3_000 tokens => 133.33 $/1M.
      log!(member.id, %{
        provider_cost_usd: money("0.200000"),
        prompt_tokens: 1_000,
        completion_tokens: 500
      })

      log!(member.id, %{
        provider_cost_usd: money("0.200000"),
        prompt_tokens: 1_000,
        completion_tokens: 500
      })

      # Direct (not routed): 1 request, 1.00 USD, 1_000 tokens => 1_000 $/1M.
      log!(member.id, %{
        routed_via_router: false,
        provider_cost_usd: money("1.000000"),
        prompt_tokens: 500,
        completion_tokens: 500
      })

      assert [row] = Analytics.router_vs_direct_by_subject(window())

      assert row.subject_type == "user"
      assert row.subject_id == user.id
      assert row.subject_name == user.name

      assert row.router.request_count == 2
      assert Decimal.equal?(row.router.cost_usd, money("0.400000"))
      assert_in_delta 133.3333, row.router.usd_per_1m_tokens, 0.01
      assert_in_delta 0.2, row.router.usd_per_request, 0.01

      assert row.direct.request_count == 1
      assert Decimal.equal?(row.direct.cost_usd, money("1.000000"))
      assert_in_delta 1_000.0, row.direct.usd_per_1m_tokens, 0.01

      # Router is 86.67 % cheaper per 1M tokens than the subject's direct lane.
      assert_in_delta(-86.67, row.usd_per_1m_delta_pct, 0.01)
    end

    test "a subject with only routed traffic reports an empty direct half" do
      {member, _user, _group} = user_subject()
      log!(member.id, %{provider_cost_usd: money("0.500000")})

      assert [row] = Analytics.router_vs_direct_by_subject(window())

      assert row.router.request_count == 1
      assert row.direct.request_count == 0
      assert Decimal.equal?(row.direct.cost_usd, money("0"))
      assert row.usd_per_1m_delta_pct == nil
    end

    test "ignores router-dimension filters so the direct column survives" do
      {member, _user, _group} = user_subject()

      log!(member.id, %{
        router_use_case_key: "coding_implement",
        router_decision_source: "classifier"
      })

      log!(member.id, %{routed_via_router: false})

      assert [row] =
               Analytics.router_vs_direct_by_subject(
                 window() ++ [router_use_case_key: "coding_implement"]
               )

      assert row.router.request_count == 1
      assert row.direct.request_count == 1
    end

    test "the routed half is net of the decision step" do
      {member, _user, _group} = user_subject()

      # 0.20 served + 0.05 decision = 0.25 net over 1_000 tokens.
      log!(member.id, %{
        provider_cost_usd: money("0.200000"),
        router_decision_cost_usd: money("0.050000"),
        prompt_tokens: 1_000,
        completion_tokens: 0
      })

      # Direct lane: 1.00 over 1_000 tokens.
      log!(member.id, %{
        routed_via_router: false,
        provider_cost_usd: money("1.000000"),
        prompt_tokens: 1_000,
        completion_tokens: 0
      })

      assert [row] = Analytics.router_vs_direct_by_subject(window())

      assert Decimal.equal?(row.router.cost_usd, money("0.250000"))
      assert Decimal.equal?(row.router.served_cost_usd, money("0.200000"))
      assert Decimal.equal?(row.router.decision_cost_usd, money("0.050000"))
      assert_in_delta 250.0, row.router.usd_per_1m_tokens, 0.01
      # Without the decision cost the router would look 80 % cheaper; priced
      # honestly it is 75 % cheaper.
      assert_in_delta(-75.0, row.usd_per_1m_delta_pct, 0.01)
    end

    test "drops direct-only subjects and router_decision rows" do
      {member, _user, _group} = user_subject()

      # Direct-only subject: there is no router half to compare.
      log!(member.id, %{routed_via_router: false, provider_cost_usd: money("1.000000")})

      # A router_decision row is routed, but it is not served traffic: it must
      # not synthesize a router half out of the classifier's own call.
      log!(member.id, %{
        request_type: "router_decision",
        provider_cost_usd: money("0.010000")
      })

      assert Analytics.router_vs_direct_by_subject(window()) == []
    end
  end

  # ---------------------------------------------------------------------
  # false_savings_signals/1
  # ---------------------------------------------------------------------

  describe "false_savings_signals/1" do
    test "counts intra-session model switches and turns per session" do
      {member, _user, _group} = user_subject()
      model_a = model_fixture(unique("model-a"))
      model_b = model_fixture(unique("model-b"))

      # Session s1: two turns, different models => a switch.
      log!(member.id, %{session_id: "s1", model_id: model_a.id})
      log!(member.id, %{session_id: "s1", model_id: model_b.id})

      # Session s2: two turns, same model => no switch.
      log!(member.id, %{session_id: "s2", model_id: model_a.id})
      log!(member.id, %{session_id: "s2", model_id: model_a.id})

      # A row without a session: counted in coverage, not in sessions.
      log!(member.id, %{session_id: nil})

      signals = Analytics.false_savings_signals(window())

      assert signals.request_count == 5
      assert_in_delta 80.0, signals.session_coverage_pct, 0.01
      assert signals.sessions_count == 2
      assert signals.sessions_with_switch == 1
      assert_in_delta 50.0, signals.session_switch_rate_pct, 0.01
      assert_in_delta 2.0, signals.avg_turns_per_session, 0.01

      switch = Enum.find(signals.signals, &(&1.key == :session_switches))
      assert switch.direction == :above
      assert switch.level == :critical
      assert signals.status == :critical
    end

    test "reports classifier cost share and cache reuse honestly" do
      {member, _user, _group} = user_subject()

      log!(member.id, %{
        provider_cost_usd: money("0.900000"),
        router_decision_cost_usd: money("0.100000"),
        router_decision_source: "classifier",
        prompt_tokens: 1_000,
        cache_read_tokens: 0
      })

      signals = Analytics.false_savings_signals(window())

      assert_in_delta 10.0, signals.classifier_cost_share_pct, 0.01
      assert_in_delta 0.0, signals.cache_read_pct, 0.01
      assert Decimal.equal?(signals.served_plus_decision_usd, money("1.000000"))

      assert Enum.find(signals.signals, &(&1.key == :cache_read)).level == :critical
      assert Enum.find(signals.signals, &(&1.key == :classifier_overhead)).level == :warning
      assert signals.status == :critical
    end

    test "an empty window is :ok with no signals invented" do
      signals = Analytics.false_savings_signals(window())

      assert signals.request_count == 0
      assert signals.session_coverage_pct == nil
      assert signals.session_switch_rate_pct == nil
      assert signals.sessions_count == 0
      assert signals.status == :ok
    end
  end

  # ---------------------------------------------------------------------
  # who_spent_on_what/1
  # ---------------------------------------------------------------------

  describe "who_spent_on_what/1" do
    test "separates spend the subject could reach directly from router-only spend" do
      {member, user, group} = user_subject()
      reachable = model_fixture(unique("model-reachable"))
      acl_only = model_fixture(unique("model-acl-only"))

      log!(member.id, %{
        model_id: reachable.id,
        model_resolved: reachable.name,
        router_direct_access: true,
        provider_cost_usd: money("1.000000"),
        router_decision_cost_usd: money("0.010000"),
        prompt_tokens: 500,
        completion_tokens: 500,
        inserted_at: at(9)
      })

      log!(member.id, %{
        model_id: acl_only.id,
        model_resolved: acl_only.name,
        router_direct_access: false,
        provider_cost_usd: money("0.500000"),
        prompt_tokens: 500,
        completion_tokens: 500,
        inserted_at: at(15)
      })

      rows = Analytics.who_spent_on_what(window())
      by_model = Map.new(rows, &{&1.model_id, &1})

      assert length(rows) == 2

      direct = by_model[reachable.id]
      assert direct.subject_id == user.id
      assert direct.subject_name == user.name
      assert direct.group_name == group.name
      assert direct.direct_access == true
      assert direct.model_name == reachable.name
      assert Decimal.equal?(direct.cost_usd, money("1.010000"))
      assert_in_delta 1_010.0, direct.usd_per_1m_tokens, 0.01
      assert direct.last_seen_at.hour == 9

      router_only = by_model[acl_only.id]
      assert router_only.direct_access == false
      assert Decimal.equal?(router_only.cost_usd, money("0.500000"))
      assert_in_delta 500.0, router_only.usd_per_1m_tokens, 0.01
      assert router_only.last_seen_at.hour == 15

      # Sorted by spend, descending.
      assert hd(rows).model_id == reachable.id
    end

    test "attributes a service subject by its service name" do
      service = service_subject()
      model = model_fixture(unique("model-service"))

      log_service!(service.id, %{
        model_id: model.id,
        model_resolved: model.name,
        router_direct_access: false
      })

      assert [row] = Analytics.who_spent_on_what(window())

      assert row.subject_type == "service"
      assert row.subject_id == service.id
      assert row.subject_name == service.name
      assert row.group_name == nil
      assert row.direct_access == false
    end
  end

  # ---------------------------------------------------------------------
  # decision_insights/1
  # ---------------------------------------------------------------------

  describe "decision_insights/1" do
    test "flags a router that costs more than the baseline as critical" do
      {member, _user, _group} = user_subject()

      log!(member.id, %{
        provider_cost_usd: money("2.000000"),
        router_baseline_cost_usd: money("1.000000")
      })

      insights = Analytics.decision_insights(window())
      keys = Enum.map(insights, & &1.key)

      assert :negative_net_savings in keys
      assert Enum.find(insights, &(&1.key == :negative_net_savings)).level == :critical

      # Critical first.
      assert hd(insights).level in [:critical]
    end

    test "asks for baseline pricing when no routed row carries one" do
      {member, _user, _group} = user_subject()
      log!(member.id, %{provider_cost_usd: money("0.100000")})

      insights = Analytics.decision_insights(window())

      assert Enum.find(insights, &(&1.key == :no_baseline)).level == :critical
      assert Enum.find(insights, &(&1.key == :partial_baseline)) == nil
    end

    test "warns when the classifier overhead passes the threshold" do
      {member, _user, _group} = user_subject()

      log!(member.id, %{
        provider_cost_usd: money("0.880000"),
        router_decision_cost_usd: money("0.120000"),
        router_decision_source: "classifier",
        router_baseline_cost_usd: money("1.500000")
      })

      insights = Analytics.decision_insights(window())

      assert Enum.find(insights, &(&1.key == :classifier_overhead)).level == :warning
    end

    test "an empty window says so instead of inventing recommendations" do
      insights = Analytics.decision_insights(window())

      assert Enum.map(insights, & &1.key) == [:no_router_traffic]
    end

    test "decision_insights_from/3 derives the same list from pre-computed reads" do
      {member, _user, _group} = user_subject()

      log!(member.id, %{
        provider_cost_usd: money("2.000000"),
        router_baseline_cost_usd: money("1.000000")
      })

      from_parts =
        Analytics.decision_insights_from(
          Analytics.summary(window()),
          Analytics.false_savings_signals(window()),
          Analytics.use_case_breakdown(window())
        )

      direct = Analytics.decision_insights(window())

      # Same recommendations, same order — without re-running the three scans.
      assert Enum.map(from_parts, &{&1.key, &1.level}) ==
               Enum.map(direct, &{&1.key, &1.level})

      assert :negative_net_savings in Enum.map(from_parts, & &1.key)
    end
  end
end
