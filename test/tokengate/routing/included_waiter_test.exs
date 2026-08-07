defmodule Tokengate.Routing.IncludedWaiterTest do
  use ExUnit.Case, async: true

  alias Tokengate.Routing.IncludedWaiter

  setup do
    # Clean up any waiter entries from previous tests
    if :ets.whereis(:tokengate_included_waiters) != :undefined do
      :ets.delete_all_objects(:tokengate_included_waiters)
    end

    # Initialize limits ETS tables
    if :ets.whereis(:tokengate_inflight) == :undefined do
      :ets.new(:tokengate_inflight, [:set, :public, :named_table, write_concurrency: true])
    else
      :ets.delete_all_objects(:tokengate_inflight)
    end

    {:ok, %{}}
  end

  describe "wait_for_slot/3" do
    test "returns :ok immediately when a slot is free" do
      assert :ok =
               IncludedWaiter.wait_for_slot("cred-a", 5, 5_000)
    end

    test "waits and gets notified when a slot is freed via Limits.release" do
      cred_id = "cred-b2"
      limit = 1

      # Saturate the credential with one request
      assert :ok = Tokengate.Limits.Manager.acquire_concurrency(cred_id, limit)

      # The second request goes to the waiter queue
      task =
        Task.async(fn ->
          IncludedWaiter.wait_for_slot(cred_id, limit, 5_000)
        end)

      # Give the task time to register in the queue
      Process.sleep(50)

      # Release the slot — this calls notify_slot automatically
      Tokengate.Limits.Manager.release(cred_id)

      assert {:ok, :ok} = Task.yield(task, 2_000)
    end

    test "returns queue_timeout when no slot is freed in time" do
      cred_id = "cred-c"
      limit = 1

      # Saturate the credential
      assert :ok = Tokengate.Limits.Manager.acquire_concurrency(cred_id, limit)

      assert {:error, :queue_timeout} =
               IncludedWaiter.wait_for_slot(cred_id, limit, 50)
    end

    test "notify_slot is a no-op with no waiters" do
      assert :ok = IncludedWaiter.notify_slot("nonexistent")
    end

    test "dead waiter is skipped and next waiter gets the slot" do
      cred_id = "cred-dead"
      limit = 1

      # Saturate
      assert :ok = Tokengate.Limits.Manager.acquire_concurrency(cred_id, limit)

      # Start a waiter, then kill it
      dead_task =
        Task.async(fn ->
          IncludedWaiter.wait_for_slot(cred_id, limit, 5_000)
        end)

      Process.sleep(50)
      Task.shutdown(dead_task, :brutal_kill)

      # Second waiter registers
      alive_task =
        Task.async(fn ->
          IncludedWaiter.wait_for_slot(cred_id, limit, 5_000)
        end)

      Process.sleep(50)

      # Release → should skip dead waiter and notify alive_task
      Tokengate.Limits.Manager.release_concurrency(cred_id)
      IncludedWaiter.notify_slot(cred_id)

      assert {:ok, :ok} = Task.yield(alive_task, 2_000)
    end
  end
end
