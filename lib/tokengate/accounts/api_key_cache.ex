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

      %{member: %GroupMember{}, limits: %{concurrency_limit:, rpm_limit:, credit_plan: %{subject:, limit_usd:, unlimited?:, topups: [...]}}, subject_type: "user" | "service"}

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
    * membership/service/group deletion — `delete_group_member/1`,
      `delete_service/1`, `delete_group/1` invalidate by id (group invalidates
      every member of the group).

  A stale entry can survive at most `@ttl_ms`; that window bounds how long a
  revoked key or edited limit takes to propagate. 60s is the same staleness
  contract the routing cache already accepts.

  ## Concurrency

  Named public ETS table owned by this GenServer; reads and writes run in
  the caller process (no bottleneck). The GenServer only creates the table
  and runs a periodic sweep of expired entries.
  """

  use GenServer

  @table :tokengate_api_key_cache
  @ttl_ms :timer.seconds(60)
  @sweep_ms :timer.seconds(60)

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
        if System.monotonic_time(:millisecond) < expires_at do
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

  @doc "Drops a single entry by token hash."
  @spec invalidate_hash(binary() | nil) :: :ok
  def invalidate_hash(nil), do: :ok

  def invalidate_hash(key_hash) when is_binary(key_hash) do
    :ets.delete(@table, key_hash)
    :ok
  end

  @doc "Drops every entry whose member id matches (any token hash of that member)."
  @spec invalidate_member(term()) :: :ok
  def invalidate_member(member_id) do
    :ets.match_delete(@table, {:_, %{member: %{id: member_id}}, :_})
    :ok
  end

  @doc "Drops every entry belonging to members of the given group."
  @spec invalidate_group(term()) :: :ok
  def invalidate_group(group_id) do
    :ets.match_delete(@table, {:_, %{member: %{group_id: group_id}}, :_})
    :ok
  end

  @doc """
  Drops every entry of a **user** (across all their memberships).

  El plan de gasto del usuario (su límite y SUS top-ups) viaja en cada entrada
  de sus keys: un top-up nuevo o revocado debe tumbar todas. Con un grupo por
  usuario basta con `invalidate_group/1`, pero el plan es del usuario, no del
  grupo — invalidar por usuario es lo correcto.
  """
  @spec invalidate_user(term()) :: :ok
  def invalidate_user(user_id) do
    :ets.match_delete(@table, {:_, %{member: %{user_id: user_id}}, :_})
    :ok
  end

  @doc "Drops the whole cache."
  @spec invalidate_all() :: :ok
  def invalidate_all do
    :ets.delete_all_objects(@table)
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
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp put_new(key, fun) do
    case fun.() do
      :error ->
        :error

      entry when is_map(entry) ->
        expires_at = System.monotonic_time(:millisecond) + @ttl_ms
        :ets.insert(@table, {key, entry, expires_at})
        entry
    end
  end

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
