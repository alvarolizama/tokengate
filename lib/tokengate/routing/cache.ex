defmodule Tokengate.Routing.Cache do
  @moduledoc """
  ETS-backed routing cache: avoids re-querying Postgres for the same
  (model_alias_id, team_id) provider list on every proxied request.

  ## What is cached

    * `{:model_providers, model_alias_id, team_id}` — the ordered list of
      `ModelProvider` structs (with credential + provider preloaded) visible to
      that scope. `team_id` may be `:global` for service/virtual members.
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
  process. The owning GenServer only creates the table and handles TTL
  sweeps. A `:timer` entry per key expires the cache after `@ttl_ms`.
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

  `team_id` may be `nil` for global/service scope (the cache key uses
  `:global`). `fun` is the DB query — it is only executed on a cache miss.
  """
  @spec fetch_model_providers(binary(), binary() | nil, (-> [term()])) :: [term()]
  def fetch_model_providers(model_alias_id, team_id, fun) when is_function(fun, 0) do
    key = {:model_providers, model_alias_id, team_id || :global}

    case :ets.lookup(@table, key) do
      [{^key, providers, _expires_at}] -> providers
      [] -> put_new(key, fun.())
    end
  end

  @doc """
  Returns a `MapSet` of credential ids that are currently NOT `status ==
  "active"`. Computed from the DB on first call; cached for `@ttl_ms`.
  """
  @spec disabled_credential_ids() :: MapSet.t()
  def disabled_credential_ids do
    key = :disabled_credentials

    case :ets.lookup(@table, key) do
      [{^key, %MapSet{} = set, _expires_at}] -> set
      [] -> put_new(key, query_disabled_credentials())
    end
  end

  @doc """
  Invalidates a specific cache key (`{:model_providers, alias_id, team_id}`)
  or the whole `:disabled_credentials` set.
  """
  @spec invalidate(tuple() | :disabled_credentials) :: :ok
  def invalidate(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Drops every cached entry. Called after bulk writes (team deletion, provider
  deletion, etc.).
  """
  @spec invalidate_all() :: :ok
  def invalidate_all do
    :ets.delete_all_objects(@table)
    :ok
  end

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
