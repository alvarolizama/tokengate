defmodule Tokengate.Routing.IncludedWaiter do
  @moduledoc """
  Cola FIFO por credential para requests esperando slot en una included saturada.

  Cuando una credential `included` está al máximo de concurrencia, los requests
  no caen inmediatamente a pay-per-token — se registran en esta cola y esperan
  a que otro request libere un slot. El timeout depende de cuántas included
  queden en la cascada (config `:included_wait_tiers`).

      * Se registra el proceso actual con {credential_id, timestamp, ref}
      * Al liberar un slot (`Limits.Manager.release/1`), se notifica al waiter
        más antiguo (FIFO estricto).
      * Si el proceso muere mientras espera, su entrada se limpia en la
        siguiente notificación.
  """

  @table :tokengate_included_waiters

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Espera hasta `timeout_ms` por un slot en `credential_id`.

  Intenta adquirir concurrencia inmediatamente; si falla, se registra en la
  cola FIFO de esta credential y bloquea hasta que otro request libere un slot
  o el timeout expire.

  Retorna `:ok` cuando se adquirió el slot, o `{:error, :queue_timeout}`.
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
  Notifica al waiter más antiguo de `credential_id` que un slot se liberó.

  Llamado por `Tokengate.Limits.Manager.release/1` cada vez que se libera
  concurrencia. Es idempotente: si no hay waiters, no hace nada.
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
      :ets.new(@table, [:ordered_set, :public, :named_table, write_concurrency: true])
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
    # Busca todas las entradas para esta credential, elige la más antigua
    # (menor timestamp), la borra y notifica al proceso.
    spec = [
      {{{credential_id, :"$1", :"$2"}, :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
    ]

    entries = :ets.select(@table, spec)

    if entries != [] do
      # Enum.min_by en el timestamp (primer elemento de cada tupla)
      {ts, ref, pid} = Enum.min_by(entries, fn {ts, _ref, _pid} -> ts end)
      key = {credential_id, ts, ref}

      if Process.alive?(pid) do
        :ets.delete(@table, key)
        send(pid, {:slot_available, ref})
      else
        # Proceso muerto — limpiar entrada huérfana y probar el siguiente
        :ets.delete(@table, key)
        do_notify(credential_id)
      end
    end

    :ok
  end
end
