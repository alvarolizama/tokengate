defmodule Tokengate.Routing.CircuitBreakerManagerTest do
  @moduledoc """
  Tests for `Tokengate.Routing.CircuitBreakerManager` (DynamicSupervisor + Registry).
  """

  use ExUnit.Case, async: false

  alias Tokengate.Routing.CircuitBreakerManager

  @threshold 3
  @cooldown_ms 50
  @rate_limit_cooldown_ms 20

  # Credential ids are :binary_id (UUIDs) in production, and the breaker
  # Registry is a named singleton shared across test files. Using real UUIDs
  # here means any breaker left registered (e.g. left open by a test) stays
  # castable by Ecto in other LiveView tests that sweep the Registry
  # (CircuitBreakerManager.status_all/open_breakers) — a string like
  # "cred-open" would fail to dump to :binary_id and poison those tests.
  defp credential, do: Ecto.UUID.generate()

  setup do
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

    _pid =
      Process.whereis(Tokengate.Routing.CircuitBreakerRegistry) ||
        start_supervised!(
          {Registry, keys: :unique, name: Tokengate.Routing.CircuitBreakerRegistry}
        )

    _pid = Process.whereis(CircuitBreakerManager) || start_supervised!(CircuitBreakerManager)

    :ok
  end

  describe "ensure_started/1" do
    test "starts a breaker and returns :ok" do
      credential = credential()
      assert CircuitBreakerManager.ensure_started(credential) == :ok
      assert CircuitBreakerManager.status(credential) == :closed
    end

    test "is idempotent" do
      credential = credential()
      assert CircuitBreakerManager.ensure_started(credential) == :ok
      assert CircuitBreakerManager.ensure_started(credential) == :ok
      assert CircuitBreakerManager.ensure_started(credential) == :ok
      assert CircuitBreakerManager.status(credential) == :closed
    end

    test "is safe under concurrent access from 50 tasks" do
      credential = credential()

      Task.async_stream(
        1..50,
        fn _i ->
          CircuitBreakerManager.ensure_started(credential)
        end,
        timeout: :infinity
      )
      |> Stream.run()

      # Exactly one breaker should be registered.
      assert Registry.lookup(Tokengate.Routing.CircuitBreakerRegistry, credential)
             |> length() == 1

      assert CircuitBreakerManager.status(credential) == :closed
    end
  end

  describe "allow?/1" do
    test "unknown credential returns true (lazily starts in closed)" do
      credential = credential()
      assert CircuitBreakerManager.allow?(credential) == true
      # The breaker was started as a side effect.
      assert CircuitBreakerManager.status(credential) == :closed
    end

    test "open credential returns false" do
      credential = credential()

      for _ <- 1..@threshold do
        CircuitBreakerManager.record_failure(credential, :server_error)
      end

      assert CircuitBreakerManager.status(credential) == :open
      assert CircuitBreakerManager.allow?(credential) == false
    end
  end

  describe "record_success/1 and record_failure/2" do
    test "success resets the failure counter" do
      credential = credential()

      for _ <- 1..(@threshold - 1) do
        CircuitBreakerManager.record_failure(credential, :server_error)
      end

      CircuitBreakerManager.record_success(credential)
      assert CircuitBreakerManager.status(credential) == :closed

      for _ <- 1..(@threshold - 1) do
        CircuitBreakerManager.record_failure(credential, :server_error)
      end

      assert CircuitBreakerManager.status(credential) == :closed
    end

    test ":client_error never counts" do
      credential = credential()

      for _ <- 1..100 do
        CircuitBreakerManager.record_failure(credential, :client_error)
      end

      assert CircuitBreakerManager.status(credential) == :closed
      assert CircuitBreakerManager.allow?(credential) == true
    end

    test "record_failure on a new credential ensures a breaker is started" do
      credential = credential()

      CircuitBreakerManager.record_failure(credential, :server_error)
      assert CircuitBreakerManager.status(credential) == :closed

      for _ <- 1..(@threshold - 1) do
        CircuitBreakerManager.record_failure(credential, :server_error)
      end

      assert CircuitBreakerManager.status(credential) == :open
    end
  end

  describe "status/1" do
    test "returns :closed for an unknown credential without starting a process" do
      credential = credential()
      assert CircuitBreakerManager.status(credential) == :closed

      # Confirm no process was lazily started.
      assert Registry.lookup(Tokengate.Routing.CircuitBreakerRegistry, credential) == []
    end

    test "tracks the full lifecycle through the manager" do
      credential = credential()

      assert CircuitBreakerManager.status(credential) == :closed

      for _ <- 1..@threshold do
        CircuitBreakerManager.record_failure(credential, :server_error)
      end

      assert CircuitBreakerManager.status(credential) == :open
      assert CircuitBreakerManager.allow?(credential) == false

      assert_eventually(fn -> CircuitBreakerManager.status(credential) == :half_open end)

      # Probe succeeds.
      assert CircuitBreakerManager.allow?(credential) == true
      CircuitBreakerManager.record_success(credential)
      assert CircuitBreakerManager.status(credential) == :closed
    end
  end

  describe "reset/1" do
    test "forces an open breaker back to closed" do
      credential = credential()

      for _ <- 1..@threshold do
        CircuitBreakerManager.record_failure(credential, :server_error)
      end

      assert CircuitBreakerManager.status(credential) == :open
      assert CircuitBreakerManager.reset(credential) == :ok
      assert CircuitBreakerManager.status(credential) == :closed
    end

    test "is a no-op when the breaker does not exist" do
      assert CircuitBreakerManager.reset(credential()) == :ok
    end
  end

  ## Helpers ##################################################################

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
