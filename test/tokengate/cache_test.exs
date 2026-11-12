defmodule Tokengate.CacheTest do
  @moduledoc """
  Single-flight behavior of `Tokengate.Cache.fetch/3` — the generic ETS cache
  behind the exemption set and the observability destinations (both read on
  every proxied request).

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

      holder = spawn(fn -> Cache.fetch(key, 60_000, fn -> Process.sleep(10_000) end) end)

      wait_until(fn ->
        match?([_], :ets.lookup(Cache.table(), {:__computing__, key}))
      end)

      Process.exit(holder, {:shutdown, :cancel})

      {elapsed, value} =
        :timer.tc(fn -> Cache.fetch(key, 60_000, fn -> %{recovered: true} end) end)

      assert value == %{recovered: true}
      # Microseconds: must not wait out the TTL (60s) nor the full 200ms poll
      # window — the monitor releases the lock in a few ms.
      assert div(elapsed, 1000) < 200
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

  defp wait_until(fun, tries \\ 100)

  defp wait_until(_fun, 0), do: flunk("condition never became true")

  defp wait_until(fun, tries) do
    if fun.(), do: :ok, else: Process.sleep(5) && wait_until(fun, tries - 1)
  end
end
