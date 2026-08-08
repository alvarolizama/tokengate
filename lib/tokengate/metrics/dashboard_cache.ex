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

  Same pattern as `Metrics.Collector` and `Metrics.Window`: the GenServer
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

  With a 5s TTL and 2s debounce, a single dashboard hits Postgres every
  ~5-6s instead of every ~2s — a ~60% reduction. Multiple dashboards for
  the same user share one cache entry.
  """

  use GenServer

  @table :tokengate_dashboard_cache
  @default_ttl_ms 5_000

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
  """
  @spec fetch_or_compute(term(), (-> map())) :: map()
  def fetch_or_compute(key, compute_fn) do
    case read(key) do
      {:ok, data} ->
        data

      :miss ->
        data = compute_fn.()
        put(key, data)
        data
    end
  end

  @doc "Stores `data` under `key` with the current monotonic timestamp."
  @spec put(term(), map()) :: :ok
  def put(key, data) do
    :ets.insert(@table, {key, data, System.monotonic_time(:millisecond)})
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
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Returns the configured TTL in milliseconds."
  @spec ttl_ms() :: non_neg_integer()
  def ttl_ms, do: Application.get_env(:tokengate, :dashboard_cache_ttl_ms, @default_ttl_ms)

  ## GenServer callbacks ------------------------------------------------------

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  ## Internals ---------------------------------------------------------------

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    end

    :ok
  end

  defp read(key) do
    case :ets.lookup(@table, key) do
      [{^key, data, ts}] ->
        if System.monotonic_time(:millisecond) - ts < ttl_ms() do
          {:ok, data}
        else
          :miss
        end

      [] ->
        :miss
    end
  end
end
