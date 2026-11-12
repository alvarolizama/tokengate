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
  visible on the next read. The TTL only bounds the staleness of a write
  that bypasses the context (raw SQL, another node, a rolled-back sandbox).

  ## Degradation

  `fetch/3` never raises: when the table is gone (owner restart, hot code
  reload into a tree that predates the module) the function runs uncached.
  The cache is an optimization, never a dependency.

  ## Tests

  The table is VM-global and outlives the Ecto sandbox rollback, so
  `Tokengate.DataCase` flushes it on every setup — same treatment as
  `DashboardCache` and `GlobalSettings`' `:persistent_term`.
  """

  use GenServer

  @table :tokengate_cache
  @sweep_ms :timer.seconds(30)

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
              put(key, ttl_ms, fun)
            end

          [] ->
            put(key, ttl_ms, fun)
        end
      rescue
        # The table raced away between the whereis check and the lookup
        # (owner process died / supervisor restart). Degrade to an uncached
        # computation.
        ArgumentError -> fun.()
      end
    end
  end

  @doc "Drops one entry. A no-op when the table is gone."
  @spec invalidate(term()) :: :ok
  def invalidate(key) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, key)
    :ok
  end

  @doc "Drops every entry. A no-op when the table is gone."
  @spec invalidate_all() :: :ok
  def invalidate_all do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

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

  defp put(key, ttl_ms, fun) do
    value = fun.()
    :ets.insert(@table, {key, value, now() + ttl_ms})
    value
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
