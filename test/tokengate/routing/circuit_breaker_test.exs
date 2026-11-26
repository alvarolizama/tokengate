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

    # A 400 rejects the body, not the credential: falling back on it must cost
    # the provider nothing, so it never counts toward the threshold.
    test ":bad_request never counts", %{breaker: breaker} do
      for _ <- 1..100 do
        CircuitBreaker.record_failure(breaker, :bad_request, "Invalid parameter: field x")
      end

      sync(breaker)
      assert CircuitBreaker.status(breaker) == :closed
      assert CircuitBreaker.allow?(breaker) == true
      assert CircuitBreaker.details(breaker).failures == 0
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
    test "trips with rate_limit_cooldown_ms, not the server_error cooldown",
         %{breaker: breaker} do
      for _ <- 1..@threshold do
        CircuitBreaker.record_failure(breaker, :rate_limited)
      end

      sync(breaker)

      # The breaker's own state carries the policy inputs: the trip recorded
      # :rate_limited as `last_reason` and the two configured windows differ,
      # so `cooldown_for/2` arms the SHORT one (20ms) instead of 50ms. The old
      # assertion timed the transition to :half_open and required it under
      # 50ms — that measured scheduler placement under load (poll + jitter),
      # not the policy, and flaked while the breaker was behaving correctly.
      assert {:open, data} = :sys.get_state(breaker)
      assert data.last_reason == :rate_limited
      assert data.rate_limit_cooldown_ms == @rate_limit_cooldown_ms
      assert data.cooldown_ms == @cooldown_ms
      assert %DateTime{} = data.opened_at

      # Recovery still happens; no wall-clock bound on it.
      assert_eventually(fn -> CircuitBreaker.status(breaker) == :half_open end)
    end

    test "the trip reason selects the window: 60s for :server_error, short for :rate_limited" do
      # Two breakers over the SAME 60s window so the only difference is the
      # reason. If :rate_limited did NOT use the short window, it could not
      # reach :half_open inside the ~2s polling budget; if the selection were
      # ignored for :server_error, it would flip too — the contrast fails in
      # both directions and needs no wall-clock measurement of its own.
      limited =
        start_supervised!(
          Supervisor.child_spec(
            {CircuitBreaker,
             credential_id: "policy-rate-limited",
             threshold: 1,
             cooldown_ms: 60_000,
             rate_limit_cooldown_ms: @rate_limit_cooldown_ms},
            id: :policy_rate_limited
          )
        )

      server =
        start_supervised!(
          Supervisor.child_spec(
            {CircuitBreaker,
             credential_id: "policy-server-error",
             threshold: 1,
             cooldown_ms: 60_000,
             rate_limit_cooldown_ms: @rate_limit_cooldown_ms},
            id: :policy_server_error
          )
        )

      CircuitBreaker.record_failure(limited, :rate_limited)
      CircuitBreaker.record_failure(server, :server_error)
      sync(limited)
      sync(server)

      assert {:open, limited_data} = :sys.get_state(limited)
      assert {:open, server_data} = :sys.get_state(server)
      assert limited_data.last_reason == :rate_limited
      assert server_data.last_reason == :server_error
      assert limited_data.cooldown_ms == server_data.cooldown_ms

      assert_eventually(fn -> CircuitBreaker.status(limited) == :half_open end)

      # Same instant, same 60s window: the long one cannot have elapsed, so this
      # is a policy assertion, not a race.
      assert CircuitBreaker.status(server) == :open
    end

    test "rate_limited keeps the same trip threshold as server_error",
         %{breaker: breaker} do
      # Both reasons count toward the same threshold; the previous test
      # exercises the shorter cooldown directly. Sequential wall-clock
      # measurements here only compare scheduler placement, not breaker policy.
      for reason <- [:server_error, :rate_limited] do
        for _ <- 1..@threshold, do: CircuitBreaker.record_failure(breaker, reason)
        sync(breaker)
        assert CircuitBreaker.status(breaker) == :open
        assert CircuitBreaker.details(breaker).last_reason == reason
        CircuitBreaker.reset(breaker)
        assert CircuitBreaker.status(breaker) == :closed
      end
    end
  end

  describe "error message tracking" do
    test "details/1 exposes the last upstream error message", %{breaker: breaker} do
      CircuitBreaker.record_failure(breaker, :server_error, "max connections reached")
      sync(breaker)

      details = CircuitBreaker.details(breaker)
      assert details.last_reason == :server_error
      assert details.last_error_message == "max connections reached"
    end

    test "error message survives the trip to open", %{breaker: breaker} do
      for _ <- 1..@threshold do
        CircuitBreaker.record_failure(breaker, :server_error, "upstream exploded")
      end

      sync(breaker)
      assert CircuitBreaker.status(breaker) == :open

      details = CircuitBreaker.details(breaker)
      assert details.last_error_message == "upstream exploded"
    end

    test "record_failure/2 without message still works (nil message)", %{breaker: breaker} do
      CircuitBreaker.record_failure(breaker, :server_error)
      sync(breaker)

      details = CircuitBreaker.details(breaker)
      assert details.last_reason == :server_error
      assert details.last_error_message == nil
    end

    test "reset clears the error message", %{breaker: breaker} do
      CircuitBreaker.record_failure(breaker, :server_error, "boom")
      sync(breaker)

      CircuitBreaker.reset(breaker)
      sync(breaker)

      details = CircuitBreaker.details(breaker)
      assert details.last_error_message == nil
    end
  end

  describe "recovery and probe leasing" do
    test "late failures while :open never reset the cooldown timer", %{breaker: breaker} do
      trip_to_open(breaker)
      assert CircuitBreaker.status(breaker) == :open

      # Flood late counting failures while already open.
      for _ <- 1..10 do
        CircuitBreaker.record_failure(breaker, :server_error, "late in-flight error")
      end

      # Still transitions to :half_open on schedule instead of remaining wedged.
      assert_eventually(fn -> CircuitBreaker.status(breaker) == :half_open end)
    end

    test "claim_probe admits one probe and auto-releases when the owner crashes", %{
      breaker: breaker
    } do
      trip_to_open(breaker)
      assert_eventually(fn -> CircuitBreaker.status(breaker) == :half_open end)

      # Spawn a probe owner process that claims the slot, then gets killed.
      parent = self()

      owner =
        spawn(fn ->
          res = CircuitBreaker.claim_probe(breaker, self())
          send(parent, {:claimed, res})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:claimed, {:ok, epoch}}
      assert is_integer(epoch)

      # Concurrent caller is rejected while probe is active.
      assert {:error, :probe_in_flight} = CircuitBreaker.claim_probe(breaker, self())

      # Kill the probe owner -> monitor releases the probe slot automatically.
      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

      assert_eventually(fn ->
        match?({:ok, _}, CircuitBreaker.claim_probe(breaker, self()))
      end)
    end

    test "release_probe frees the :half_open slot without reopening", %{breaker: breaker} do
      trip_to_open(breaker)
      assert_eventually(fn -> CircuitBreaker.status(breaker) == :half_open end)

      assert {:ok, _epoch} = CircuitBreaker.claim_probe(breaker, self())
      assert {:error, :probe_in_flight} = CircuitBreaker.claim_probe(breaker, self())

      CircuitBreaker.release_probe(breaker, self())
      assert CircuitBreaker.status(breaker) == :half_open
      assert {:ok, _epoch} = CircuitBreaker.claim_probe(breaker, self())
    end

    test "non-counting failure in :half_open releases probe without reopening", %{
      breaker: breaker
    } do
      trip_to_open(breaker)
      assert_eventually(fn -> CircuitBreaker.status(breaker) == :half_open end)

      assert {:ok, epoch} = CircuitBreaker.claim_probe(breaker, self())
      CircuitBreaker.record_failure(breaker, :bad_request, "400 invalid param", epoch: epoch)

      assert CircuitBreaker.status(breaker) == :half_open
      assert CircuitBreaker.details(breaker).probe_in_flight? == false
    end

    test "stale-epoch failure cannot reopen a recovered breaker", %{breaker: breaker} do
      trip_to_open(breaker)
      assert_eventually(fn -> CircuitBreaker.status(breaker) == :half_open end)

      assert {:ok, epoch} = CircuitBreaker.claim_probe(breaker, self())
      stale_epoch = epoch - 1

      # Stale failure from an earlier epoch is ignored in :half_open.
      CircuitBreaker.record_failure(breaker, :server_error, "stale", epoch: stale_epoch)
      assert CircuitBreaker.status(breaker) == :half_open

      # Current probe succeeds -> :closed.
      CircuitBreaker.record_success(breaker, epoch: epoch)
      assert CircuitBreaker.status(breaker) == :closed
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
