defmodule Tokengate.Proxy.ResponseCacheTest do
  @moduledoc """
  Covers ResponseCache: cacheability rules, hit/miss lifecycle, TTL expiry.
  """
  use ExUnit.Case, async: false

  alias Tokengate.Proxy.ResponseCache

  setup do
    # The module's public API talks to the __MODULE__-named process and its
    # named ETS table. Start it supervised per test (no-op + rescue when a
    # previous test in this file already left it running under the same
    # supervisor tree via the app supervision — ExUnit isolates per file
    # with async: false so this is deterministic).
    case ResponseCache.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  test "cache_key returns nil for streaming payloads" do
    assert ResponseCache.cache_key("key", "model", %{"stream" => true}) == nil
  end

  test "cache_key returns nil for chat with tools" do
    payload = %{"tools" => [%{"type" => "function"}]}
    assert ResponseCache.cache_key("key", "model", payload) == nil
  end

  test "cache_key ignores telemetry fields, keeps sampling params" do
    base = %{
      "model" => "m",
      "messages" => [%{"role" => "user", "content" => "hi"}],
      "user" => "tracker-123"
    }

    other_user = Map.put(base, "user", "tracker-999")
    temp = Map.put(base, "temperature", 0.9)

    assert ResponseCache.cache_key("k", "m", base) ==
             ResponseCache.cache_key("k", "m", other_user)

    refute ResponseCache.cache_key("k", "m", base) == ResponseCache.cache_key("k", "m", temp)
  end

  # A service payload (embeddings, stt, …) has no output-shaping
  # subset: its input fields ARE the request. Two different inputs must not
  # share a cache entry, or the second request gets the first one's answer.
  test "cache_key distinguishes different service inputs" do
    base = %{"model" => "m", "input" => "uno"}

    other = %{"model" => "m", "input" => "dos"}

    refute ResponseCache.cache_key("k", "m", base) == ResponseCache.cache_key("k", "m", other)
  end

  test "cache_key of a service payload still ignores telemetry" do
    base = %{"model" => "m", "input" => "uno", "query" => "q", "user" => "tracker-123"}

    other_user = Map.put(base, "user", "tracker-999")

    assert ResponseCache.cache_key("k", "m", base) ==
             ResponseCache.cache_key("k", "m", other_user)
  end

  test "cache_key distinguishes every service capability's own field" do
    keys =
      for field <- ~w(input prompt query documents), value <- ~w(uno dos) do
        ResponseCache.cache_key("k", "m", %{"model" => "m", field => value})
      end

    assert length(Enum.uniq(keys)) == length(keys)
  end

  test "cache_key is scoped per api key and model" do
    payload = %{"messages" => [%{"role" => "user", "content" => "hi"}]}

    refute ResponseCache.cache_key("k1", "m", payload) ==
             ResponseCache.cache_key("k2", "m", payload)

    refute ResponseCache.cache_key("k", "m1", payload) ==
             ResponseCache.cache_key("k", "m2", payload)
  end

  test "store then lookup roundtrips the body" do
    key = ResponseCache.cache_key("k-rt", "m", %{"messages" => []})

    :ok = ResponseCache.store(key, ~s({"answer": 42}))
    # store is a fire-and-forget cast (hot path); sync with the server
    # before asserting.
    _ = :sys.get_state(Process.whereis(ResponseCache))

    assert {:ok, ~s({"answer": 42}), _age} = ResponseCache.lookup(key)
  end

  test "lookup misses for unknown keys" do
    assert ResponseCache.lookup({"k-miss", "m", "nope"}) == :miss
  end

  test "insert_new semantics: first write wins" do
    key = ResponseCache.cache_key("k-in", "m", %{"messages" => []})

    :ok = ResponseCache.store(key, ~s({"v": 1}))
    :ok = ResponseCache.store(key, ~s({"v": 2}))
    _ = :sys.get_state(Process.whereis(ResponseCache))

    assert {:ok, body, _} = ResponseCache.lookup(key)
    assert body == ~s({"v": 1})
  end

  # F45: the sweep used to `:ets.tab2list/1` the WHOLE cache (every cached LLM
  # body) on every tick. It now walks the expiry index and stops at the first
  # live entry, so a live entry is never even read.
  test "sweep removes only the expired entries and keeps live ones" do
    now = System.monotonic_time(:millisecond)

    expired_keys =
      for i <- 1..2 do
        key = {"k-sweep", "m", "expired-#{i}"}
        inserted_at = now - 10_000
        :ets.insert(:tokengate_response_cache, {key, ~s({"old": #{i}}), inserted_at, 1_000})
        :ets.insert(:tokengate_response_cache_expiry, {{inserted_at + 1_000, key}, key})
        key
      end

    live_key = {"k-sweep", "m", "live"}
    :ets.insert(:tokengate_response_cache, {live_key, ~s({"live": true}), now, 60_000})
    :ets.insert(:tokengate_response_cache_expiry, {{now + 60_000, live_key}, live_key})

    pid = Process.whereis(ResponseCache)
    send(pid, :sweep)
    _ = :sys.get_state(pid)

    for key <- expired_keys do
      assert ResponseCache.lookup(key) == :miss
    end

    assert {:ok, ~s({"live": true}), _age} = ResponseCache.lookup(live_key)
    assert :ets.lookup(:tokengate_response_cache_expiry, {now + 60_000, live_key}) != []
  end

  # The cap is enforced from the SAME expiry index: the oldest entries are the
  # earliest to expire, so eviction never sorts (or copies) the whole cache.
  test "eviction keeps the cache at max_entries, dropping the oldest" do
    max = 2_000
    # Own the table for this test: the eviction order is only deterministic
    # when the cache does not carry another test's entries.
    :ets.delete_all_objects(:tokengate_response_cache)
    :ets.delete_all_objects(:tokengate_response_cache_expiry)

    # Keys sort by (expiry, key); every store in this test happens within a
    # few milliseconds, so "1" is the earliest deadline AND the smallest key
    # of its batch — it is the first to go.
    retired = {"k-cap", "m", "1"}
    newest = {"k-cap", "m", Integer.to_string(max + 100)}

    for i <- 1..(max + 100) do
      :ok = ResponseCache.store({"k-cap", "m", Integer.to_string(i)}, ~s({"i": #{i}}))
    end

    _ = :sys.get_state(Process.whereis(ResponseCache))

    assert :ets.info(:tokengate_response_cache, :size) <= max
    assert ResponseCache.lookup(retired) == :miss
    assert {:ok, _body, _age} = ResponseCache.lookup(newest)

    assert :ets.info(:tokengate_response_cache_expiry, :size) ==
             :ets.info(:tokengate_response_cache, :size)
  end
end
