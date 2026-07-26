defmodule Tokengate.Metrics.CollectorTest do
  @moduledoc """
  Tests for Tokengate.Metrics.Collector — ETS-backed real-time counters.

  `async: false` because the ETS table `:tokengate_metrics` is a named
  (singleton) table; concurrent tests would clobber each other's counters.
  `reset/0` is called in setup so each test starts from a clean slate.
  """

  use ExUnit.Case, async: false

  alias Tokengate.Metrics.Collector

  setup do
    # Reuse the app-tree collector when present; otherwise start one under the
    # test supervisor. Then reset the ETS table for a clean slate.
    pid = Process.whereis(Collector) || start_supervised!(Collector)
    _ = :sys.get_state(pid)
    Collector.reset()
    :ok
  end

  # Helper to build a valid record_request attrs map.
  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        model_alias_id: "alias-1",
        provider_id: "provider-1",
        agent_type: "api",
        status: 200,
        latency_ms: 100,
        prompt_tokens: 50,
        completion_tokens: 25,
        cost_usd: Decimal.new("0.500000"),
        savings_usd: Decimal.new("0.100000"),
        streaming: false
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------
  # record_request/1 — counter increments
  # ---------------------------------------------------------------------

  describe "record_request/1 — counter increments" do
    test "increments total request count" do
      Collector.record_request(attrs())
      Collector.record_request(attrs())
      Collector.record_request(attrs())

      snap = Collector.snapshot()
      assert snap.requests_total == 3
    end

    test "increments per-dimension counters" do
      Collector.record_request(
        attrs(%{model_alias_id: "a1", provider_id: "p1", agent_type: "api"})
      )

      Collector.record_request(
        attrs(%{model_alias_id: "a1", provider_id: "p2", agent_type: "sdk"})
      )

      Collector.record_request(
        attrs(%{model_alias_id: "a2", provider_id: "p1", agent_type: "api"})
      )

      snap = Collector.snapshot()

      assert snap.by_alias == %{"a1" => 2, "a2" => 1}
      assert snap.by_provider == %{"p1" => 2, "p2" => 1}
      assert snap.by_agent == %{"api" => 2, "sdk" => 1}
    end

    test "increments prompt and completion tokens" do
      Collector.record_request(attrs(%{prompt_tokens: 100, completion_tokens: 50}))
      Collector.record_request(attrs(%{prompt_tokens: 200, completion_tokens: 75}))

      snap = Collector.snapshot()
      assert snap.prompt_tokens == 300
      assert snap.completion_tokens == 125
    end
  end

  # ---------------------------------------------------------------------
  # error counting + rate
  # ---------------------------------------------------------------------

  describe "error counting and rate" do
    test "counts status >= 400 as errors" do
      Collector.record_request(attrs(%{status: 200}))
      Collector.record_request(attrs(%{status: 404}))
      Collector.record_request(attrs(%{status: 500}))
      Collector.record_request(attrs(%{status: 200}))

      snap = Collector.snapshot()
      assert snap.requests_total == 4
      assert snap.errors_total == 2
      assert_in_delta snap.error_rate, 0.5, 0.001
    end

    test "status 399 is not an error" do
      Collector.record_request(attrs(%{status: 399}))
      snap = Collector.snapshot()
      assert snap.errors_total == 0
      assert snap.error_rate == 0.0
    end

    test "error_rate is 0.0 with no requests" do
      snap = Collector.snapshot()
      assert snap.error_rate == 0.0
    end
  end

  # ---------------------------------------------------------------------
  # micro-USD exactness over 1000 records
  # ---------------------------------------------------------------------

  describe "micro-USD cost/savings counters" do
    test "exact over 1000 records with fractional micro-USD" do
      # $0.000001 per request → 1000 requests = $0.001000 total.
      # 0.000001 * 1_000_000 = 1 micro-USD per request.
      cost = Decimal.new("0.000001")
      savings = Decimal.new("0.000002")

      for _ <- 1..1000 do
        Collector.record_request(attrs(%{cost_usd: cost, savings_usd: savings}))
      end

      snap = Collector.snapshot()

      # 1000 * 0.000001 = 0.001000
      assert Decimal.equal?(snap.cost_usd, Decimal.new("0.001000"))
      # 1000 * 0.000002 = 0.002000
      assert Decimal.equal?(snap.savings_usd, Decimal.new("0.002000"))
    end

    test "rounds half-up on micro boundaries" do
      # 0.0000005 → rounds to 1 micro-USD (half_up)
      Collector.record_request(attrs(%{cost_usd: Decimal.new("0.0000005")}))
      snap = Collector.snapshot()
      assert Decimal.equal?(snap.cost_usd, Decimal.new("0.000001"))
    end

    test "zero cost handled" do
      Collector.record_request(
        attrs(%{cost_usd: Decimal.new("0"), savings_usd: Decimal.new("0")})
      )

      snap = Collector.snapshot()
      assert Decimal.equal?(snap.cost_usd, Decimal.new("0.000000"))
      assert Decimal.equal?(snap.savings_usd, Decimal.new("0.000000"))
    end
  end

  # ---------------------------------------------------------------------
  # latency samples trim at 200
  # ---------------------------------------------------------------------

  describe "latency ring" do
    test "trims samples to 200 entries" do
      for i <- 1..250 do
        Collector.record_request(attrs(%{latency_ms: i}))
      end

      snap = Collector.snapshot()
      assert snap.latency.count == 200
    end

    test "keeps the most recent 200 (prepended, so 250..51)" do
      for i <- 1..250 do
        Collector.record_request(attrs(%{latency_ms: i}))
      end

      snap = Collector.snapshot()
      # The last 200 recorded are 51..250. avg = sum(51..250) / 200.
      expected_avg = Enum.sum(51..250) / 200
      assert_in_delta snap.latency.avg_ms, expected_avg, 0.001
    end
  end

  # ---------------------------------------------------------------------
  # p95 / avg math
  # ---------------------------------------------------------------------

  describe "p95 and avg math" do
    test "avg over known samples" do
      for ms <- [10, 20, 30, 40, 50] do
        Collector.record_request(attrs(%{latency_ms: ms}))
      end

      snap = Collector.snapshot()
      assert snap.latency.count == 5
      assert_in_delta snap.latency.avg_ms, 30.0, 0.001
    end

    test "p95 returns max when count < 20" do
      for ms <- [10, 50, 100, 200] do
        Collector.record_request(attrs(%{latency_ms: ms}))
      end

      snap = Collector.snapshot()
      # count 4 < 20 → p95 is max
      assert snap.latency.p95_ms == 200
    end

    test "p95 uses nearest-rank for count >= 20" do
      # 20 samples 1..20. p95 rank = ceil(0.95 * 20) = 19, index 18 → value 19.
      for ms <- 1..20 do
        Collector.record_request(attrs(%{latency_ms: ms}))
      end

      snap = Collector.snapshot()
      assert snap.latency.p95_ms == 19
    end

    test "p95 with 100 samples" do
      for ms <- 1..100 do
        Collector.record_request(attrs(%{latency_ms: ms}))
      end

      snap = Collector.snapshot()
      # rank = ceil(0.95 * 100) = 95, index 94 → value 95
      assert snap.latency.p95_ms == 95
    end

    test "empty latency returns count 0, avg 0.0, p95 0" do
      snap = Collector.snapshot()
      assert snap.latency.count == 0
      assert snap.latency.avg_ms == 0.0
      assert snap.latency.p95_ms == 0
    end
  end

  # ---------------------------------------------------------------------
  # broadcast received
  # ---------------------------------------------------------------------

  describe "PubSub broadcast" do
    test "broadcasts {:metrics_updated, lite} on each record" do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, "metrics:updated")

      Collector.record_request(attrs())

      assert_receive {:metrics_updated, lite}
      assert Map.has_key?(lite, :requests_total)
      assert Map.has_key?(lite, :errors_total)
      assert lite.requests_total == 1
      assert lite.errors_total == 0
    end

    test "snapshot_lite contains only requests_total and errors_total" do
      lite = Collector.snapshot_lite()
      assert Map.keys(lite) |> Enum.sort() == [:errors_total, :requests_total]
    end
  end

  # ---------------------------------------------------------------------
  # snapshot shape
  # ---------------------------------------------------------------------

  describe "snapshot/0 shape" do
    test "returns Decimal cost_usd and savings_usd" do
      Collector.record_request(
        attrs(%{cost_usd: Decimal.new("1.500000"), savings_usd: Decimal.new("0.250000")})
      )

      snap = Collector.snapshot()

      assert %Decimal{} = snap.cost_usd
      assert %Decimal{} = snap.savings_usd
      assert Decimal.equal?(snap.cost_usd, Decimal.new("1.500000"))
      assert Decimal.equal?(snap.savings_usd, Decimal.new("0.250000"))
    end

    test "has all required keys" do
      Collector.record_request(attrs())

      snap = Collector.snapshot()

      assert Map.has_key?(snap, :requests_total)
      assert Map.has_key?(snap, :errors_total)
      assert Map.has_key?(snap, :error_rate)
      assert Map.has_key?(snap, :by_alias)
      assert Map.has_key?(snap, :by_provider)
      assert Map.has_key?(snap, :by_agent)
      assert Map.has_key?(snap, :prompt_tokens)
      assert Map.has_key?(snap, :completion_tokens)
      assert Map.has_key?(snap, :cost_usd)
      assert Map.has_key?(snap, :savings_usd)
      assert Map.has_key?(snap, :latency)

      assert Map.has_key?(snap.latency, :count)
      assert Map.has_key?(snap.latency, :avg_ms)
      assert Map.has_key?(snap.latency, :p95_ms)
    end
  end

  # ---------------------------------------------------------------------
  # reset/0
  # ---------------------------------------------------------------------

  describe "reset/0" do
    test "clears all counters" do
      Collector.record_request(attrs(%{status: 500}))
      Collector.record_request(attrs(%{status: 200}))

      assert Collector.snapshot().requests_total == 2

      Collector.reset()

      snap = Collector.snapshot()
      assert snap.requests_total == 0
      assert snap.errors_total == 0
      assert snap.latency.count == 0
      assert snap.by_alias == %{}
    end
  end
end
