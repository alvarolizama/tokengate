defmodule Tokengate.Metrics.DashboardCacheTest do
  @moduledoc """
  Focused ad-hoc verification for the new DashboardCache ETS module.

  `async: false` because the ETS table `:tokengate_dashboard_cache` is a
  named (singleton) table. `invalidate_all/0` in setup gives each test a
  clean slate.
  """

  use ExUnit.Case, async: false

  alias Tokengate.Metrics.DashboardCache

  setup do
    # Reuse the app-tree cache when present; otherwise start one.
    pid = Process.whereis(DashboardCache) || start_supervised!(DashboardCache)
    _ = :sys.get_state(pid)
    DashboardCache.invalidate_all()
    :ok
  end

  describe "fetch_or_compute/2" do
    test "computes and stores on first call (cache miss)" do
      key = DashboardCache.build_key("user-1", "today", "Etc/UTC")
      call_count = :counters.new(1, [:atomics])

      result =
        DashboardCache.fetch_or_compute(key, fn ->
          :counters.add(call_count, 1, 1)
          %{metrics: %{requests: 42}, cost_series: [1, 2, 3]}
        end)

      assert result == %{metrics: %{requests: 42}, cost_series: [1, 2, 3]}
      assert :counters.get(call_count, 1) == 1
    end

    test "returns cached data on second call (cache hit, no recompute)" do
      key = DashboardCache.build_key("user-1", "today", "Etc/UTC")
      call_count = :counters.new(1, [:atomics])

      compute = fn ->
        :counters.add(call_count, 1, 1)
        %{metrics: %{requests: 99}}
      end

      first = DashboardCache.fetch_or_compute(key, compute)
      second = DashboardCache.fetch_or_compute(key, compute)

      assert first == %{metrics: %{requests: 99}}
      assert second == %{metrics: %{requests: 99}}
      # Compute fn called exactly once — second was a cache hit
      assert :counters.get(call_count, 1) == 1
    end

    test "different keys produce independent cache entries" do
      key_a = DashboardCache.build_key("user-1", "today", "Etc/UTC")
      key_b = DashboardCache.build_key("user-2", "today", "Etc/UTC")

      result_a = DashboardCache.fetch_or_compute(key_a, fn -> %{user: "a"} end)
      result_b = DashboardCache.fetch_or_compute(key_b, fn -> %{user: "b"} end)

      assert result_a == %{user: "a"}
      assert result_b == %{user: "b"}
    end

    test "same user, different period → different entries" do
      key_today = DashboardCache.build_key("user-1", "today", "Etc/UTC")
      key_7d = DashboardCache.build_key("user-1", "7d", "Etc/UTC")

      r1 = DashboardCache.fetch_or_compute(key_today, fn -> %{period: "today"} end)
      r2 = DashboardCache.fetch_or_compute(key_7d, fn -> %{period: "7d"} end)

      assert r1.period == "today"
      assert r2.period == "7d"
    end
  end

  describe "invalidate/1" do
    test "removes a single entry, next call recomputes" do
      key = DashboardCache.build_key("user-1", "today", "Etc/UTC")
      call_count = :counters.new(1, [:atomics])

      compute = fn ->
        :counters.add(call_count, 1, 1)
        %{data: :ok}
      end

      _ = DashboardCache.fetch_or_compute(key, compute)
      :ok = DashboardCache.invalidate(key)
      _ = DashboardCache.fetch_or_compute(key, compute)

      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "invalidate_all/0" do
    test "clears all entries" do
      k1 = DashboardCache.build_key("u1", "today", "Etc/UTC")
      k2 = DashboardCache.build_key("u2", "today", "Etc/UTC")

      _ = DashboardCache.fetch_or_compute(k1, fn -> %{a: 1} end)
      _ = DashboardCache.fetch_or_compute(k2, fn -> %{b: 2} end)

      :ok = DashboardCache.invalidate_all()

      assert DashboardCache.fetch(k1) == :miss
      assert DashboardCache.fetch(k2) == :miss
    end
  end

  describe "TTL expiry" do
    @tag :ttl
    test "entry expires after TTL and recomputes" do
      # Use a 1ms TTL for testing via config override
      # We can't easily override the config, so we test the read logic
      # directly: insert with an artificially old timestamp.
      key = DashboardCache.build_key("user-ttl", "today", "Etc/UTC")
      call_count = :counters.new(1, [:atomics])

      compute = fn ->
        :counters.add(call_count, 1, 1)
        %{v: :fresh}
      end

      # First call: miss → compute → store
      _ = DashboardCache.fetch_or_compute(key, compute)
      assert :counters.get(call_count, 1) == 1

      # Manually age the entry past TTL. We compute an expired timestamp
      # relative to the current monotonic time so it works regardless of
      # what epoch the BEAM uses for monotonic_time.
      expired_ts = System.monotonic_time(:millisecond) - DashboardCache.ttl_ms() - 1
      :ets.insert(:tokengate_dashboard_cache, {key, %{v: :stale}, expired_ts})

      # Second call: should be a miss (expired) → recompute
      result = DashboardCache.fetch_or_compute(key, compute)
      assert result == %{v: :fresh}
      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "build_key/3" do
    test "returns a 3-tuple" do
      key = DashboardCache.build_key("user-1", "7d", "America/Merida")
      assert key == {"user-1", "7d", "America/Merida"}
    end
  end
end
