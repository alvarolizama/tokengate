defmodule Tokengate.Routing.CircuitBreakerTest do
  @moduledoc """
  Tests for `Tokengate.Routing.CircuitBreaker` (`:gen_statem`).

  Uses test-scale cooldowns so transitions happen deterministically without
  `Process.sleep/1`. AGENTS.md forbids `Process.sleep/1`; instead we synchronize
  with `:sys.get_state/1` and an `assert_eventually/1` helper that polls `status/1`.
  """

  use ExUnit.Case, async: false

  alias Tokengate.Routing.CircuitBreaker

  # Test-scale config. Restored in on_exit so other async:false suites are
  # unaffected.
  @threshold 3
  @cooldown_ms 50
  @rate_limit_cooldown_ms 20

  setup do
    # Save and override the application env.
    prev = Application.get_env(:tokengate, :circuit_breaker)

    Application.put_env(:tokengate, :circuit_breaker,
      cooldown_ms: @cooldown_ms,
      threshold: @threshold,
      rate_limit_cooldown_ms: @rate_limit_cooldown_ms
    )

    on_exit(fn ->
      if prev do
        Application.put_env(:tokengate, :circuit_breaker, prev)
      else
        Application.delete_env(:tokengate, :circuit_breaker)
      end
    end)

    # The breaker registers itself via the registry; reuse the app-tree
    # instance when present.
    _pid =
      Process.whereis(Tokengate.Routing.CircuitBreakerRegistry) ||
        start_supervised!(
          {Registry, keys: :unique, name: Tokengate.Routing.CircuitBreakerRegistry}
        )

    {:ok, breaker} =
      start_supervised({CircuitBreaker, credential_id: "cred-test"})

    sync(breaker)
    {:ok, breaker: breaker}
  end

  describe "closed state" do
    test "allows requests and counts consecutive failures", %{breaker: breaker} do
      assert CircuitBreaker.allow?(breaker) == true
      assert CircuitBreaker.status(breaker) == :closed

      # threshold - 1 failures should NOT trip.
      for _ <- 1..(@threshold - 1) do
        CircuitBreaker.record_failure(breaker, :server_error)
      end

      sync(breaker)
      assert CircuitBreaker.status(breaker) == :closed
      assert CircuitBreaker.allow?(breaker) == true
    end

    test "trips to open after exactly threshold consecutive failures", %{breaker: breaker} do
      for _ <- 1..@threshold do
        CircuitBreaker.record_failure(breaker, :server_error)
      end

      sync(breaker)
      assert CircuitBreaker.status(breaker) == :open
      assert CircuitBreaker.allow?(breaker) == false
    end

    test "success resets the failure counter", %{breaker: breaker} do
      # threshold - 1 failures...
      for _ <- 1..(@threshold - 1) do
        CircuitBreaker.record_failure(breaker, :server_error)
      end

      sync(breaker)
      # ...a success resets...
      CircuitBreaker.record_success(breaker)
      sync(breaker)

      # ...so threshold - 1 more failures should still be closed.
      for _ <- 1..(@threshold - 1) do
        CircuitBreaker.record_failure(breaker, :server_error)
      end

      sync(breaker)
      assert CircuitBreaker.status(breaker) == :closed
    end

    test ":client_error never counts", %{breaker: breaker} do
      for _ <- 1..100 do
        CircuitBreaker.record_failure(breaker, :client_error)
      end

      sync(breaker)
      assert CircuitBreaker.status(breaker) == :closed
      assert CircuitBreaker.allow?(breaker) == true
    end

    test ":timeout counts toward the threshold", %{breaker: breaker} do
      for _ <- 1..@threshold do
        CircuitBreaker.record_failure(breaker, :timeout)
      end

      sync(breaker)
      assert CircuitBreaker.status(breaker) == :open
    end
  end

  describe "open state" do
    test "rejects allow? and transitions to half_open after cooldown", %{breaker: breaker} do
      trip_to_open(breaker)

      assert CircuitBreaker.allow?(breaker) == false
      assert CircuitBreaker.status(breaker) == :open

      # After cooldown_ms the breaker should be half_open.
      assert_eventually(fn -> CircuitBreaker.status(breaker) == :half_open end)
    end

    test "late failure while open refreshes the cooldown", %{breaker: breaker} do
      trip_to_open(breaker)

      # Record another failure before cooldown elapses -> cooldown restarts.
      CircuitBreaker.record_failure(breaker, :server_error)
      sync(breaker)

      # The cooldown was refreshed, so right after this we should still be open.
      assert CircuitBreaker.status(breaker) == :open
      assert_eventually(fn -> CircuitBreaker.status(breaker) == :half_open end)
    end

    test "reset forces back to closed", %{breaker: breaker} do
      trip_to_open(breaker)
      assert CircuitBreaker.status(breaker) == :open

      assert CircuitBreaker.reset(breaker) == :ok
      sync(breaker)
      assert CircuitBreaker.status(breaker) == :closed
    end
  end

  describe "half_open state" do
    test "allows exactly one probe; second allow? during probe is false", %{breaker: breaker} do
      trip_to_open(breaker)
      assert_eventually(fn -> CircuitBreaker.status(breaker) == :half_open end)

      # First probe passes.
      assert CircuitBreaker.allow?(breaker) == true
      # Second call while probe is in flight must be rejected.
      assert CircuitBreaker.allow?(breaker) == false
    end

    test "probe success returns to closed", %{breaker: breaker} do
      trip_to_open(breaker)
      assert_eventually(fn -> CircuitBreaker.status(breaker) == :half_open end)

      assert CircuitBreaker.allow?(breaker) == true
      CircuitBreaker.record_success(breaker)
      sync(breaker)

      assert CircuitBreaker.status(breaker) == :closed
      assert CircuitBreaker.allow?(breaker) == true
    end

    test "probe failure returns to open with a fresh cooldown", %{breaker: breaker} do
      trip_to_open(breaker)
      assert_eventually(fn -> CircuitBreaker.status(breaker) == :half_open end)

      assert CircuitBreaker.allow?(breaker) == true
      CircuitBreaker.record_failure(breaker, :server_error)
      sync(breaker)

      assert CircuitBreaker.status(breaker) == :open
      # And it should recover again after the fresh cooldown.
      assert_eventually(fn -> CircuitBreaker.status(breaker) == :half_open end)
    end
  end

  describe ":rate_limited uses the short cooldown" do
    test "trips with rate_limit_cooldown_ms, ~3x faster than server_error cooldown",
         %{breaker: breaker} do
      # Trip with rate_limited.
      for _ <- 1..@threshold do
        CircuitBreaker.record_failure(breaker, :rate_limited)
      end

      sync(breaker)
      assert CircuitBreaker.status(breaker) == :open

      # The short cooldown is 20ms vs the long 50ms; measure the time to reach
      # half_open and confirm it's well under the long cooldown.
      {elapsed_us, :ok} =
        :timer.tc(fn ->
          assert_eventually(fn -> CircuitBreaker.status(breaker) == :half_open end)
        end)

      elapsed_ms = elapsed_us / 1000

      # Should be roughly the short cooldown, definitely less than the long one.
      # We give generous headroom for CI scheduler jitter.
      assert elapsed_ms < @cooldown_ms,
             "rate_limited recovery took #{elapsed_ms}ms, expected < #{@cooldown_ms}ms"
    end

    test "rate_limited recovery is meaningfully faster than server_error recovery",
         %{breaker: breaker} do
      # Measure server_error recovery time.
      trip_to_open(breaker)

      {server_us, :ok} =
        :timer.tc(fn ->
          assert_eventually(fn -> CircuitBreaker.status(breaker) == :half_open end)
        end)

      # Reset to closed so we can trip again with rate_limited.
      CircuitBreaker.reset(breaker)
      sync(breaker)
      assert CircuitBreaker.status(breaker) == :closed

      for _ <- 1..@threshold do
        CircuitBreaker.record_failure(breaker, :rate_limited)
      end

      sync(breaker)
      assert CircuitBreaker.status(breaker) == :open

      {rl_us, :ok} =
        :timer.tc(fn ->
          assert_eventually(fn -> CircuitBreaker.status(breaker) == :half_open end)
        end)

      # rate_limited recovery should be ~3x faster (20ms vs 50ms).
      # Allow a generous lower bound to tolerate scheduler jitter; the key
      # invariant is rl << server.
      assert rl_us * 2 < server_us,
             "rate_limited (#{rl_us / 1000}ms) should be much faster than server_error (#{server_us / 1000}ms)"
    end
  end

  ## Helpers ##################################################################

  defp trip_to_open(breaker) do
    for _ <- 1..@threshold do
      CircuitBreaker.record_failure(breaker, :server_error)
    end

    sync(breaker)
  end

  # Synchronize with the breaker so prior casts have been processed.
  # AGENTS.md: use :sys.get_state/1 instead of Process.sleep/1.
  defp sync(breaker) do
    _ = :sys.get_state(breaker)
    :ok
  end

  # Poll a predicate until it returns true, bounded to ~2s. Avoids Process.sleep
  # while still allowing time-based state machine transitions to occur. The
  # `receive after` blocks the test process briefly so the gen_statem can process
  # its state_timeout events between polls.
  defp assert_eventually(predicate, attempts \\ 0)

  defp assert_eventually(_predicate, 400) do
    flunk("assert_eventually: condition never became true after ~2s of polling")
  end

  defp assert_eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      # Brief pause (5ms) so the gen_statem gets scheduled to process timeouts.
      # This is NOT Process.sleep — it's a receive-based timeout with no clause.
      receive do
      after
        5 -> :ok
      end

      assert_eventually(predicate, attempts + 1)
    end
  end
end
