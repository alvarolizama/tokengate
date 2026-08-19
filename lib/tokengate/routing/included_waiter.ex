defmodule Tokengate.Routing.IncludedWaiter do
  @moduledoc """
  FIFO queue per credential for requests waiting for a slot on a saturated
  `included` credential.

  When an `included` credential is at max concurrency, requests don't fall
  through to pay-per-token immediately — they register in this queue and
  wait for another request to free a slot. The timeout depends on how many
  included credentials remain in the cascade (config `:included_wait_tiers`).

      * The current process registers with {credential_id, timestamp, ref}
      * When a slot is freed (`Limits.Manager.release/1`), the oldest waiter
        is notified (strict FIFO).
      * If a process dies while waiting, its entry is cleaned up on the next
        notification.
  """

  @table :tokengate_included_waiters

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Waits up to `timeout_ms` for a slot on `credential_id`.

  Tries to acquire concurrency immediately; if it fails, registers in this
  credential's FIFO queue and blocks until another request frees a slot or
  the timeout expires.

  Returns `:ok` when a slot was acquired, or `{:error, :queue_timeout}`.
  """
  @spec wait_for_slot(
          credential_id :: term(),
          limit :: pos_integer(),
          timeout_ms :: pos_integer()
        ) ::
          :ok | {:error, :queue_timeout}
  def wait_for_slot(credential_id, limit, timeout_ms) do
    ensure_table()

    case Tokengate.Limits.Manager.acquire_concurrency(credential_id, limit) do
      :ok ->
        :ok

      {:error, :concurrency_exceeded} ->
        register_and_wait(credential_id, limit, timeout_ms)
    end
  end

  @doc """
  Notifies the oldest waiter for `credential_id` that a slot was freed.

  Called by `Tokengate.Limits.Manager.release/1` each time concurrency is
  released. Idempotent: if there are no waiters, it does nothing.
  """
  @spec notify_slot(credential_id :: term()) :: :ok
  def notify_slot(credential_id) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> do_notify(credential_id)
    end
  end

  # ── Internals ──────────────────────────────────────────────────────────

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :ordered_set,
        :public,
        :named_table,
        write_concurrency: true,
        read_concurrency: true
      ])
    end
  end

  defp register_and_wait(credential_id, limit, timeout_ms) do
    ref = make_ref()
    inserted_at = System.monotonic_time(:millisecond)
    key = {credential_id, inserted_at, ref}
    start = System.monotonic_time(:millisecond)
    :ets.insert(@table, {key, self()})

    receive do
      {:slot_available, ^ref} ->
        # Slot was freed — retry acquisition. Another waiter might have raced
        # us, so if it fails again we re-register with the remaining timeout.
        remaining = timeout_ms - (System.monotonic_time(:millisecond) - start)

        case Tokengate.Limits.Manager.acquire_concurrency(credential_id, limit) do
          :ok ->
            :ok

          {:error, :concurrency_exceeded} when remaining > 0 ->
            register_and_wait(credential_id, limit, remaining)

          {:error, :concurrency_exceeded} ->
            {:error, :queue_timeout}
        end
    after
      timeout_ms ->
        :ets.delete(@table, key)
        {:error, :queue_timeout}
    end
  end

  defp do_notify(credential_id) do
    # Selects all entries for this credential, picks the oldest (lowest
    # timestamp), deletes it and notifies the process.
    spec = [
      {{{credential_id, :"$1", :"$2"}, :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
    ]

    entries = :ets.select(@table, spec)

    if entries != [] do
      # Enum.min_by over the timestamp (first element of each tuple)
      {ts, ref, pid} = Enum.min_by(entries, fn {ts, _ref, _pid} -> ts end)
      key = {credential_id, ts, ref}

      if Process.alive?(pid) do
        :ets.delete(@table, key)
        send(pid, {:slot_available, ref})
      else
        # Process dead — clean up the orphan entry and try the next one
        :ets.delete(@table, key)
        do_notify(credential_id)
      end
    end

    :ok
  end
end
