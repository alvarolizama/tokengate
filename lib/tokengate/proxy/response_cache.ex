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
    * A companion `:ordered_set` index (`:tokengate_response_cache_expiry`)
      keyed by `{expires_at_ms, key}`. Expiry is a total order over the
      cache, so the periodic sweep and the eviction at the size cap walk
      ONLY the entries they are about to delete. The previous version
      `:ets.tab2list/1`-ed the whole table — every cached LLM body copied,
      sorted and filtered — on each sweep and on every store above the cap.
    * Lazy TTL on read + periodic sweep (every sweep_interval/2), same
      discipline as `StickyTracker`.
    * Writes only on success (2xx). Streaming requests bypass the cache
      entirely — both read and write.
    * Bounded: entries carry max_entries cap; the oldest entries (earliest
      expiry) are evicted in expiry order when full (no LRU — TTLs are
      short).

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
  @expiry_table :tokengate_response_cache_expiry
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
          drop_entry(key, {inserted_at + ttl_ms, key})
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
    ensure_tables()

    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)

    schedule_sweep()
    {:ok, %{ttl_ms: ttl, max_entries: max_entries}}
  end

  @impl true
  def handle_cast({:store, key, body_json}, state) do
    now = System.monotonic_time(:millisecond)

    try do
      # `insert_new`: the first write for a key wins, and only that write owns
      # the expiry index entry — a second store for the same key must not
      # index a body it never wrote.
      if :ets.insert_new(@table, {key, body_json, now, state.ttl_ms}) do
        :ets.insert(@expiry_table, {{now + state.ttl_ms, key}, key})
      end

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

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals -------------------------------------------------------------

  defp ensure_tables do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    if :ets.whereis(@expiry_table) == :undefined do
      :ets.new(@expiry_table, [
        :ordered_set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  # Bound: when at cap, drop the OLDEST entries. With a uniform TTL the
  # earliest expiry is the oldest insertion, and the expiry index hands them
  # over in order — no full-table copy, no sort of the whole cache.
  defp maybe_evict(%{max_entries: max}) when max > 0 do
    count = :ets.info(@table, :size)

    if count > max do
      (div(count - max, 2) + 1)
      |> oldest_index_keys()
      |> Enum.each(fn {_expires_at, key} = index_key -> drop_entry(key, index_key) end)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp maybe_evict(_), do: :ok

  # Walks the expiry index from the earliest deadline and stops at the first
  # entry that is still live: the work is proportional to what expired, not
  # to the size of the cache.
  defp sweep(state) do
    now = System.monotonic_time(:millisecond)
    delete_expired(now)
    {:ok, state}
  end

  defp delete_expired(now) do
    case :ets.first(@expiry_table) do
      {expires_at, _key} = index_key when expires_at <= now ->
        :ets.delete(@expiry_table, index_key)
        drop_body(index_key)
        delete_expired(now)

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp oldest_index_keys(count), do: collect_index_keys(count, :ets.first(@expiry_table), [])

  defp collect_index_keys(0, _index_key, acc), do: Enum.reverse(acc)

  defp collect_index_keys(_count, :"$end_of_table", acc), do: Enum.reverse(acc)

  defp collect_index_keys(count, index_key, acc) do
    collect_index_keys(count - 1, :ets.next(@expiry_table, index_key), [index_key | acc])
  end

  # Deletes the body only when the index entry still points at the CURRENT
  # body: an expiry entry left behind by an evicted-and-restored key must not
  # delete the fresh copy. `index_key` is the ETS key (`{expires_at, key}`),
  # which is what `:ets.first/1` hands back.
  defp drop_body({expires_at, key}) do
    case :ets.lookup(@table, key) do
      [{_, _body, inserted_at, ttl_ms}] when inserted_at + ttl_ms == expires_at ->
        :ets.delete(@table, key)

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp drop_entry(key, {_expires_at, key} = index_key) do
    :ets.delete(@expiry_table, index_key)
    :ets.delete(@table, key)
  rescue
    ArgumentError -> :ok
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
  # stt, tts, image) has no fixed output-shaping subset
  # — its whole payload IS the request — so it hashes everything except the
  # telemetry fields. Hashing it through the chat whitelist would make two
  # different `input`/`prompt` values hash EQUAL, and the second
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
