defmodule Tokengate.Proxy.ResponseCache do
  @moduledoc """
  ETS-based response cache for identical non-streaming requests.

  Motivation: repeated identical requests (re-indexing embeddings, retried
  agents, dashboard refreshes) pay full input price upstream every time.
  OpenRouter's response caching demonstrates the pattern (zero-cost hits,
  ~5 min TTL); this is the gateway-local version, independent of provider
  support.

  ## Design

    * Public ETS table `:tokengate_response_cache`, keyed by
      `{api_key_hash, model, canonical_payload_hash}`.
    * Value: `{response_body_json, inserted_at, ttl_ms}`. Bodies are stored
      JSON-encoded to avoid keeping large decoded structures in memory and
      to make hits trivial to re-send.
    * Lazy TTL on read + periodic sweep (every sweep_interval/2), same
      discipline as `StickyTracker`.
    * Writes only on success (2xx). Streaming requests bypass the cache
      entirely — both read and write.
    * Bounded: entries carry max_entries cap with random eviction when
      full (keep it simple, no LRU — TTLs are short).

  Reads never require the GenServer (direct ETS); writes go through the
  GenServer for single-writer ordering.

  ## What is NOT cached

    * Streaming requests (`stream: true`)
    * Chat requests with tools — tool results make identical-looking
      requests semantically different in ways the hash can't see. TODO if
      this proves too conservative.
  """

  use GenServer

  @table :tokengate_response_cache
  @default_ttl_ms 5 * 60 * 1000
  @default_max_entries 2_000
  @sweep_interval_ms 60_000

  ## Public API ------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Default TTL in milliseconds.
  """
  def default_ttl_ms, do: @default_ttl_ms

  @doc """
  Builds the canonical cache key for a request. Returns nil when the
  payload is not cacheable (streaming, or chat with tools).
  """
  @spec cache_key(binary(), binary(), map()) :: {binary(), binary(), binary()} | nil
  def cache_key(api_key_hash, model, payload) when is_map(payload) do
    if cacheable?(payload) do
      {api_key_hash, model, canonical_hash(payload)}
    end
  end

  @doc """
  Looks up a cached response. Returns `{:ok, body_json, age_ms}` on a fresh
  hit, `:miss` otherwise. Expired entries are deleted lazily.
  """
  @spec lookup({binary(), binary(), binary()}) :: {:ok, String.t(), non_neg_integer} | :miss
  def lookup(key) do
    try do
      :ets.lookup(@table, key)
    rescue
      ArgumentError -> :miss
    else
      [{_, body_json, inserted_at, ttl_ms}] ->
        age = System.monotonic_time(:millisecond) - inserted_at

        if age < ttl_ms do
          {:ok, body_json, age}
        else
          :ets.delete(@table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  @doc """
  Stores a successful response body (already JSON-encoded by the caller).
  """
  @spec store({binary(), binary(), binary()}, String.t()) :: :ok
  def store(key, body_json) do
    try do
      GenServer.cast(__MODULE__, {:store, key, body_json})
    catch
      :exit, _ -> :ok
    end
  end

  ## GenServer -------------------------------------------------------------

  @impl true
  def init(opts) do
    :ets.new(@table, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)

    schedule_sweep()
    {:ok, %{ttl_ms: ttl, max_entries: max_entries}}
  end

  @impl true
  def handle_cast({:store, key, body_json}, state) do
    try do
      :ets.insert_new(@table, {key, body_json, System.monotonic_time(:millisecond), state.ttl_ms})
      maybe_evict(state)
    rescue
      ArgumentError -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(state)
    schedule_sweep()
    {:noreply, state}
  end

  ## Internals -------------------------------------------------------------

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  # Simple bound: when at cap, wipe the oldest third by inserted_at. Cheap
  # and good enough for a short-TTL cache.
  defp maybe_evict(%{max_entries: max} = _state) when max > 0 do
    count = :ets.info(@table, :size)

    if count > max do
      :ets.tab2list(@table)
      |> Enum.sort_by(fn {_k, _b, inserted_at, _ttl} -> inserted_at end, :asc)
      |> Enum.take(div(count - max, 2) + 1)
      |> Enum.each(fn {key, _, _, _} -> :ets.delete(@table, key) end)
    end

    :ok
  end

  defp maybe_evict(_), do: :ok

  defp sweep(state) do
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(@table)
    |> Enum.filter(fn {_k, _b, inserted_at, ttl_ms} -> now - inserted_at >= ttl_ms end)
    |> Enum.each(fn {key, _, _, _} -> :ets.delete(@table, key) end)

    {:ok, state}
  end

  # A payload is cacheable when it is not streaming and (for chat) carries
  # no tools. Embeddings always qualify.
  defp cacheable?(%{"stream" => true}), do: false
  defp cacheable?(%{"tools" => [_ | _]}), do: false
  defp cacheable?(_), do: true

  # Canonical hash: model + messages + the sampling params that change the
  # output, in a stable encoding. Fields that don't affect the output
  # (user tracking, session ids) are excluded so equivalent requests hash
  # equal regardless of telemetry.
  #
  # Chat has a canonical SUBSET: it carries telemetry (`user`, `session_id`)
  # whose changes must not break the cache. A service request (embeddings,
  # rerank, stt, tts, image, video, music) has no fixed output-shaping subset
  # — its whole payload IS the request — so it hashes everything except the
  # telemetry fields. Hashing it through the chat whitelist would make two
  # different `input`/`query`/`prompt` values hash EQUAL, and the second
  # request would receive the first one's cached answer.
  @canonical_fields ~w(model messages temperature top_p max_tokens presence_penalty frequency_penalty stop response_format seed tool_choice)
  @telemetry_fields ~w(user session_id)

  defp canonical_hash(%{"messages" => _} = payload) do
    payload
    |> Map.take(@canonical_fields)
    |> encode_hash()
  end

  defp canonical_hash(payload) do
    payload
    |> Map.drop(@telemetry_fields)
    |> encode_hash()
  end

  defp encode_hash(payload) do
    payload
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
