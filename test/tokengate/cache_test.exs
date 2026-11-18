defmodule Tokengate.CacheTest do
  @moduledoc """
  Single-flight behavior of `Tokengate.Cache.fetch/3` — the generic ETS cache
  behind the observability destinations (read once per request log).

  `async: false`: the table is a named singleton shared by the whole VM.
  """

  use ExUnit.Case, async: false
  alias Tokengate.Cache

  setup do
    pid = Process.whereis(Cache) || start_supervised!(Cache)
    _ = :sys.get_state(pid)
    Cache.invalidate_all()
    :ok
  end

  describe "fetch/3" do
    test "computes once and serves the cached value afterwards" do
      key = {:cache_test, System.unique_integer([:positive])}
      call_count = :counters.new(1, [:atomics])

      compute = fn ->
        :counters.add(call_count, 1, 1)
        %{v: :cached}
      end

      assert Cache.fetch(key, 1_000, compute) == %{v: :cached}
      assert Cache.fetch(key, 1_000, compute) == %{v: :cached}
      assert :counters.get(call_count, 1) == 1
    end

    test "caches nil values too (no accidental re-computation)" do
      key = {:cache_test, :nil_value, System.unique_integer([:positive])}
      call_count = :counters.new(1, [:atomics])

      compute = fn ->
        :counters.add(call_count, 1, 1)
        nil
      end

      assert Cache.fetch(key, 1_000, compute) == nil
      assert Cache.fetch(key, 1_000, compute) == nil
      assert :counters.get(call_count, 1) == 1
    end
  end

  describe "single-flight" do
    test "concurrent misses on the same key compute once and share the value" do
      key = {:cache_single_flight, System.unique_integer([:positive])}
      call_count = :counters.new(1, [:atomics])

      compute = fn ->
        :counters.add(call_count, 1, 1)
        # Wide enough that every waiter is still blocked when the holder
        # publishes the value.
        Process.sleep(50)
        %{v: :shared}
      end

      results =
        1..10
        |> Enum.map(fn _ -> Task.async(fn -> Cache.fetch(key, 5_000, compute) end) end)
        |> Task.await_many(5_000)

      assert Enum.uniq(results) == [%{v: :shared}]
      assert :counters.get(call_count, 1) == 1
      assert :ets.lookup(Cache.table(), {:__computing__, key}) == []
    end

    test "a crashing compute releases the placeholder (no wedged key)" do
      key = {:cache_single_flight_crash, System.unique_integer([:positive])}

      assert_raise RuntimeError, "boom", fn ->
        Cache.fetch(key, 60_000, fn -> raise "boom" end)
      end

      assert Cache.fetch(key, 60_000, fn -> %{recovered: true} end) == %{recovered: true}
      assert :ets.lookup(Cache.table(), {:__computing__, key}) == []
    end

    test "a holder killed by an external exit signal releases the lock via monitor" do
      key = {:cache_single_flight_exit, System.unique_integer([:positive])}
      test_pid = self()

      # The holder announces itself from INSIDE the compute fun: the
      # placeholder is inserted before the fun runs, so the message proves the
      # lock is in ETS without a polling loop guessing at it.
      holder =
        spawn(fn ->
          Cache.fetch(key, 60_000, fn ->
            send(test_pid, :holder_computing)
            Process.sleep(10_000)
          end)
        end)

      assert_receive :holder_computing, 5_000
      assert match?([_], :ets.lookup(Cache.table(), {:__computing__, key}))

      # Monitor first, then kill: the DOWN proves the holder is gone before the
      # recovery fetch starts, so a slow scheduler cannot make the fetch see a
      # live owner and burn its capped wait window.
      ref = Process.monitor(holder)
      Process.exit(holder, {:shutdown, :cancel})
      assert_receive {:DOWN, ^ref, :process, ^holder, _reason}, 5_000

      {elapsed, value} =
        :timer.tc(fn -> Cache.fetch(key, 60_000, fn -> %{recovered: true} end) end)

      assert value == %{recovered: true}
      # The lock must NOT wait out the TTL (60s). Avoid asserting a few-ms
      # scheduler deadline here: under the full suite's load that measures CI
      # scheduling, not monitor cleanup. This still catches a forgotten
      # release/fallback-to-TTL regression.
      assert div(elapsed, 1000) < 5_000
      refute match?([_], :ets.lookup(Cache.table(), {:__computing__, key}))
    end
  end

  describe "invalidate/1" do
    test "removes a single entry, next fetch recomputes" do
      key = {:cache_test, :invalidate, System.unique_integer([:positive])}
      call_count = :counters.new(1, [:atomics])

      compute = fn ->
        :counters.add(call_count, 1, 1)
        :value
      end

      assert Cache.fetch(key, 1_000, compute) == :value
      assert Cache.invalidate(key) == :ok
      assert Cache.fetch(key, 1_000, compute) == :value
      assert :counters.get(call_count, 1) == 2
    end
  end
end
