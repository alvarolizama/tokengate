defmodule Tokengate.Metrics.DashboardCache do
  @moduledoc """
  ETS-backed TTL cache for dashboard query results.

  The dashboard (`DashboardLive`) shows period-scoped aggregates (today,
  7d, 30d, 90d) that cannot be answered by the Collector's lifetime
  counters. Without this cache, every connected dashboard re-queries
  Postgres on each `metrics:updated` PubSub broadcast (debounced to 2s).
  With N connected dashboards and a busy proxy, that is N × 8+ queries
  every 2 seconds.

  This cache stores the full data bundle per `{user_id, period, timezone}`
  with a configurable TTL (default 5s). On a cache hit the dashboard
  skips all Postgres queries and applies the cached assigns directly.

  ## Concurrency model

  Same pattern as `Metrics.Collector`: the GenServer
  only owns the public named ETS table. `fetch_or_compute/2` runs in the
  caller's process — reads are direct ETS lookups, writes are atomic
  inserts. No GenServer bottleneck on the hot path.

  ## TTL vs PubSub invalidation

  The cache relies on TTL expiry, not PubSub invalidation. The
  `metrics:updated` broadcast still triggers the dashboard's reload
  cycle (debounced to 2s), but the reload reads from cache first. If
  the entry is within TTL, it's a hit — no Postgres query. This means
  the dashboard may show data up to `@ttl_ms` stale, which is acceptable
  for a metrics overview.

  Expired entries are swept periodically by the owning GenServer, so
  bounded key spaces (user × period × timezone, or fixed monitor keys)
  never accumulate dead rows in the table.

  With a 5s TTL and 2s debounce, a single dashboard hits Postgres every
  ~5-6s instead of every ~2s — a ~60% reduction. Multiple dashboards for
  the same user share one cache entry.

  ## Per-entry TTL

  Lifetime/whole-table aggregates (users spend, day p95, filter options)
  don't need 5s freshness — re-running them every refresh re-scans the log
  table for data that barely moves. `fetch_or_compute/3` and `put/3` accept
  a per-entry `:ttl` in milliseconds; the expiry is baked into the entry at
  write time, so a 60s entry coexists with the 5s default in the same table
  and the sweep honors each entry's own deadline.
  """

  use GenServer

  @table :tokengate_dashboard_cache
  @default_ttl_ms 5_000
  # Sweep cadence: how often the owning GenServer purges expired entries.
  @sweep_interval_ms 5_000
  # How often a waiter re-checks for the value a concurrent computer is
  # building. Kept short enough to be invisible next to a stats query, long
  # enough that a crowd of waiters doesn't spin the scheduler.
  @poll_interval_ms 10
  # Hard cap on how long any waiter blocks behind a lock, regardless of the
  # entry TTL (a 60s structural TTL must never freeze a LiveView for a
  # wedged holder). Past this window the waiter recomputes locally.
  @max_wait_ms 1_500

  ## Public API ---------------------------------------------------------------

  @doc "Starts the cache GenServer (owns the ETS table)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Builds a cache key from user_id, period, and timezone."
  @spec build_key(term(), String.t(), String.t()) :: {term(), String.t(), String.t()}
  def build_key(user_id, period, timezone) do
    {user_id, period, timezone}
  end

  @doc """
  Returns `{:ok, data}` if a fresh entry exists for `key`, `:miss`
  otherwise. Does NOT compute — use `fetch_or_compute/2` for that.
  """
  @spec fetch(term()) :: {:ok, map()} | :miss
  def fetch(key) do
    case read(key) do
      {:ok, _data} = hit -> hit
      :miss -> :miss
    end
  end

  @doc """
  Reads a cached entry for `key`. On hit (within TTL), returns the
  cached data. On miss, calls `compute_fn.()`, stores the result, and
  returns it. Runs entirely in the caller's process.

  Accepts a per-entry `:ttl` in milliseconds (default: the global TTL).

  ## Single-flight

  Concurrent misses on the SAME key do not fan out onto the database: the
  first caller wins an `:ets.insert_new/2` placeholder (`{:__computing__,
  key}`) and computes; the rest wait (bounded by the entry's TTL) for that
  result instead of running the identical query. N viewers now cost ONE
  computation per TTL window, not N.

  The placeholder carries the holder's pid and the entry's deadline; waiters
  monitor the holder so an external exit signal (LiveView async cancel) also
  releases the lock immediately. A waiter that outlives its capped wait window
  (@max_wait_ms) computes locally and caches its own result, so a crashed or
  slow holder never strands the key.
  """
  @spec fetch_or_compute(term(), (-> map())) :: map()
  def fetch_or_compute(key, compute_fn) do
    fetch_or_compute(key, compute_fn, [])
  end

  @spec fetch_or_compute(term(), (-> map()), keyword()) :: map()
  def fetch_or_compute(key, compute_fn, opts) do
    ttl = Keyword.get(opts, :ttl, ttl_ms())

    case read(key) do
      {:ok, data} -> data
      :miss -> compute_once(key, compute_fn, ttl)
    end
  end

  @doc "Stores `data` under `key` with the global TTL."
  @spec put(term(), map()) :: :ok
  def put(key, data), do: put(key, data, ttl_ms())

  @doc "Stores `data` under `key` with a custom TTL in milliseconds."
  @spec put(term(), map(), non_neg_integer()) :: :ok
  def put(key, data, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {key, data, expires_at})
    :ok
  end

  @doc "Invalidates a single cache entry."
  @spec invalidate(term()) :: :ok
  def invalidate(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc "Invalidates all cache entries."
  @spec invalidate_all() :: :ok
  def invalidate_all do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Returns the configured TTL in milliseconds."
  @spec ttl_ms() :: non_neg_integer()
  def ttl_ms, do: Application.get_env(:tokengate, :dashboard_cache_ttl_ms, @default_ttl_ms)

  @doc """
  Deletes every entry whose TTL has elapsed. Run periodically by the owning
  GenServer; safe to call directly (tests, maintenance). Returns the number
  of entries removed, or 0 when the table doesn't exist yet.
  """
  @spec sweep_expired() :: non_neg_integer()
  def sweep_expired do
    if :ets.whereis(@table) == :undefined do
      0
    else
      now = System.monotonic_time(:millisecond)
      :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    end
  end

  ## GenServer callbacks ------------------------------------------------------

  @impl true
  def init(_opts) do
    ensure_table()
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals ---------------------------------------------------------------

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    end

    :ok
  end

  # Single-flight wrapper around the miss path. See `fetch_or_compute/3`.
  #
  # Waiters are bounded by construction: at most @max_wait_ms behind the lock
  # (plus the monitor for a fast :DOWN), then they compute locally. A duplicate
  # computation is always cheaper than a wedged key — a LiveView holds this
  # call inside its own process, so there is no safe way to block longer.
  defp compute_once(key, compute_fn, ttl) do
    lock_key = {:__computing__, key}
    deadline = System.monotonic_time(:millisecond) + ttl

    if :ets.insert_new(@table, {lock_key, {:computing, self()}, deadline}) do
      try do
        data = compute_fn.()
        put(key, data, ttl)
        data
      after
        # Releases on normal return AND on raise/exit: a crashing computer
        # must not leave the key wedged for the whole TTL.
        :ets.delete(@table, lock_key)
      end
    else
      case await_value(key, lock_key, deadline) do
        {:ok, data} ->
          data

        # The holder released without a value (its compute raised), died on an
        # external exit signal (its `after` never ran — the waiter cleared the
        # stale lock via monitor), or outlived the wait window. Cache our own
        # result: without the put every later caller keeps recomputing.
        :miss ->
          data = compute_fn.()
          put(key, data, ttl)
          data
      end
    end
  end

  # Waits (bounded) for the process holding the lock to publish the entry.
  # The placeholder carries the holder's pid, so waiters monitor it: when the
  # holder dies on an external exit signal (e.g. LiveView async cancellation)
  # its `after` clause never runs — the `:DOWN` message releases the lock
  # immediately instead of leaving every waiter polling until the deadline.
  # Returns `:miss` as soon as the lock is gone without a value, so a crashed
  # computer costs waiters one poll interval instead of the full TTL.
  defp await_value(key, lock_key, deadline) do
    holder_pid = holder_pid(lock_key)
    wait_deadline = min(deadline, System.monotonic_time(:millisecond) + @max_wait_ms)
    ref = holder_pid && Process.monitor(holder_pid)

    try do
      await_value(key, lock_key, wait_deadline, ref)
    after
      ref && Process.demonitor(ref, [:flush])
    end
  end

  defp holder_pid(lock_key) do
    case :ets.lookup(@table, lock_key) do
      [{^lock_key, {:computing, pid}, _deadline}] -> pid
      _ -> nil
    end
  end

  defp await_value(key, lock_key, deadline, ref) do
    case read(key) do
      {:ok, data} ->
        {:ok, data}

      :miss ->
        now = System.monotonic_time(:millisecond)

        cond do
          now >= deadline ->
            :miss

          :ets.lookup(@table, lock_key) == [] ->
            :miss

          # Holder died without releasing: clear the stale lock so the next
          # attempt can take it instead of polling until the deadline.
          received_down?(ref) ->
            release_stale_lock(lock_key, holder_pid(lock_key))
            :miss

          true ->
            Process.sleep(@poll_interval_ms)
            await_value(key, lock_key, deadline, ref)
        end
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
  # the meantime (a re-attempt may already own the key with its own pid).
  defp release_stale_lock(lock_key, dead_pid) do
    case :ets.match(@table, {lock_key, {:computing, :"$1"}, :_}) do
      [[^dead_pid]] -> :ets.delete(@table, lock_key)
      _ -> :ok
    end
  end

  defp read(key) do
    case :ets.lookup(@table, key) do
      [{^key, data, expires_at}] ->
        # The deadline is baked into the entry at write time, so a 60s
        # entry survives next to the 5s default regardless of what the
        # global TTL is when it is read.
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, data}
        else
          :miss
        end

      [] ->
        :miss
    end
  end
end
