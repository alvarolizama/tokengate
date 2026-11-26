defmodule Tokengate.SmartRouter.SessionPin do
  @moduledoc """
  Layer 0's memory: `{subject_id, session_key} -> pinned destination`.

  Changing the model mid-conversation invalidates the upstream prompt cache and
  breaks `reasoning_content` inside a tool loop, so the model that opened a
  conversation keeps it until the TTL expires or the conversation needs a
  capability the pinned destination does not have (`capability_upgrade`).

  ## Why the key is `{subject_id, session_key}`

  `StickyTracker` is keyed on `{api_key_hash, model_id}`; switching the model
  therefore misses its entry. Pinning one layer above — on the subject and the
  derived conversation key — keeps provider affinity intact across model
  switches while letting the same subject run many conversations.

  The pin is NEVER written for a `nil` session key. `SessionId.derive/2`
  returns `nil` for marker-less one-shot payloads, and falling back to the API
  key hash would pin every one-shot request of a subject to the first model
  for the whole TTL.

  Entries carry a monotonic `expires_at`; a read checks it lazily, so no sweep
  is required for correctness (the periodic sweep only reclaims memory).
  """

  use GenServer

  @table :tokengate_router_session_pins
  @sweep_ms :timer.seconds(60)

  @type pin :: %{
          use_case_id: String.t(),
          use_case_key: String.t(),
          use_case_model_id: String.t() | nil,
          model_id: String.t(),
          model_name: String.t() | nil,
          effort_tier: String.t() | nil,
          requirements: map()
        }

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The live pin for `{subject_id, session_key}`, or `nil`."
  @spec get(String.t() | nil, String.t() | nil) :: pin() | nil
  def get(nil, _session_key), do: nil
  def get(_subject_id, nil), do: nil

  def get(subject_id, session_key) do
    case :ets.lookup(@table, key(subject_id, session_key)) do
      [{_key, pin, expires_at}] ->
        if now() < expires_at do
          pin
        else
          :ets.delete(@table, key(subject_id, session_key))
          nil
        end

      [] ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Pins `session_key` to `pin` for `ttl_ms`. A non-positive TTL is a no-op
  (the pin would be dead on arrival).
  """
  @spec put(String.t() | nil, String.t() | nil, pin(), non_neg_integer()) :: :ok
  def put(nil, _session_key, _pin, _ttl_ms), do: :ok
  def put(_subject_id, nil, _pin, _ttl_ms), do: :ok

  def put(subject_id, session_key, pin, ttl_ms)
      when is_binary(subject_id) and is_binary(session_key) and is_map(pin) do
    if ttl_ms > 0 do
      :ets.insert(
        @table,
        {key(subject_id, session_key), pin, now() + ttl_ms}
      )
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops one pin."
  @spec clear(String.t() | nil, String.t() | nil) :: :ok
  def clear(nil, _session_key), do: :ok
  def clear(_subject_id, nil), do: :ok

  def clear(subject_id, session_key) do
    :ets.delete(@table, key(subject_id, session_key))
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops every pin (all nodes of the caller's node)."
  @spec clear_all() :: :ok
  def clear_all, do: flush()

  @doc false
  @spec flush() :: :ok
  def flush do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  # Test helper: ages an entry past its TTL without sleeping.
  def backdate_for_test(subject_id, session_key, ms) do
    case :ets.lookup(@table, key(subject_id, session_key)) do
      [{key, pin, expires_at}] ->
        :ets.insert(@table, {key, pin, expires_at - ms})
        :ok

      [] ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp key(subject_id, session_key), do: {subject_id, session_key}
  defp now, do: System.monotonic_time(:millisecond)

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

    :ok
  end
end
