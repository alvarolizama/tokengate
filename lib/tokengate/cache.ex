defmodule Tokengate.Cache do
  @moduledoc """
  Small generic ETS cache for hot-path data that changes rarely.

  Same contract as `Tokengate.Accounts.ApiKeyCache`: a named **public** ETS
  table owned by this GenServer, reads and writes in the caller process (no
  bottleneck), per-entry TTL and a periodic sweep of expired entries. It is
  generic because several hot paths share the shape but not the key space;
  keys are tagged tuples so a table scan never confuses two datasets:

    * `{:exemptions, scope}` — the `Tokengate.Budgets.Exemptions` set of
      exempt subjects for a scope (read on every proxied request).
    * `{:observability_destinations, :all}` — the output of
      `Tokengate.Observability.list_all_destinations/0` (read once per
      request log).

  TTL is a safety net, not the invalidation mechanism: every writer that
  changes the underlying rows invalidates its own key, so a mutation is
  visible on the next read — on the writer's node immediately and, through
  `Tokengate.CacheInvalidation`, on every other connected node. The TTL only
  bounds the staleness of a write that bypasses the context (raw SQL, a
  disconnected node, a rolled-back sandbox).

  ## Degradation

  `fetch/3` never raises: when the table is gone (owner restart, hot code
  reload into a tree that predates the module) the function runs uncached.
  The cache is an optimization, never a dependency.

  ## Single-flight

  Concurrent misses on the same key do not run `fun` N times: the first
  caller takes an `insert_new/2` placeholder, the rest wait (bounded to
  `@max_wait_ms`, then compute locally) for that value. The placeholder
  carries the holder's pid and waiters monitor it, so a holder killed by
  an external exit signal releases the lock immediately instead of wedging
  the key until the TTL sweep. Whatever `fun` returns is stored — this
  module caches values, not successes.

  ## Tests

  The table is VM-global and outlives the Ecto sandbox rollback, so
  `Tokengate.DataCase` flushes it on every setup — same treatment as
  `DashboardCache` and `GlobalSettings`' `:persistent_term`.
  """

  use GenServer

  @table :tokengate_cache
  @sweep_ms :timer.seconds(30)
  # Waiters behind a single-flight lock re-check at this cadence…
  @poll_interval_ms 5

  # …and never block longer than this. Cache entries here are cheap
  # hot-path reads (exemptions, observability destinations): a duplicate
  # computation beats stalling a proxied request behind a slow holder.
  @max_wait_ms 200

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the cached value for `key`, computing it with `fun` on a miss or
  after `ttl_ms`. The computed value is stored (whatever it is, `nil`
  included) together with its expiry.
  """
  @spec fetch(term(), non_neg_integer(), (-> value)) :: value when value: term()
  def fetch(key, ttl_ms, fun) when is_function(fun, 0) do
    if :ets.whereis(@table) == :undefined do
      fun.()
    else
      try do
        case :ets.lookup(@table, key) do
          [{^key, value, expires_at}] ->
            if now() < expires_at do
              value
            else
              :ets.delete(@table, key)
              put_new(key, ttl_ms, fun)
            end

          [] ->
            put_new(key, ttl_ms, fun)
        end
      rescue
        # The table raced away between the whereis check and the lookup
        # (owner process died / supervisor restart). Degrade to an uncached
        # computation.
        ArgumentError -> fun.()
      end
    end
  end

  @doc "Drops one entry (on this node and the others). A no-op when the table is gone."
  @spec invalidate(term()) :: :ok
  def invalidate(key), do: dispatch({:invalidate, key})

  @doc "Drops every entry (on this node and the others). A no-op when the table is gone."
  @spec invalidate_all() :: :ok
  def invalidate_all, do: dispatch(:all)

  # Local-only application of an invalidation operation, used by
  # `Tokengate.CacheInvalidation` for operations arriving from another node.
  @doc false
  @spec apply_local(term()) :: :ok
  def apply_local({:invalidate, key}) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, key)
    :ok
  end

  def apply_local(:all) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  def apply_local(_op), do: :ok

  defp dispatch(op), do: Tokengate.CacheInvalidation.dispatch(:cache, op)

  @doc false
  def table, do: @table

  # ---------------------------------------------------------------------------
  # GenServer — table owner + TTL sweep
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    ensure_table()
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp put_new(key, ttl_ms, fun) do
    lock_key = {:__computing__, key}
    deadline = now() + @max_wait_ms

    if :ets.insert_new(@table, {lock_key, {:computing, self()}, deadline}) do
      try do
        compute_and_store(key, ttl_ms, fun)
      after
        # Releases on normal return AND on raise/exit: a crashing computer
        # must not leave the key wedged for the whole TTL.
        :ets.delete(@table, lock_key)
      end
    else
      case await_value(key, lock_key, deadline) do
        {:ok, value} ->
          value

        # The holder died (its `after` never ran — the waiter cleared the
        # stale lock via monitor), or outlived the capped wait window.
        # Cache our own result: without the write every later caller keeps
        # recomputing, which is the stampede single-flight exists to stop.
        :miss ->
          compute_and_store(key, ttl_ms, fun)
      end
    end
  end

  defp compute_and_store(key, ttl_ms, fun) do
    value = fun.()
    :ets.insert(@table, {key, value, now() + ttl_ms})
    value
  end

  # Waits (bounded) for the process holding the lock to publish the entry.
  # The placeholder carries the holder's pid, so waiters monitor it: when
  # the holder dies on an external exit signal its `after` clause never
  # runs — the `:DOWN` message releases the lock immediately instead of
  # leaving every waiter polling until the deadline.
  defp await_value(key, lock_key, deadline) do
    holder = holder_pid(lock_key)
    wait_deadline = min(deadline, now() + @max_wait_ms)
    ref = holder && Process.monitor(holder)

    try do
      await_value(key, lock_key, wait_deadline, ref)
    after
      ref && Process.demonitor(ref, [:flush])
    end
  end

  defp await_value(key, lock_key, deadline, ref) do
    case fresh_value(key) do
      {:ok, value} ->
        {:ok, value}

      :miss ->
        cond do
          now() >= deadline ->
            :miss

          :ets.lookup(@table, lock_key) == [] ->
            :miss

          received_down?(ref) ->
            release_stale_lock(lock_key, holder_pid(lock_key))
            :miss

          true ->
            Process.sleep(@poll_interval_ms)
            await_value(key, lock_key, deadline, ref)
        end
    end
  end

  defp fresh_value(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] -> if now() < expires_at, do: {:ok, value}, else: :miss
      [] -> :miss
    end
  end

  defp holder_pid(lock_key) do
    case :ets.lookup(@table, lock_key) do
      [{^lock_key, {:computing, pid}, _deadline}] -> pid
      _ -> nil
    end
  end

  defp received_down?(nil), do: false

  defp received_down?(ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> true
    after
      0 -> false
    end
  end

  # Clears the dead holder's lock, but only if nobody else took it over in
  # the meantime.
  defp release_stale_lock(lock_key, dead_pid) do
    case :ets.match(@table, {lock_key, {:computing, :"$1"}, :_}) do
      [[^dead_pid]] -> :ets.delete(@table, lock_key)
      _ -> :ok
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end
  end
end
