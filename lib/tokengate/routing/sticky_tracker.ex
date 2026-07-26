defmodule Tokengate.Routing.StickyTracker do
  @moduledoc """
  GenServer that owns a public named ETS table (`:tokengate_sticky_routes`)
  mapping `{api_key_hash, model_alias_id}` to `alias_provider_id`.

  The same API key is kept sticky to the same provider so that prompt-cache
  affinity is preserved across requests.

  The ETS table is created in `init/1` with `read_concurrency: true`. Reads
  can be performed directly against the public table (no GenServer call) via
  `get/2`; writes and clears go through the GenServer for single-writer
  ordering.

  ## Public API

    * `start_link/1`
    * `get/2`          – direct ETS read (no server round-trip).
    * `put/3`          – async cast to the GenServer.
    * `clear/2`        – sync call removing a single key.
    * `clear_all_for_provider/1` – drops all stickies pointing at any of the
      given alias_provider_ids (used when a provider goes down).
  """

  use GenServer

  @table :tokengate_sticky_routes

  ## Public API ------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the `alias_provider_id` stuck for `{api_key_hash, model_alias_id}`,
  or `nil` when no sticky entry exists or the tracker is not running.

  Reads directly from the public ETS table — no GenServer round-trip.
  """
  @spec get(binary(), binary()) :: binary() | nil
  def get(api_key_hash, model_alias_id) do
    try do
      :ets.lookup(@table, {api_key_hash, model_alias_id})
    rescue
      ArgumentError -> nil
    else
      [{_, alias_provider_id}] -> alias_provider_id
      [] -> nil
    end
  end

  @doc """
  Sticks `{api_key_hash, model_alias_id}` to `alias_provider_id`.

  Async cast: returns `:ok` immediately.
  """
  @spec put(binary(), binary(), binary()) :: :ok
  def put(api_key_hash, model_alias_id, alias_provider_id) do
    GenServer.cast(__MODULE__, {:put, api_key_hash, model_alias_id, alias_provider_id})
  end

  @doc """
  Removes the sticky entry for `{api_key_hash, model_alias_id}`.
  """
  @spec clear(binary(), binary()) :: :ok
  def clear(api_key_hash, model_alias_id) do
    GenServer.call(__MODULE__, {:clear, api_key_hash, model_alias_id})
  end

  @doc """
  Drops all sticky entries pointing at any of the given `alias_provider_ids`.

  Called when a provider goes down so that traffic is redistributed.
  """
  @spec clear_all_for_provider([binary()]) :: :ok
  def clear_all_for_provider(alias_provider_ids) when is_list(alias_provider_ids) do
    GenServer.call(__MODULE__, {:clear_all_for_provider, alias_provider_ids})
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

    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:put, api_key_hash, model_alias_id, alias_provider_id}, state) do
    :ets.insert(@table, {{api_key_hash, model_alias_id}, alias_provider_id})
    {:noreply, state}
  end

  @impl true
  def handle_call({:clear, api_key_hash, model_alias_id}, _from, state) do
    :ets.delete(@table, {api_key_hash, model_alias_id})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:clear_all_for_provider, alias_provider_ids}, _from, state) do
    id_set = MapSet.new(alias_provider_ids)

    :ets.foldl(
      fn
        {{api_key_hash, model_alias_id} = key, alias_provider_id}, acc
        when is_binary(api_key_hash) and is_binary(model_alias_id) ->
          if MapSet.member?(id_set, alias_provider_id) do
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
end
