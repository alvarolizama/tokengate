defmodule Tokengate.Routing.Cache do
  @moduledoc """
  ETS-backed routing cache: avoids re-querying Postgres for the same
  (model_id, group_id) provider list on every proxied request.

  ## What is cached

    * `{:model_providers, model_id, scope}` — the ordered list of
      `ModelProvider` structs (with credential + provider preloaded) visible to
      that scope. `scope` is a group id, `{:service, service_id}` or `:global`
      (group-less/service-less members, global lanes only).
    * `{:accessible_models, group_id, member_id}` — the list of `Model`
      structs a group member may route to (group grants ∪ individual extra
      grants ∪ service grants). `group_id`/`member_id` may be `:global` for
      service/virtual members.
    * `{:disabled_credentials, MapSet.t()}` — credential ids that are NOT
      `status == "active"`. A request only reads this set; the write side
      (Oban job, admin UI) invalidates it.

  ## Invalidation

  Writes go through `Tokengate.Providers` / `Tokengate.Accounts` context
  functions. Each of those functions calls `invalidate/1` (or
  `invalidate_all/0`) after a successful DB write. The proxy hot path never
  invalidates; it only reads and lazily re-populates on a miss.

  Catalog writes (provider, credential, pool, lane) call `invalidate_all/0`,
  which used to wipe the table: every model in every group then re-queried
  Postgres on the next request — a herd of K simultaneous scans for K models.
  Instead, `invalidate_all/0` REWRITES the deadline of the routing entries so
  they expire inside a short, deterministic per-key stagger window (≤1s), and
  drops correctness-critical singletons (`:disabled_credentials`) immediately.
  Keys still expire, just not on the same millisecond.

  ## Concurrency

  All reads/writes are lock-free `public` ETS ops running in the caller
  process. The owning GenServer only creates the tables. Entries carry a
  monotonic `expires_at`; a read treats an expired entry as a miss (and
  deletes it), so the effective TTL is `@ttl_ms` even without a sweep.

  Misses are single-flighted per key: the first caller hits the DB and the
  rest wait for its value, so N concurrent requests for the same
  (model, group) run ONE query. Locks live in their own table and are never
  expired by a TTL — a holder keeps its lock until it publishes or dies.
  """

  use GenServer

  @table :tokengate_routing_cache
  @locks :tokengate_routing_cache_locks
  @ttl_ms :timer.minutes(1)

  # Upper bound of the expiry stagger applied by `invalidate_all/0`. Small
  # enough that a deleted provider stops being routed, large enough that the
  # recomputation of every model key spreads over N scheduler rounds instead
  # of one burst.
  @invalidate_stagger_ms 1_000
  # Waiter poll cadence and re-contend budget (see `DashboardCache`).
  @poll_interval_ms 5
  @max_recontends 3

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the cached model providers for the given scope, computing and
  caching the result on a miss.

  `scope` is the routing scope the list belongs to:

    * a group id — the lanes visible to a member of that group;
    * `{:service, service_id}` — the global lanes plus that service's own
      exclusive lanes. Services MUST NOT share the `:global` entry: two
      services with a service-exclusive lane for the SAME model would
      otherwise overwrite each other's list for a whole TTL;
    * `nil` / `:global` — the group-less, service-less scope (global lanes
      only).

  `fun` is the DB query — it is only executed on a cache miss.
  """
  @spec fetch_model_providers(binary(), term(), (-> [term()])) :: [term()]
  def fetch_model_providers(model_id, scope, fun) when is_function(fun, 0) do
    fetch_fresh({:model_providers, model_id, scope_key(scope)}, fun)
  end

  # `{:service, id}` stays a tuple (it is a first-class scope); everything else
  # follows the historical contract where a missing group is `:global`.
  defp scope_key({:service, _id} = scope), do: scope
  defp scope_key(:global), do: :global
  defp scope_key(nil), do: :global
  defp scope_key(group_id), do: group_id

  @doc """
  Returns the cached accessible models for a group member, computing and
  caching the result on a miss.

  `group_id` may be `nil` for service/virtual members (the cache key uses
  `:global`). `fun` is the DB query — it is only executed on a cache miss.
  """
  @spec fetch_accessible_models(term(), term() | nil, (-> [term()])) :: [term()]
  def fetch_accessible_models(group_id, member_id, fun) when is_function(fun, 0) do
    fetch_fresh({:accessible_models, group_id || :global, member_id || :global}, fun)
  end

  @doc """
  Drops the cached accessible models for a group member — or a whole group.

  `nil` acts as a wildcard on either side:

    * `(group_id, member_id)` — clears the single exact key.
    * `(group_id, nil)` — clears every cached entry for members of that group
      (after a `GroupModel` grant/revoke).
    * `(nil, member_id)` — clears every entry for that member regardless of
      group (after a `GroupMemberExtraModel` / `ServiceModel` change).
  """
  @spec invalidate_accessible_models(term() | nil, term() | nil) :: :ok
  def invalidate_accessible_models(group_id, member_id),
    do: dispatch({:accessible_models, group_id, member_id})

  @doc """
  Returns a `MapSet` of credential ids that are currently NOT `status ==
  "active"`. Computed from the DB on first call; cached for `@ttl_ms`.
  """
  @spec disabled_credential_ids() :: MapSet.t()
  def disabled_credential_ids do
    fetch_fresh(:disabled_credentials, &query_disabled_credentials/0)
  end

  @doc """
  Invalidates a specific cache key (`{:model_providers, model_id, group_id}`)
  or the whole `:disabled_credentials` set — on this node and the others.
  """
  @spec invalidate(tuple() | :disabled_credentials) :: :ok
  def invalidate(key), do: dispatch({:invalidate, key})

  @doc """
  Drops every cached entry. Called after bulk writes (group deletion, provider
  deletion, etc.) — on this node and the others.
  """
  @spec invalidate_all() :: :ok
  def invalidate_all, do: dispatch(:all)

  # Local-only application, used by `Tokengate.CacheInvalidation` for the
  # operations that arrive from another node (and synchronously for the
  # caller's own node through `dispatch/1`).
  #
  # Tolerates a missing table: seeds/release tasks run with `with_repo`, no
  # supervision tree, so there is nothing to invalidate.
  @doc false
  @spec apply_local(term()) :: :ok
  def apply_local({:invalidate, key}) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, key)
    :ok
  end

  def apply_local({:accessible_models, group_id, member_id}) do
    if :ets.whereis(@table) != :undefined do
      :ets.match_delete(@table, {{:accessible_models, group_id || :_, member_id || :_}, :_, :_})
    end

    :ok
  end

  # Catalog write: stagger the expiry of the routing entries instead of
  # wiping them (see the moduledoc). The disabled-credentials singleton is
  # dropped at once — it decides whether a credential may be used at all.
  def apply_local(:all) do
    if :ets.whereis(@table) == :undefined do
      :ok
    else
      :ets.delete(@table, :disabled_credentials)
      stagger_expiry()
      :ok
    end
  end

  def apply_local(_op), do: :ok

  defp dispatch(op), do: Tokengate.CacheInvalidation.dispatch(:routing_cache, op)

  @doc false
  def table, do: @table

  # ---------------------------------------------------------------------------
  # GenServer callbacks (table owner only — all reads run in caller process)
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

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

    if :ets.whereis(@locks) == :undefined do
      :ets.new(@locks, [:named_table, :public, :set, write_concurrency: true])
    end

    :ok
  end

  # TTL on read: `expires_at` is an absolute monotonic deadline stored with the
  # entry. Without this check the written deadline was dead weight — a missed
  # invalidation (or an unsupported write path) would keep a stale entry alive
  # forever, and the router now serves every request from this cache.
  defp fetch_fresh(key, fun) do
    case lookup(key) do
      {:ok, value} -> value
      :miss -> single_flight(key, fun, @max_recontends)
    end
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          :ets.delete(@table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  # One DB query per key per miss: the first caller computes, every other
  # caller waits for its value instead of running the same query. Same
  # contract as `Metrics.DashboardCache` — no wait cap on a live holder, a
  # vanished holder hands the lock to the next contender.
  defp single_flight(key, fun, recontends) do
    # Re-read first: a previous round may have waited behind a holder that
    # just published this exact key.
    case lookup(key) do
      {:ok, value} ->
        value

      :miss ->
        do_single_flight(key, fun, recontends)
    end
  end

  defp do_single_flight(key, fun, recontends) do
    case acquire(key) do
      :acquired ->
        try do
          put_new(key, fun.())
        after
          release(key)
        end

      {:wait, holder} ->
        case await(key, holder) do
          {:ok, value} ->
            value

          :miss when recontends > 0 ->
            single_flight(key, fun, recontends - 1)

          :miss ->
            fun.()
        end
    end
  end

  # Degrades to computing without a lock when the lock table doesn't exist
  # (release tasks / seeds run with no supervision tree).
  defp acquire(key) do
    if :ets.whereis(@locks) == :undefined do
      :acquired
    else
      if :ets.insert_new(@locks, {key, self()}) do
        :acquired
      else
        case :ets.lookup(@locks, key) do
          [{_key, pid}] -> {:wait, pid}
          _ -> {:wait, :released}
        end
      end
    end
  end

  defp release(key) do
    me = self()

    if :ets.whereis(@locks) != :undefined do
      case :ets.lookup(@locks, key) do
        [{_key, ^me}] -> :ets.delete(@locks, key)
        _ -> :ok
      end
    end

    :ok
  end

  defp await(key, :released) do
    case lookup(key) do
      {:ok, value} -> {:ok, value}
      :miss -> :miss
    end
  end

  defp await(key, holder) when is_pid(holder) do
    ref = Process.monitor(holder)

    try do
      await(key, holder, ref)
    after
      Process.demonitor(ref, [:flush])
    end
  end

  defp await(key, holder, ref) do
    case lookup(key) do
      {:ok, value} ->
        {:ok, value}

      :miss ->
        receive do
          {:DOWN, ^ref, :process, _pid, _reason} ->
            # Dead holder, `after` never ran: free its placeholder (and only
            # its) so the next contender can take the key.
            release_stale_lock(key, holder)
            :miss
        after
          @poll_interval_ms -> await(key, holder, ref)
        end
    end
  end

  defp release_stale_lock(key, dead_pid) do
    case :ets.lookup(@locks, key) do
      [{_key, ^dead_pid}] -> :ets.delete(@locks, key)
      _ -> :ok
    end
  end

  defp put_new(key, value) do
    expires_at = System.monotonic_time(:millisecond) + @ttl_ms
    true = :ets.insert(@table, {key, value, expires_at})
    value
  end

  # `invalidate_all/0` body: bring every entry's deadline inside a per-key
  # deterministic stagger (never later than the original one, so the TTL is
  # honored). Same-ms expiry for every model key is what produced the burst
  # of identical catalog scans after each admin write.
  defp stagger_expiry do
    now = System.monotonic_time(:millisecond)

    @table
    |> :ets.tab2list()
    |> Enum.each(fn
      {key, value, expires_at} when is_integer(expires_at) ->
        :ets.insert(@table, {key, value, min(expires_at, now + stagger_ms(key))})

      _other ->
        :ok
    end)
  end

  # 1..@invalidate_stagger_ms, stable per key: two consecutive catalog
  # writes don't reshuffle the order, and the same key always lands in the
  # same slot.
  defp stagger_ms(key), do: 1 + :erlang.phash2(key, @invalidate_stagger_ms)

  defp query_disabled_credentials do
    import Ecto.Query, only: [from: 2]

    Tokengate.Repo.all(
      from(c in Tokengate.Providers.Credential,
        where: c.status != "active",
        select: c.id
      )
    )
    |> MapSet.new()
  end
end
