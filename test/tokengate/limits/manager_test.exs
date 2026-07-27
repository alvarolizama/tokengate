defmodule Tokengate.Limits.ManagerTest do
  @moduledoc """
  Tests for Tokengate.Limits.Manager — ETS sliding-window RPM +
  in-flight concurrency gate.

  `async: false` because the ETS tables (`:tokengate_rpm_buckets`,
  `:tokengate_inflight`) are named (singleton) tables; concurrent tests
  would clobber each other's counters. Each test uses a unique
  `api_key_id` via `System.unique_integer/0` to avoid inter-test
  contamination even within the serial run.
  """

  use ExUnit.Case, async: false

  alias Tokengate.Limits.Manager

  @rpm_table :tokengate_rpm_buckets

  setup do
    # Reuse the app-tree manager when present; tests use unique keys so the
    # shared ETS tables don't collide.
    pid = Process.whereis(Manager) || start_supervised!(Manager)
    _ = :sys.get_state(pid)
    :ok
  end

  defp unique_key do
    "key-#{System.unique_integer([:positive])}"
  end

  # --- RPM / sliding window ---

  describe "check_rate/2 — RPM sliding window" do
    test "under limit returns :ok repeatedly" do
      key = unique_key()

      for _ <- 1..5 do
        assert :ok = Manager.check_rate(key, 10)
      end
    end

    test "hitting exactly the limit then next is rate-limited" do
      key = unique_key()
      limit = 3

      for _ <- 1..limit do
        assert :ok = Manager.check_rate(key, limit)
      end

      assert {:error, :rate_limited, ms} = Manager.check_rate(key, limit)
      assert ms > 0
    end

    test "nil limit is unlimited (1000 calls ok)" do
      key = unique_key()

      for _ <- 1..1000 do
        assert :ok = Manager.check_rate(key, nil)
      end
    end

    test "different keys are independent" do
      key1 = unique_key()
      key2 = unique_key()

      for _ <- 1..3 do
        assert :ok = Manager.check_rate(key1, 3)
      end

      # key1 is saturated; key2 is untouched
      assert {:error, :rate_limited, _} = Manager.check_rate(key1, 3)
      assert :ok = Manager.check_rate(key2, 3)
      assert :ok = Manager.check_rate(key2, 3)
      assert :ok = Manager.check_rate(key2, 3)
      assert {:error, :rate_limited, _} = Manager.check_rate(key2, 3)
    end

    test "window slides — weighted count from previous bucket decays" do
      key = unique_key()
      now = System.system_time(:second)
      current_bucket = div(now, 60)
      prev_bucket = current_bucket - 1
      elapsed = rem(now, 60)

      # Seed the previous bucket with 6 requests. With limit 10:
      # weighted_prev = floor(6 * (60 - elapsed) / 60).
      # If elapsed is small, weighted_prev is near 6, so we have ~4 free slots.
      # If elapsed is large, weighted_prev is small, so more free slots.
      :ets.insert(@rpm_table, {{key, prev_bucket}, 6})

      weighted_prev = div(6 * (60 - elapsed), 60)
      free_slots = max(0, 10 - weighted_prev)

      # We should be able to make free_slots calls before being limited.
      # Because the counter increments on each :ok, we expect free_slots
      # successes and then a rate-limit (assuming free_slots > 0).
      successes =
        Enum.reduce_while(1..(free_slots + 5), 0, fn _, acc ->
          case Manager.check_rate(key, 10) do
            :ok -> {:cont, acc + 1}
            {:error, :rate_limited, _} -> {:halt, acc}
          end
        end)

      assert successes == free_slots
    end

    test "retry_after_ms is at least 1000" do
      key = unique_key()

      for _ <- 1..3 do
        assert :ok = Manager.check_rate(key, 3)
      end

      assert {:error, :rate_limited, ms} = Manager.check_rate(key, 3)
      assert ms >= 1000
    end
  end

  describe "acquire_concurrency/2 — in-flight gate" do
    test "acquire up to limit ok, limit+1 rejected" do
      key = unique_key()

      for _ <- 1..5 do
        assert :ok = Manager.acquire_concurrency(key, 5)
      end

      assert {:error, :concurrency_exceeded} = Manager.acquire_concurrency(key, 5)
    end

    test "release re-enables acquisition" do
      key = unique_key()

      for _ <- 1..3 do
        assert :ok = Manager.acquire_concurrency(key, 3)
      end

      assert {:error, :concurrency_exceeded} = Manager.acquire_concurrency(key, 3)
      assert :ok = Manager.release_concurrency(key)
      assert :ok = Manager.acquire_concurrency(key, 3)
    end

    test "release at 0 stays 0 (does not go negative)" do
      key = unique_key()

      assert :ok = Manager.release_concurrency(key)
      assert Manager.current_concurrency(key) == 0

      assert :ok = Manager.release_concurrency(key)
      assert Manager.current_concurrency(key) == 0
    end

    test "current_concurrency is accurate" do
      key = unique_key()

      assert Manager.current_concurrency(key) == 0
      assert :ok = Manager.acquire_concurrency(key, 5)
      assert Manager.current_concurrency(key) == 1
      assert :ok = Manager.acquire_concurrency(key, 5)
      assert Manager.current_concurrency(key) == 2
      assert :ok = Manager.release_concurrency(key)
      assert Manager.current_concurrency(key) == 1
    end

    test "nil limit is unlimited (still tracks count)" do
      key = unique_key()

      for _ <- 1..100 do
        assert :ok = Manager.acquire_concurrency(key, nil)
      end

      assert Manager.current_concurrency(key) == 100
    end

    test "concurrent acquirers never exceed limit (50 racing on limit 10)" do
      key = unique_key()
      limit = 10

      results =
        1..50
        |> Task.async_stream(
          fn _ -> Manager.acquire_concurrency(key, limit) end,
          timeout: :infinity,
          max_concurrency: 50
        )
        |> Enum.map(fn {:ok, result} -> result end)

      successes = Enum.count(results, &(&1 == :ok))
      assert successes == limit
    end
  end

  describe "acquire/2 — combined rate + concurrency" do
    test "rate failure returns rate error without consuming concurrency" do
      key = unique_key()
      rpm = 2
      conc = 5

      # Saturate the rate limit.
      assert :ok = Manager.acquire(key, %{rpm_limit: rpm, concurrency_limit: conc})
      assert :ok = Manager.acquire(key, %{rpm_limit: rpm, concurrency_limit: conc})

      # Third call should fail on rate, NOT consume a concurrency slot.
      assert {:error, :rate_limited, _ms} =
               Manager.acquire(key, %{rpm_limit: rpm, concurrency_limit: conc})

      # Concurrency count should still be 2 (the two successful acquires).
      assert Manager.current_concurrency(key) == 2
    end

    test "concurrency failure returns concurrency error" do
      key = unique_key()
      rpm = 100
      conc = 2

      assert :ok = Manager.acquire(key, %{rpm_limit: rpm, concurrency_limit: conc})
      assert :ok = Manager.acquire(key, %{rpm_limit: rpm, concurrency_limit: conc})

      assert {:error, :concurrency_exceeded} =
               Manager.acquire(key, %{rpm_limit: rpm, concurrency_limit: conc})

      # Rate was checked first and succeeded, so the rate counter advanced.
      # Concurrency is at the limit (2).
      assert Manager.current_concurrency(key) == 2
    end

    test "release/1 releases concurrency slot" do
      key = unique_key()

      assert :ok = Manager.acquire(key, %{rpm_limit: 100, concurrency_limit: 1})

      assert {:error, :concurrency_exceeded} =
               Manager.acquire(key, %{rpm_limit: 100, concurrency_limit: 1})

      assert :ok = Manager.release(key)
      assert :ok = Manager.acquire(key, %{rpm_limit: 100, concurrency_limit: 1})
    end
  end

  describe "total_inflight/0" do
    test "sums in-flight counts across keys" do
      key_a = unique_key()
      key_b = unique_key()
      base = Manager.total_inflight()

      assert :ok = Manager.acquire(key_a, %{rpm_limit: 100, concurrency_limit: 10})
      assert :ok = Manager.acquire(key_a, %{rpm_limit: 100, concurrency_limit: 10})
      assert :ok = Manager.acquire(key_b, %{rpm_limit: 100, concurrency_limit: 10})

      assert Manager.total_inflight() == base + 3

      assert :ok = Manager.release(key_a)
      assert Manager.total_inflight() == base + 2

      # Cleanup so other tests see the same baseline
      assert :ok = Manager.release(key_a)
      assert :ok = Manager.release(key_b)
      assert Manager.total_inflight() == base
    end
  end

  describe "sweep — GenServer cleanup" do
    test "old bucket is swept away, recent bucket is kept" do
      key = unique_key()
      now = System.system_time(:second)
      current_bucket = div(now, 60)

      old_bucket = current_bucket - 3
      recent_bucket = current_bucket - 1

      # Insert a fake old bucket (3 minutes ago — older than 2-minute retention)
      # and a recent one (1 minute ago).
      :ets.insert(@rpm_table, {{key, old_bucket}, 5})
      :ets.insert(@rpm_table, {{key, recent_bucket}, 3})

      # Sanity: both present.
      assert :ets.lookup(@rpm_table, {key, old_bucket}) != []
      assert :ets.lookup(@rpm_table, {key, recent_bucket}) != []

      # Trigger the sweep synchronously by sending the message and then
      # waiting for the GenServer to process it via :sys.get_state.
      pid = GenServer.whereis(Manager)
      Process.send(pid, :sweep, [])
      _ = :sys.get_state(pid)

      # Old bucket gone, recent kept.
      assert :ets.lookup(@rpm_table, {key, old_bucket}) == []
      assert :ets.lookup(@rpm_table, {key, recent_bucket}) != []
    end
  end
end
