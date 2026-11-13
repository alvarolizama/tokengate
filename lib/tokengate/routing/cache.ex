defmodule Tokengate.Routing.Cache do
  @moduledoc """
  ETS-backed routing cache: avoids re-querying Postgres for the same
  (model_id, group_id) provider list on every proxied request.

  ## What is cached

    * `{:model_providers, model_id, group_id}` — the ordered list of
      `ModelProvider` structs (with credential + provider preloaded) visible to
      that scope. `group_id` may be `:global` for service/virtual members.
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

  ## Concurrency

  All reads/writes are lock-free `public` ETS ops running in the caller
  process. The owning GenServer only creates the table. Entries carry a
  monotonic `expires_at`; a read treats an expired entry as a miss (and
  deletes it), so the effective TTL is `@ttl_ms` even without a sweep.
  """

  use GenServer

  @table :tokengate_routing_cache
  @ttl_ms :timer.minutes(1)

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

  `group_id` may be `nil` for global/service scope (the cache key uses
  `:global`). `fun` is the DB query — it is only executed on a cache miss.
  """
  @spec fetch_model_providers(binary(), binary() | nil, (-> [term()])) :: [term()]
  def fetch_model_providers(model_id, group_id, fun) when is_function(fun, 0) do
    fetch_fresh({:model_providers, model_id, group_id || :global}, fun)
  end

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

  def apply_local(:all) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
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
  end

  # TTL on read: `expires_at` is an absolute monotonic deadline stored with the
  # entry. Without this check the written deadline was dead weight — a missed
  # invalidation (or an unsupported write path) would keep a stale entry alive
  # forever, and the router now serves every request from this cache.
  defp fetch_fresh(key, fun) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          value
        else
          :ets.delete(@table, key)
          put_new(key, fun.())
        end

      [] ->
        put_new(key, fun.())
    end
  end

  defp put_new(key, value) do
    expires_at = System.monotonic_time(:millisecond) + @ttl_ms
    true = :ets.insert(@table, {key, value, expires_at})
    value
  end

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
