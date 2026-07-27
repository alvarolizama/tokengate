defmodule Tokengate.Routing.StickyTracker do
  @moduledoc """
  GenServer that owns a public named ETS table (`:tokengate_sticky_routes`)
  mapping `{api_key_hash, model_alias_id}` to `{model_provider_id, inserted_at}`.

  The same API key is kept sticky to the same provider so that prompt-cache
  affinity is preserved across requests.

  Entries expire after `@ttl_ms` (30 minutes). Reads check the TTL lazily
  and return `nil` for expired entries, deleting them on the fly. A periodic
  sweep runs every `@sweep_interval_ms` to purge expired entries in bulk.

  The ETS table is created in `init/1` with `read_concurrency: true`. Reads
  can be performed directly against the public table (no GenServer call) via
  `get/2`; writes and clears go through the GenServer for single-writer
  ordering.

  ## Public API

    * `start_link/1`
    * `get/2`          – direct ETS read (no server round-trip), with TTL.
    * `put/3`          – async cast to the GenServer.
    * `clear/2`        – sync call removing a single key.
    * `clear_all_for_provider/1` – drops all stickies pointing at any of the
      given model_provider_ids (used when a provider goes down).
  """

  use GenServer

  @table :tokengate_sticky_routes
  # Sticky entries expire after 30 minutes — after this, the router returns
  # to the highest-priority active credential.
  @ttl_ms 30 * 60 * 1000
  @sweep_interval_ms 5 * 60 * 1000

  ## Public API ------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the `model_provider_id` stuck for `{api_key_hash, model_alias_id}`,
  or `nil` when no sticky entry exists, the entry has expired, or the
  tracker is not running.

  Reads directly from the public ETS table — no GenServer round-trip.
  Expired entries are deleted lazily on read.
  """
  @spec get(binary(), binary()) :: binary() | nil
  def get(api_key_hash, model_alias_id) do
    try do
      :ets.lookup(@table, {api_key_hash, model_alias_id})
    rescue
      ArgumentError -> nil
    else
      [{_, {model_provider_id, inserted_at}}] ->
        if expired?(inserted_at) do
          GenServer.cast(__MODULE__, {:delete, {api_key_hash, model_alias_id}})
          nil
        else
          model_provider_id
        end

      [] ->
        nil
    end
  end

  @doc """
  Sticks `{api_key_hash, model_alias_id}` to `model_provider_id`.

  Async cast: returns `:ok` immediately.
  """
  @spec put(binary(), binary(), binary()) :: :ok
  def put(api_key_hash, model_alias_id, model_provider_id) do
    GenServer.cast(__MODULE__, {:put, api_key_hash, model_alias_id, model_provider_id})
  end

  @doc """
  Removes the sticky entry for `{api_key_hash, model_alias_id}`.
  """
  @spec clear(binary(), binary()) :: :ok
  def clear(api_key_hash, model_alias_id) do
    GenServer.call(__MODULE__, {:clear, api_key_hash, model_alias_id})
  end

  @doc """
  Drops all sticky entries pointing at any of the given `model_provider_ids`.

  Called when a provider goes down so that traffic is redistributed.
  """
  @spec clear_all_for_provider([binary()]) :: :ok
  def clear_all_for_provider(model_provider_ids) when is_list(model_provider_ids) do
    GenServer.call(__MODULE__, {:clear_all_for_provider, model_provider_ids})
  end

  ## GenServer callbacks ---------------------------------------------------

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true
      ])

    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:put, api_key_hash, model_alias_id, model_provider_id}, state) do
    :ets.insert(
      @table,
      {{api_key_hash, model_alias_id}, {model_provider_id, System.monotonic_time(:millisecond)}}
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast({:delete, key}, state) do
    :ets.delete(@table, key)
    {:noreply, state}
  end

  @impl true
  def handle_call({:clear, api_key_hash, model_alias_id}, _from, state) do
    :ets.delete(@table, {api_key_hash, model_alias_id})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:clear_all_for_provider, model_provider_ids}, _from, state) do
    id_set = MapSet.new(model_provider_ids)
    now = System.monotonic_time(:millisecond)

    :ets.foldl(
      fn
        {{api_key_hash, model_alias_id} = key, {model_provider_id, inserted_at}}, acc
        when is_binary(api_key_hash) and is_binary(model_alias_id) ->
          # Delete if the entry points at a cleared provider OR has expired.
          if MapSet.member?(id_set, model_provider_id) or expired?(inserted_at, now) do
            :ets.delete(@table, key)
          end

          acc

        _other, acc ->
          acc
      end,
      :ok,
      @table
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    purge_expired()
    schedule_sweep()
    {:noreply, state}
  end

  ## Internal helpers ------------------------------------------------------

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp purge_expired do
    now = System.monotonic_time(:millisecond)

    :ets.foldl(
      fn
        {key, {_model_provider_id, inserted_at}}, acc ->
          if expired?(inserted_at, now) do
            :ets.delete(@table, key)
          end

          acc

        _other, acc ->
          acc
      end,
      :ok,
      @table
    )
  end

  defp expired?(inserted_at), do: expired?(inserted_at, System.monotonic_time(:millisecond))

  defp expired?(inserted_at, now), do: now - inserted_at > @ttl_ms
end
