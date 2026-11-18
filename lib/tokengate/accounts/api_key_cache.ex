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

    * key rotation/revocation — `Accounts.revoke_and_replace_api_key/1`,
      `Accounts.revoke_api_key/1`, `Accounts.hide_api_key/1`,
      `Accounts.generate_service_api_key/1`, `Accounts.revoke_service_api_key/1`
      invalidate by key hash (and by subject so every hash of that subject
      drops).
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

  Two named public ETS tables owned by this GenServer — entries and the
  single-flight locks — so reads and writes run in the caller process (no
  bottleneck). The GenServer only creates the tables and runs a periodic sweep
  of expired entries and stale locks.

  Misses are single-flight: the first caller takes an `insert_new/2` lock in
  the lock table (keyed by the same token hash), the rest wait for it instead
  of running the identical lookup. Only the lock owner ever queries the
  database, so a crowd of proxy requests arriving right after the 60s TTL — or
  a brute-force burst on the same hash — costs one DB query per key, not N.

  Waiters block up to `@max_wait_ms` (5s) for the holder to publish. If the
  holder overruns that window, a waiter takes the lock over atomically
  (`select_replace`, only when the lock's own deadline has passed) and computes
  **once**: the takeover never lets two waiters query at the same time. A
  holder that dies without running its `after` block (external exit signal) is
  detected through the monitor on its pid and its lock is released, so the key
  cannot stay wedged for the whole TTL. Failures (`:error`) are never cached.
  """

  use GenServer

  @table :tokengate_api_key_cache
  @lock_table :tokengate_api_key_cache_locks
  @ttl_ms :timer.seconds(60)
  @sweep_ms :timer.seconds(60)
  # How often a waiter re-checks for the entry a concurrent holder is
  # building. Short enough to be invisible next to the key lookup.
  @poll_interval_ms 5
  # How long a waiter blocks behind the lock before taking the lock over. It
  # has to outlive a slow-but-alive lookup: expiring early is exactly what made
  # every waiter duplicate the query under load. Past this window the waiter
  # takes the lock atomically and computes — once — instead of every waiter
  # querying on its own.
  @max_wait_ms 5_000
  # Bounded retries of the acquire/wait cycle: a lock that keeps changing hands
  # must never wedge an auth request.
  @max_attempts 4

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

  Degrades gracefully: if the ETS tables don't exist (hot code reload into
  a running node whose supervision tree predates this module, or the cache
  process being restarted), the lookup runs against the DB directly without
  caching. The cache is an optimization, never a hard dependency — auth must
  keep working even when it's gone.
  """
  @spec fetch(binary(), (-> map() | :error)) :: map() | :error
  def fetch(key_hash, fun) when is_binary(key_hash) and is_function(fun, 0) do
    if table_exists?(@table) and table_exists?(@lock_table) do
      try do
        cached_fetch(key_hash, fun)
      rescue
        # The table raced away between the whereis check and the lookup
        # (owner process died / supervisor restart). Degrade to a direct
        # uncached lookup — never break auth over a cache.
        ArgumentError -> fun.()
      end
    else
      fun.()
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
    if table_exists?(@table), do: :ets.delete(@table, key_hash)
    :ok
  end

  def apply_local({:member, member_id}) do
    if table_exists?(@table), do: :ets.match_delete(@table, {:_, %{member: %{id: member_id}}, :_})
    :ok
  end

  def apply_local({:group, group_id}) do
    if table_exists?(@table),
      do: :ets.match_delete(@table, {:_, %{member: %{group_id: group_id}}, :_})

    :ok
  end

  def apply_local({:user, user_id}) do
    if table_exists?(@table),
      do: :ets.match_delete(@table, {:_, %{member: %{user_id: user_id}}, :_})

    :ok
  end

  def apply_local(:all) do
    if table_exists?(@table), do: :ets.delete_all_objects(@table)
    :ok
  end

  def apply_local(_op), do: :ok

  defp dispatch(op), do: Tokengate.CacheInvalidation.dispatch(:api_key_cache, op)

  defp table_exists?(table), do: :ets.whereis(table) != :undefined

  @doc false
  def table, do: @table

  @doc false
  def lock_table, do: @lock_table

  # ---------------------------------------------------------------------------
  # GenServer — table owner + TTL sweep
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    ensure_table(@table)
    ensure_table(@lock_table)
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    # Expired entries and stale locks go in the same pass: a lock whose holder
    # vanished must not occupy the hash forever.
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    :ets.select_delete(@lock_table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Single-flight internals
  # ---------------------------------------------------------------------------

  defp put_new(key, fun) do
    do_put_new(key, fun, @max_attempts)
  end

  # Single-flight core. Exactly one process owns the lock at a time and only
  # the owner runs `fun`: waiters observe the published entry, or wait for the
  # lock to be released, or (past @max_wait_ms) take a stale lock over. None of
  # those paths duplicates the lookup while another process is computing.
  defp do_put_new(key, fun, attempts) do
    if acquire_lock(key) do
      compute_owned(key, fun)
    else
      case await_entry(key) do
        {:ok, entry} ->
          entry

        :took_over ->
          compute_owned(key, fun)

        :miss when attempts > 1 ->
          do_put_new(key, fun, attempts - 1)

        # Last resort: a lock that keeps changing hands must never wedge auth.
        # One uncached lookup beats a stalled request (and nothing is cached
        # from this path, so the next caller still goes through single-flight).
        :miss ->
          fun.()
      end
    end
  end

  defp acquire_lock(key) do
    :ets.insert_new(@lock_table, {key, self(), lock_deadline()})
  end

  # Only the owner releases the lock: compare-and-delete by pid, so a holder
  # whose lock was taken over cannot release the new owner's lock.
  defp compute_owned(key, fun) do
    try do
      compute_and_cache(key, fun)
    after
      release_own_lock(key)
    end
  end

  defp release_own_lock(key) do
    pid = self()
    :ets.select_delete(@lock_table, [{{key, pid, :_}, [], [true]}])
    :ok
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

  # Waits (bounded) for the holder to publish the entry. The lock carries the
  # holder's pid, so waiters monitor it: when the holder dies on an external
  # exit signal its `after` clause never runs — the `:DOWN` message releases
  # the lock instead of leaving every waiter until the deadline.
  defp await_entry(key) do
    holder_pid = holder_pid(key)
    ref = holder_pid && Process.monitor(holder_pid)

    try do
      await_entry(key, lock_deadline(), ref)
    after
      ref && Process.demonitor(ref, [:flush])
    end
  end

  defp await_entry(key, deadline, ref) do
    case lookup_fresh(key) do
      {:ok, entry} ->
        {:ok, entry}

      :miss ->
        cond do
          # The holder finished without publishing (its lookup returned
          # `:error`): the lock is gone and the value is not cached by design.
          :ets.lookup(@lock_table, key) == [] ->
            :miss

          received_down?(ref) ->
            release_stale_lock(key, holder_pid(key))
            :miss

          # The holder overran its own window: take the lock over atomically.
          # Only one waiter wins, and it computes once — the rest keep waiting
          # on the fresh lock instead of duplicating the query.
          lock_expired?(key) ->
            if steal_lock(key), do: :took_over, else: :miss

          now() >= deadline ->
            :miss

          true ->
            Process.sleep(@poll_interval_ms)
            await_entry(key, deadline, ref)
        end
    end
  end

  defp lock_expired?(key) do
    case :ets.lookup(@lock_table, key) do
      [{^key, _pid, deadline}] -> deadline <= now()
      _ -> false
    end
  end

  # Atomic compare-and-swap of an expired lock: only a lock whose own deadline
  # has passed can be replaced, and only one waiter wins the `select_replace`.
  # The winner becomes the holder (its pid + a fresh deadline) and computes.
  defp steal_lock(key) do
    pid = self()
    new_deadline = lock_deadline()
    current = now()

    :ets.select_replace(@lock_table, [
      {{key, :_, :"$1"}, [{:<, :"$1", current}], [{{key, {:const, pid}, new_deadline}}]}
    ]) == 1
  end

  defp lock_deadline, do: now() + @max_wait_ms

  defp lookup_fresh(key) do
    case :ets.lookup(@table, key) do
      [{^key, entry, expires_at}] -> if now() < expires_at, do: {:ok, entry}, else: :miss
      [] -> :miss
    end
  end

  defp holder_pid(key) do
    case :ets.lookup(@lock_table, key) do
      [{^key, pid, _deadline}] when is_pid(pid) -> pid
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
  defp release_stale_lock(key, dead_pid) do
    case :ets.match(@lock_table, {key, :"$1", :_}) do
      [[^dead_pid]] -> :ets.delete(@lock_table, key)
      _ -> :ok
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp ensure_table(table) do
    if :ets.whereis(table) == :undefined do
      :ets.new(table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end
  end
end
