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

  describe "sweep_expired/0" do
    test "removes entries past TTL and keeps fresh ones" do
      fresh_key = {:sweep_test, "fresh"}
      stale_key = {:sweep_test, "stale"}

      _ = DashboardCache.fetch_or_compute(fresh_key, fn -> %{fresh: true} end)

      # Age one entry past its deadline. Entries store an absolute
      # `expires_at` (monotonic ms) baked in at write time, so an already
      # expired deadline is just `now - 1`.
      expired_deadline = System.monotonic_time(:millisecond) - 1
      :ets.insert(:tokengate_dashboard_cache, {stale_key, %{stale: true}, expired_deadline})

      # Note: the owning GenServer also sweeps on its own timer, so we can't
      # assert on the returned count (it may have reaped the stale entry
      # first). The invariant is: after sweep_expired/0, stale is gone and
      # fresh survives.
      _removed = DashboardCache.sweep_expired()

      assert DashboardCache.fetch(fresh_key) == {:ok, %{fresh: true}}
      assert DashboardCache.fetch(stale_key) == :miss
    end

    test "is safe to call on an empty table" do
      DashboardCache.invalidate_all()
      assert DashboardCache.sweep_expired() == 0
    end
  end

  describe "TTL expiry" do
    @tag :ttl
    test "entry expires after TTL and recomputes" do
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

      # Manually age the entry past its deadline. Entries store an absolute
      # `expires_at` (monotonic ms) baked in at write time; an already
      # expired deadline is just `now - 1`, relative to the current
      # monotonic time so it works regardless of what epoch the BEAM uses.
      expired_deadline = System.monotonic_time(:millisecond) - 1
      :ets.insert(:tokengate_dashboard_cache, {key, %{v: :stale}, expired_deadline})

      # Second call: should be a miss (expired) → recompute
      result = DashboardCache.fetch_or_compute(key, compute)
      assert result == %{v: :fresh}
      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "single-flight" do
    test "concurrent misses on the same key compute once and share the result" do
      key = {:single_flight, System.unique_integer([:positive])}
      call_count = :counters.new(1, [:atomics])

      compute = fn ->
        :counters.add(call_count, 1, 1)
        # Wide enough that every waiter is still blocked when the holder
        # publishes the value.
        Process.sleep(150)
        %{v: :shared}
      end

      results =
        1..10
        |> Enum.map(fn _ ->
          Task.async(fn -> DashboardCache.fetch_or_compute(key, compute) end)
        end)
        |> Task.await_many(5_000)

      assert Enum.uniq(results) == [%{v: :shared}]
      assert :counters.get(call_count, 1) == 1
      assert DashboardCache.fetch(key) == {:ok, %{v: :shared}}
    end

    test "a crashing compute releases the placeholder (no wedged key)" do
      key = {:single_flight_crash, System.unique_integer([:positive])}

      assert_raise RuntimeError, "boom", fn ->
        DashboardCache.fetch_or_compute(key, fn -> raise "boom" end, ttl: 60_000)
      end

      # The next caller must recompute immediately, not wait out the TTL.
      assert DashboardCache.fetch_or_compute(key, fn -> %{recovered: true} end, ttl: 60_000) ==
               %{recovered: true}
    end

    test "a holder killed by an external exit signal releases the lock via monitor" do
      # The LiveView async-cancel path is Process.exit(pid, reason): the
      # holder's `after` clause never runs, so without the DOWN monitor the
      # placeholder would wedge the key for the whole TTL.
      key = {:single_flight_exit, System.unique_integer([:positive])}

      holder =
        spawn(fn ->
          DashboardCache.fetch_or_compute(key, fn -> Process.sleep(10_000) end, ttl: 60_000)
        end)

      # Wait until the lock is actually taken before killing the holder.
      wait_until(fn ->
        match?([_], :ets.lookup(:tokengate_dashboard_cache, {:__computing__, key}))
      end)

      Process.exit(holder, {:shutdown, :cancel})

      {elapsed, result} =
        :timer.tc(fn ->
          DashboardCache.fetch_or_compute(key, fn -> %{recovered: true} end, ttl: 60_000)
        end)

      assert result == %{recovered: true}
      # :timer.tc measures microseconds. Generous bound: must not wait out the
      # TTL (60s) — the monitor releases the lock in a few ms.
      assert elapsed < 15_000_000
      refute match?([_], :ets.lookup(:tokengate_dashboard_cache, {:__computing__, key}))
    end
  end

  describe "build_key/3" do
    test "returns a 3-tuple" do
      key = DashboardCache.build_key("user-1", "7d", "America/Merida")
      assert key == {"user-1", "7d", "America/Merida"}
    end
  end

  defp wait_until(fun, tries \\ 100)

  defp wait_until(_fun, 0), do: flunk("condition never became true")

  defp wait_until(fun, tries) do
    if fun.(), do: :ok, else: Process.sleep(10) && wait_until(fun, tries - 1)
  end
end
