defmodule Tokengate.Accounts.ApiKeyCache do
  @moduledoc """
  ETS cache for proxy API key lookups.

  The proxy hot path (`TokengateWeb.Plugs.ApiAuth`) used to hit Postgres on
  every request: member lookup with preloads (group, user, api_key) plus the
  service-key fallback. This cache stores the fully-assembled "auth entry"
   — the resolved `GroupMember` (or virtual service member) together with its
   `effective_limits` — keyed by `sha256(presented_token)`, so authenticated
   requests skip the database entirely.

  ## Entry shape

     %{member: %GroupMember{group: %Group{}, user: %User{}}, limits: %{concurrency_limit:, rpm_limit:, credit_plan: %{subject:, limit_usd:, unlimited?:, topups: [...]}}, subject_type: "user" | "service"}

  El miembro viaja con `:group` y `:user` precargados: `effective_limits/1`
  resuelve `propio (usuario) || contenedor (perfil de límites) || default`, así que ambos
  extremos de la regla tienen que estar dentro del entry cacheado.

  Caching the limits alongside the member avoids the extra preload/query
  `Accounts.effective_limits/1` performs for service-backed members.

  ## TTL & invalidation

  Entries live for `@ttl_ms` (60s). Writes that change auth-relevant state
  invalidate explicitly:

    * key rotation/revocation — `Accounts.replace_api_key/1`,
      `revoke_api_key/1`, `generate_service_api_key/1`,
      `revoke_service_api_key/1` invalidate by key hash (and by member so
      every hash of that member drops).
    * membership/service/group edits (status, limits) — `update_group_member/1`,
      `update_service/2`, `update_group/2` invalidate by id (group invalidates
      every member of the group).
    * user edits/deletion — `update_user/2`, `admin_update_user/2`,
      `delete_user/1` invalidate by id, which drops every entry of that user
      across all their memberships: los defaults propios del usuario son el
      primer eslabón de `effective_limits/1` y el plan de gasto es suyo.
    * membership/service/group deletion — `delete_group_member/1`,
      `delete_service/1`, `delete_group/1` invalidate by id (group invalidates
      every member of the group).

  A stale entry can survive at most `@ttl_ms`; that window bounds how long a
  revoked key or edited limit takes to propagate. 60s is the same staleness
  contract the routing cache already accepts.

  Invalidation is per node (the table lives in this node's ETS) but every
  writer propagates through `Tokengate.CacheInvalidation`: the calling node
  drops the entry synchronously and the other connected nodes drop theirs on
  the PubSub broadcast, so a revocation does not linger on the node that did
  not serve the write.

  ## Concurrency

  Named public ETS table owned by this GenServer; reads and writes run in
  the caller process (no bottleneck). The GenServer only creates the table
  and runs a periodic sweep of expired entries.

  Misses are single-flight: the first caller takes an `insert_new/2`
  placeholder `{:__computing__, key_hash}`, the rest wait (bounded to
  `@max_wait_ms`) for that entry instead of running the identical lookup.
  A crowd of proxy requests arriving right after the 60s TTL — or a
  brute-force burst on the same hash — costs one DB query per key, not N.
  A waiter that outlives its wait window computes locally (never raises),
  and caches its own result. Failures (`:error`) are never cached.

  The placeholder carries the holder's pid so waiters can monitor it: an
  external exit signal skips the `after` clause, and the `:DOWN` message
  releases the stale lock instead of wedging the key for the whole TTL.
  """

  use GenServer

  @table :tokengate_api_key_cache
  @ttl_ms :timer.seconds(60)
  @sweep_ms :timer.seconds(60)
  # How often a waiter re-checks for the entry a concurrent holder is
  # building. Short enough to be invisible next to the key lookup.
  @poll_interval_ms 5
  # Hard cap on how long a waiter blocks behind the lock: an auth request
  # cannot afford to stall behind a slow query. Past this window the waiter
  # runs its own lookup (a duplicate query is cheaper than a stalled proxy).
  @max_wait_ms 50

  # ---------------------------------------------------------------------------
  # Public API — hot path
  # ---------------------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the cached auth entry for a presented token hash, computing it via
  `fun` on a miss. `fun` must return the entry map or `:error` (invalid key —
  NOT cached, so brute-force probes always cost a DB lookup and the table
  can't grow unboundedly with junk hashes).

  Degrades gracefully: if the ETS table doesn't exist (hot code reload into
  a running node whose supervision tree predates this module, or the cache
  process being restarted), the lookup runs against the DB directly without
  caching. The cache is an optimization, never a hard dependency — auth must
  keep working even when it's gone.
  """
  @spec fetch(binary(), (-> map() | :error)) :: map() | :error
  def fetch(key_hash, fun) when is_binary(key_hash) and is_function(fun, 0) do
    if :ets.whereis(@table) == :undefined do
      fun.()
    else
      try do
        cached_fetch(key_hash, fun)
      rescue
        # The table raced away between the whereis check and the lookup
        # (owner process died / supervisor restart). Degrade to a direct
        # uncached lookup — never break auth over a cache.
        ArgumentError -> fun.()
      end
    end
  end

  defp cached_fetch(key_hash, fun) do
    case :ets.lookup(@table, key_hash) do
      [{^key_hash, entry, expires_at}] ->
        if now() < expires_at do
          entry
        else
          :ets.delete(@table, key_hash)
          put_new(key_hash, fun)
        end

      [] ->
        put_new(key_hash, fun)
    end
  end

  # ---------------------------------------------------------------------------
  # Invalidation
  # ---------------------------------------------------------------------------

  @doc "Drops a single entry by token hash (on this node and the others)."
  @spec invalidate_hash(binary() | nil) :: :ok
  def invalidate_hash(nil), do: :ok

  def invalidate_hash(key_hash) when is_binary(key_hash),
    do: dispatch({:hash, key_hash})

  @doc "Drops every entry whose member id matches (any token hash of that member)."
  @spec invalidate_member(term()) :: :ok
  def invalidate_member(member_id), do: dispatch({:member, member_id})

  @doc "Drops every entry belonging to members of the given group."
  @spec invalidate_group(term()) :: :ok
  def invalidate_group(group_id), do: dispatch({:group, group_id})

  @doc """
  Drops every entry of a **user** (across all their memberships).

  El plan de gasto del usuario (su límite y SUS top-ups) viaja en cada entrada
  de sus keys: un top-up nuevo o revocado debe tumbar todas. Con un perfil de límites por
  usuario basta con `invalidate_group/1`, pero el plan es del usuario, no del
  perfil de límites — invalidar por usuario es lo correcto.
  """
  @spec invalidate_user(term()) :: :ok
  def invalidate_user(user_id), do: dispatch({:user, user_id})

  @doc "Drops the whole cache (on this node and the others)."
  @spec invalidate_all() :: :ok
  def invalidate_all, do: dispatch(:all)

  # Local-only application of an invalidation operation. Used by
  # `Tokengate.CacheInvalidation` for the operations that arrive from another
  # node, and called synchronously for the caller's own node by `dispatch/1`.
  #
  # Guarded by `:ets.whereis/1`: a cache without its owner (early boot,
  # post-crash restart, a release task with no supervision tree) has nothing
  # to invalidate.
  @doc false
  @spec apply_local(term()) :: :ok
  def apply_local({:hash, key_hash}) do
    if table_exists?(), do: :ets.delete(@table, key_hash)
    :ok
  end

  def apply_local({:member, member_id}) do
    if table_exists?(), do: :ets.match_delete(@table, {:_, %{member: %{id: member_id}}, :_})
    :ok
  end

  def apply_local({:group, group_id}) do
    if table_exists?(), do: :ets.match_delete(@table, {:_, %{member: %{group_id: group_id}}, :_})
    :ok
  end

  def apply_local({:user, user_id}) do
    if table_exists?(),
      do: :ets.match_delete(@table, {:_, %{member: %{user_id: user_id}}, :_})

    :ok
  end

  def apply_local(:all) do
    if table_exists?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  def apply_local(_op), do: :ok

  defp dispatch(op), do: Tokengate.CacheInvalidation.dispatch(:api_key_cache, op)

  defp table_exists?, do: :ets.whereis(@table) != :undefined

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
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp put_new(key, fun) do
    lock_key = {:__computing__, key}
    deadline = now() + @max_wait_ms

    if :ets.insert_new(@table, {lock_key, {:computing, self()}, deadline}) do
      try do
        compute_and_cache(key, fun)
      after
        # Releases on normal return AND on raise/exit: a crashing lookup
        # must not leave the key wedged for the whole TTL.
        :ets.delete(@table, lock_key)
      end
    else
      case await_entry(key, lock_key, deadline) do
        {:ok, entry} ->
          entry

        # The holder died (its `after` never ran — the waiter cleared the
        # stale lock via monitor), or outlived the capped wait window.
        # Compute locally and cache the result; never raise: auth must keep
        # working even when the coalescing path can't help.
        :miss ->
          compute_and_cache(key, fun)
      end
    end
  end

  # `fun` is the DB lookup: a map is cached for @ttl_ms, `:error` (invalid
  # key) is never cached so brute-force probes always hit the database.
  defp compute_and_cache(key, fun) do
    case fun.() do
      :error ->
        :error

      entry when is_map(entry) ->
        :ets.insert(@table, {key, entry, now() + @ttl_ms})
        entry
    end
  end

  # Waits (bounded) for the holder to publish the entry. The placeholder
  # carries the holder's pid, so waiters monitor it: when the holder dies on
  # an external exit signal its `after` clause never runs — the `:DOWN`
  # message releases the lock instead of leaving every waiter until deadline.
  defp await_entry(key, lock_key, deadline) do
    holder_pid = holder_pid(lock_key)
    wait_deadline = min(deadline, now() + @max_wait_ms)
    ref = holder_pid && Process.monitor(holder_pid)

    try do
      await_entry(key, lock_key, wait_deadline, ref)
    after
      ref && Process.demonitor(ref, [:flush])
    end
  end

  defp await_entry(key, lock_key, deadline, ref) do
    case lookup_fresh(key) do
      {:ok, entry} ->
        {:ok, entry}

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
            await_entry(key, lock_key, deadline, ref)
        end
    end
  end

  defp lookup_fresh(key) do
    case :ets.lookup(@table, key) do
      [{^key, entry, expires_at}] -> if now() < expires_at, do: {:ok, entry}, else: :miss
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
  # the meantime (a re-attempt may already own the key with its own pid).
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
