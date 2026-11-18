defmodule Tokengate.CacheInvalidationTest do
  @moduledoc """
  Cross-node propagation of ETS cache invalidations.

  The caches are per-node tables, so the only interesting behavior is:
  (1) `dispatch` applies locally and synchronously (the writer's node is
  never stale after the write), and (2) an operation that arrives from
  ANOTHER node is applied locally by the subscriber. A real second node is
  not available in the suite, so remote delivery is exercised by sending the
  exact broadcast payload (`{CacheInvalidation, target, op, remote_node}`)
  to the subscriber and synchronizing with `:sys.get_state/1`.

  `async: false`: the cache tables and this GenServer are VM-wide singletons.
  """

  use ExUnit.Case, async: false

  alias Tokengate.Accounts.ApiKeyCache
  alias Tokengate.Cache
  alias Tokengate.CacheInvalidation
  alias Tokengate.Routing

  @remote :otro_nodo@remoto

  setup do
    pid = Process.whereis(CacheInvalidation) || start_supervised!(CacheInvalidation)
    _ = :sys.get_state(pid)
    :ok
  end

  describe "local application (dispatch)" do
    test "api keys: a local invalidation drops the entry immediately" do
      hash = "hash-#{System.unique_integer([:positive])}"
      assert ApiKeyCache.fetch(hash, fn -> %{member: %{id: "m1"}} end) == %{member: %{id: "m1"}}
      assert [_] = :ets.lookup(ApiKeyCache.table(), hash)

      assert :ok = ApiKeyCache.invalidate_hash(hash)

      assert [] = :ets.lookup(ApiKeyCache.table(), hash)
    end

    test "api key member invalidation is scoped: other members survive" do
      table = ApiKeyCache.table()
      :ets.insert(table, {"h-a", %{member: %{id: "member-a"}}, future()})
      :ets.insert(table, {"h-b", %{member: %{id: "member-b"}}, future()})

      :ok = ApiKeyCache.invalidate_member("member-a")

      assert [] = :ets.lookup(table, "h-a")
      assert [_] = :ets.lookup(table, "h-b")
    end

    test "generic cache: a local invalidation drops only the named key" do
      Cache.fetch({:cache_test, "a"}, 60_000, fn -> [:a] end)
      Cache.fetch({:cache_test, "b"}, 60_000, fn -> [:b] end)

      :ok = Cache.invalidate({:cache_test, "a"})

      recomputed = fn -> :recomputed end
      assert Cache.fetch({:cache_test, "a"}, 60_000, recomputed) == :recomputed
      assert Cache.fetch({:cache_test, "b"}, 60_000, recomputed) == [:b]
    end

    test "routing: accessible-model invalidation honours the wildcard scope" do
      Routing.Cache.fetch_accessible_models("group-a", "member-1", fn -> [:m] end)
      Routing.Cache.fetch_accessible_models("group-a", "member-2", fn -> [:m] end)
      Routing.Cache.fetch_accessible_models("group-b", "member-1", fn -> [:m] end)

      :ok = Routing.Cache.invalidate_accessible_models("group-a", nil)

      miss = fn -> :miss end
      assert Routing.Cache.fetch_accessible_models("group-a", "member-1", miss) == :miss
      assert Routing.Cache.fetch_accessible_models("group-a", "member-2", miss) == :miss

      # A different group's entry for the same member is untouched.
      assert Routing.Cache.fetch_accessible_models("group-b", "member-1", miss) == [:m]
    end
  end

  describe "remote application (subscriber)" do
    test "an invalidation broadcast from another node drops the local api key entry" do
      hash = "hash-remote-#{System.unique_integer([:positive])}"
      ApiKeyCache.fetch(hash, fn -> %{member: %{id: "m-remote"}} end)
      assert [_] = :ets.lookup(ApiKeyCache.table(), hash)

      deliver_remote(:api_key_cache, {:hash, hash})

      assert [] = :ets.lookup(ApiKeyCache.table(), hash)
    end

    test "an invalidation broadcast from another node drops the local generic cache entry" do
      key = {:cache_test, "remote-#{System.unique_integer([:positive])}"}
      Cache.fetch(key, 60_000, fn -> [:cached] end)

      deliver_remote(:cache, {:invalidate, key})

      assert Cache.fetch(key, 60_000, fn -> :recomputed end) == :recomputed
    end

    test "an invalidation broadcast from another node drops the local routing entries" do
      Routing.Cache.fetch_accessible_models("g-remote", "m-remote", fn -> [:model] end)

      deliver_remote(:routing_cache, {:accessible_models, "g-remote", "m-remote"})

      assert Routing.Cache.fetch_accessible_models("g-remote", "m-remote", fn -> :miss end) ==
               :miss
    end

    test "the subscriber ignores an operation it originated itself (no loop)" do
      hash = "hash-self-#{System.unique_integer([:positive])}"
      ApiKeyCache.fetch(hash, fn -> %{member: %{id: "m-self"}} end)

      # Same message `dispatch/2` broadcasts: origin == node(), so the
      # subscriber must NOT touch the table (the dispatch already did).
      send(CacheInvalidation, {CacheInvalidation, :api_key_cache, {:hash, hash}, node()})
      _ = :sys.get_state(CacheInvalidation)

      assert [_] = :ets.lookup(ApiKeyCache.table(), hash)
    end

    test "malformed payloads are ignored instead of crashing the subscriber" do
      send(CacheInvalidation, :basura)
      send(CacheInvalidation, {CacheInvalidation, :unknown_target, :op, @remote})
      _ = :sys.get_state(CacheInvalidation)

      assert Process.alive?(Process.whereis(CacheInvalidation))
    end
  end

  describe "degradation" do
    test "dispatch still applies locally when the PubSub broadcast is disabled" do
      Application.put_env(:tokengate, :cache_invalidation_pubsub, false)
      on_exit(fn -> Application.delete_env(:tokengate, :cache_invalidation_pubsub) end)

      hash = "hash-no-pubsub-#{System.unique_integer([:positive])}"
      ApiKeyCache.fetch(hash, fn -> %{member: %{id: "m-nopubsub"}} end)

      assert :ok = ApiKeyCache.invalidate_hash(hash)
      assert [] = :ets.lookup(ApiKeyCache.table(), hash)
    end
  end

  describe "routing cache single-flight" do
    test "concurrent misses on the same key run the query once" do
      group = "g-sf-#{System.unique_integer([:positive])}"
      call_count = :counters.new(1, [:atomics])

      query = fn ->
        :counters.add(call_count, 1, 1)
        Process.sleep(50)
        [:model]
      end

      results =
        1..10
        |> Enum.map(fn _ ->
          Task.async(fn -> Routing.Cache.fetch_accessible_models(group, "member", query) end)
        end)
        |> Task.await_many(5_000)

      assert results == List.duplicate([:model], 10)
      assert :counters.get(call_count, 1) == 1

      assert [] ==
               :ets.lookup(
                 Routing.Cache.table(),
                 {:__computing__, {:accessible_models, group, "member"}}
               )
    end

    test "a crashing query releases the lock instead of wedging the key" do
      group = "g-sf-crash-#{System.unique_integer([:positive])}"

      assert_raise RuntimeError, "boom", fn ->
        Routing.Cache.fetch_accessible_models(group, "member", fn -> raise "boom" end)
      end

      assert Routing.Cache.fetch_accessible_models(group, "member", fn -> [:recovered] end) ==
               [:recovered]
    end
  end

  describe "routing invalidate_all" do
    test "staggers expiry instead of wiping every model at once" do
      table = Routing.Cache.table()
      :ets.delete_all_objects(table)

      for i <- 1..4 do
        Routing.Cache.fetch_accessible_models("g-stag", "m#{i}", fn -> [:model] end)
      end

      :ets.insert(table, {:disabled_credentials, MapSet.new(["cred-1"]), future()})

      before = :ets.tab2list(table)
      assert length(before) == 5

      :ok = Routing.Cache.invalidate_all()

      after_entries = :ets.tab2list(table)
      # No entry was dropped: a catalog write no longer leaves every model
      # recomputing on the next request...
      assert length(after_entries) == 4
      # ...but their deadlines were pulled inside the stagger window.
      now = System.monotonic_time(:millisecond)

      assert Enum.all?(after_entries, fn {_key, _value, deadline} -> deadline <= now + 1_000 end)

      # The disabled-credential set is correctness-critical: dropped at once.
      assert [] == :ets.lookup(table, :disabled_credentials)
    end
  end

  defp deliver_remote(target, op) do
    send(CacheInvalidation, {CacheInvalidation, target, op, @remote})
    _ = :sys.get_state(CacheInvalidation)
    :ok
  end

  defp future, do: System.monotonic_time(:millisecond) + 60_000
end
