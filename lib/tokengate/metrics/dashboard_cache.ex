defmodule Tokengate.Metrics.DashboardCache do
  @moduledoc """
  ETS-backed TTL cache for dashboard query results.

  The dashboard (`DashboardLive`) shows period-scoped aggregates (today,
  7d, 30d, last_month) that cannot be answered by the Collector's lifetime
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
  # How many times a waiter re-contends for the lock after the holder it was
  # waiting on vanished without publishing a value (crash / external exit).
  # One retry is the common case: the next contending process wins the lock
  # and every other waiter queues behind it. The bound only exists so a
  # permanently failing compute cannot loop waiters forever.
  @max_recontends 3
  # Value stored next to a placeholder entry. Keeping it a non-integer makes
  # the periodic sweep (which only reaps integer deadlines) ignore locks: a
  # lock must never expire while its holder is alive, whatever the entry TTL.
  @lock_marker :lock

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
  first caller wins an `:ets.insert_new/2` placeholder
  (`{:__computing__, key}`) and computes; the rest wait for that result
  instead of running the identical query. N viewers now cost ONE computation
  per TTL window, not N.

  The placeholder carries the holder's pid, so waiters monitor it: an
  external exit signal (LiveView async cancel) releases the lock immediately.
  A waiter NEVER gives up on a live holder — it has no wait cap, because
  dropping out after a fixed window is exactly what turned a slow (30s) cold
  stats query into N identical queries against the same pool. What bounds the
  wait is the holder's own lifetime: the compute runs a DB query under the
  repo timeout, and if the holder dies the `:DOWN` releases every waiter.
  A waiter whose holder vanished without publishing re-contends for the lock
  (bounded by `@max_recontends`) instead of computing on its own, so a crash
  never turns into a stampede either.

  The lock entry carries `@lock_marker` instead of a deadline: the periodic
  sweep only reaps integer deadlines, so an entry TTL — 5s default, 60s for
  the structural bundles — can never free a holder that is still computing.
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
  True when the ETS table is up. Release tasks and `with_repo` scripts run
  without the supervision tree; callers that can answer without the cache use
  this to skip it instead of crashing on a missing table.
  """
  @spec available?() :: boolean()
  def available?, do: :ets.whereis(@table) != :undefined

  @doc """
  Deletes every entry whose TTL has elapsed. Run periodically by the owning
  GenServer; safe to call directly (tests, maintenance). Returns the number
  of entries removed, or 0 when the table doesn't exist yet.

  Only entries with an integer deadline are reaped: single-flight
  placeholders (`@lock_marker`) belong to a live holder and must survive any
  TTL, including the short ones.
  """
  @spec sweep_expired() :: non_neg_integer()
  def sweep_expired do
    if :ets.whereis(@table) == :undefined do
      0
    else
      now = System.monotonic_time(:millisecond)

      :ets.select_delete(@table, [
        {{:_, :_, :"$1"}, [{:is_integer, :"$1"}, {:<, :"$1", now}], [true]}
      ])
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
  # A waiter never computes on its own while a live holder owns the key: it
  # blocks until the holder publishes the value or dies. Dropping out after a
  # fixed window was the stampede — a 30s cold stats bundle meant every
  # viewer past the first 1.5s ran the same ~12 queries against the same
  # pool. The holder's own DB timeouts bound the wait; its exit signals it.
  defp compute_once(key, compute_fn, ttl) do
    case read(key) do
      {:ok, data} -> data
      :miss -> contend(key, compute_fn, ttl, @max_recontends)
    end
  end

  defp contend(key, compute_fn, ttl, recontends) do
    # Re-read first: the previous round may have waited behind a holder that
    # has just published this very value.
    case read(key) do
      {:ok, data} ->
        data

      :miss ->
        do_contend(key, compute_fn, ttl, recontends)
    end
  end

  defp do_contend(key, compute_fn, ttl, recontends) do
    case acquire(key) do
      :acquired ->
        hold_and_compute(key, compute_fn, ttl)

      {:wait, holder} ->
        case await_value(key, holder) do
          {:ok, data} ->
            data

          # The holder vanished without publishing (its compute raised, or an
          # external exit signal skipped its `after`). Re-contend for the lock
          # instead of computing here, so a crash spawns one new holder and
          # not one computation per waiter.
          :miss when recontends > 0 ->
            contend(key, compute_fn, ttl, recontends - 1)

          # Pathological only (a compute that can never publish): answer the
          # caller instead of looping forever. Not cached — the next caller
          # starts a fresh attempt.
          :miss ->
            compute_fn.()
        end
    end
  end

  defp hold_and_compute(key, compute_fn, ttl) do
    try do
      data = compute_fn.()
      put(key, data, ttl)
      data
    after
      # Releases on normal return AND on raise/exit: a crashing computer
      # must not leave the key wedged.
      release(key)
    end
  end

  # Drops our own placeholder. Never a stranger's: `invalidate_all/0` can
  # clear the lock while we compute, and a later holder may already own the
  # key by the time this runs.
  defp release(key) do
    me = self()
    lock = lock_key(key)

    case :ets.lookup(@table, lock) do
      [{_key, {:computing, ^me}, @lock_marker}] -> :ets.delete(@table, lock)
      _ -> :ok
    end
  end

  # Takes the single-flight placeholder for `key`. `:ets.insert_new/2` is the
  # only atomic step: exactly one caller wins, every other one learns who did.
  defp acquire(key) do
    if :ets.insert_new(@table, {lock_key(key), {:computing, self()}, @lock_marker}) do
      :acquired
    else
      case :ets.lookup(@table, lock_key(key)) do
        [{_key, {:computing, pid}, @lock_marker}] -> {:wait, pid}
        # Released between the insert attempt and the lookup: the value may
        # already be published (or the key free again). Let the caller retry.
        _ -> {:wait, :released}
      end
    end
  end

  # Waits for the process holding the lock to publish the entry, with no
  # deadline of its own. The placeholder carries the holder's pid, so waiters
  # monitor it: when the holder dies on an external exit signal (e.g. LiveView
  # async cancellation) its `after` clause never runs — `:DOWN` releases every
  # waiter immediately instead of leaving them polling.
  defp await_value(key, :released) do
    case read(key) do
      {:ok, data} -> {:ok, data}
      :miss -> :miss
    end
  end

  defp await_value(key, holder) when is_pid(holder) do
    ref = Process.monitor(holder)

    try do
      await_value(key, holder, ref)
    after
      Process.demonitor(ref, [:flush])
    end
  end

  defp await_value(key, holder, ref) do
    case read(key) do
      {:ok, data} ->
        {:ok, data}

      :miss ->
        receive do
          {:DOWN, ^ref, :process, _pid, _reason} ->
            # The holder died on an external exit signal: its `after` never
            # ran, so the placeholder is still there. Free it — only when it
            # is still that holder's — so the next contender can take the key
            # instead of queueing behind a dead pid.
            release_stale_lock(key, holder)
            :miss
        after
          @poll_interval_ms -> await_value(key, holder, ref)
        end
    end
  end

  # Clears the placeholder of a dead holder, never a live one: a new holder
  # may have taken the key between the DOWN and this call.
  defp release_stale_lock(key, dead_pid) do
    lock = lock_key(key)

    case :ets.lookup(@table, lock) do
      [{_key, {:computing, ^dead_pid}, @lock_marker}] -> :ets.delete(@table, lock)
      _ -> :ok
    end
  end

  defp lock_key(key), do: {:__computing__, key}

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
