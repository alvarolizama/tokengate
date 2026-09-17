defmodule Tokengate.Routing.StickyTrackerTest do
  use ExUnit.Case, async: false
  alias Tokengate.Routing.StickyTracker

  # The StickyTracker owns a named ETS table (:tokengate_sticky_routes) and
  # a named GenServer. async: false prevents collisions across tests that
  # also start the singleton tracker.

  setup do
    # Reuse the app-tree instance when present; clear the shared table so no
    # stale state persists between tests.
    pid = Process.whereis(StickyTracker) || start_supervised!(StickyTracker)
    _ = :sys.get_state(pid)

    if :ets.whereis(:tokengate_sticky_routes) != :undefined do
      :ets.delete_all_objects(:tokengate_sticky_routes)
    end

    {:ok, %{pid: pid}}
  end

  describe "put/3 and get/2" do
    test "stores and retrieves a sticky route" do
      StickyTracker.put("key-hash-1", "model-1", "ap-1")

      # put is async; sync with the GenServer before asserting.
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.get("key-hash-1", "model-1") == "ap-1"
    end

    test "overwrites an existing sticky route" do
      StickyTracker.put("key-hash-1", "model-1", "ap-1")
      _ = :sys.get_state(StickyTracker)

      StickyTracker.put("key-hash-1", "model-1", "ap-2")
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.get("key-hash-1", "model-1") == "ap-2"
    end

    test "returns nil for an unknown key" do
      assert StickyTracker.get("unknown-key", "unknown-model") == nil
    end
  end

  describe "put/4 with explicit TTL" do
    test "put/3 (nil TTL) stores the default TTL on the entry" do
      StickyTracker.put("key-default", "model-1", "ap-1")
      _ = :sys.get_state(StickyTracker)

      [{{"key-default", "model-1"}, {_id, _at, ttl_ms}}] =
        :ets.lookup(:tokengate_sticky_routes, {"key-default", "model-1"})

      assert ttl_ms == StickyTracker.default_ttl_ms()
    end

    test "put/4 stores the custom TTL on the entry" do
      StickyTracker.put("key-custom", "model-1", "ap-1", 5_000)
      _ = :sys.get_state(StickyTracker)

      [{{"key-custom", "model-1"}, {_id, _at, ttl_ms}}] =
        :ets.lookup(:tokengate_sticky_routes, {"key-custom", "model-1"})

      assert ttl_ms == 5_000
    end

    test "put/4 with nil TTL falls back to default" do
      StickyTracker.put("key-nil", "model-1", "ap-1", nil)
      _ = :sys.get_state(StickyTracker)

      [{{"key-nil", "model-1"}, {_id, _at, ttl_ms}}] =
        :ets.lookup(:tokengate_sticky_routes, {"key-nil", "model-1"})

      assert ttl_ms == StickyTracker.default_ttl_ms()
    end

    test "custom TTL expires the entry earlier than the default" do
      StickyTracker.put("key-expire", "model-1", "ap-1", 50)
      _ = :sys.get_state(StickyTracker)

      # Entry is alive right away
      assert StickyTracker.get("key-expire", "model-1") == "ap-1"

      # Age the entry past its TTL and read again — should be gone.
      StickyTracker.backdate_for_test({"key-expire", "model-1"}, 100)
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.get("key-expire", "model-1") == nil
    end
  end

  describe "clear/2" do
    test "removes a single sticky entry" do
      StickyTracker.put("key-hash-1", "model-1", "ap-1")
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.get("key-hash-1", "model-1") == "ap-1"

      assert StickyTracker.clear("key-hash-1", "model-1") == :ok
      assert StickyTracker.get("key-hash-1", "model-1") == nil
    end

    test "clearing a non-existent key is a no-op" do
      assert StickyTracker.clear("nope", "nope") == :ok
    end
  end

  describe "clear_all_for_provider/1" do
    test "drops all stickies pointing at the given model_provider_ids" do
      StickyTracker.put("key-a", "model-1", "ap-1")
      StickyTracker.put("key-b", "model-1", "ap-1")
      StickyTracker.put("key-c", "model-2", "ap-2")
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.clear_all_for_provider(["ap-1"]) == :ok

      assert StickyTracker.get("key-a", "model-1") == nil
      assert StickyTracker.get("key-b", "model-1") == nil
      assert StickyTracker.get("key-c", "model-2") == "ap-2"
    end

    test "clears multiple model_provider_ids at once" do
      StickyTracker.put("key-a", "model-1", "ap-1")
      StickyTracker.put("key-b", "model-2", "ap-2")
      StickyTracker.put("key-c", "model-3", "ap-3")
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.clear_all_for_provider(["ap-1", "ap-2"]) == :ok

      assert StickyTracker.get("key-a", "model-1") == nil
      assert StickyTracker.get("key-b", "model-2") == nil
      assert StickyTracker.get("key-c", "model-3") == "ap-3"
    end

    test "empty list clears nothing" do
      StickyTracker.put("key-a", "model-1", "ap-1")
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.clear_all_for_provider([]) == :ok
      assert StickyTracker.get("key-a", "model-1") == "ap-1"
    end
  end

  describe "clear_all_for_api_key_hash/1" do
    test "drops all stickies for the given api key hash across models" do
      StickyTracker.put("key-a", "model-1", "ap-1")
      StickyTracker.put("key-a", "model-2", "ap-2")
      StickyTracker.put("key-b", "model-1", "ap-3")
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.clear_all_for_api_key_hash("key-a") == :ok

      assert StickyTracker.get("key-a", "model-1") == nil
      assert StickyTracker.get("key-a", "model-2") == nil
      assert StickyTracker.get("key-b", "model-1") == "ap-3"
    end

    test "clearing unknown api key hash is a no-op" do
      assert StickyTracker.clear_all_for_api_key_hash("nope") == :ok
    end
  end

  describe "clear_all_for_api_key_hashes/1" do
    # Un sujeto (usuario / servicio) tiene N keys: limpiar su stickiness es
    # limpiar la de todas ellas en una sola pasada.
    test "drops stickies for every given hash and leaves the rest alone" do
      StickyTracker.put("key-a", "model-1", "ap-1")
      StickyTracker.put("key-b", "model-1", "ap-2")
      StickyTracker.put("key-b", "model-2", "ap-3")
      StickyTracker.put("key-other", "model-1", "ap-4")
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.clear_all_for_api_key_hashes(["key-a", "key-b"]) == :ok

      assert StickyTracker.get("key-a", "model-1") == nil
      assert StickyTracker.get("key-b", "model-1") == nil
      assert StickyTracker.get("key-b", "model-2") == nil
      # La key de OTRO sujeto sobrevive.
      assert StickyTracker.get("key-other", "model-1") == "ap-4"
    end

    test "an empty list is a no-op" do
      StickyTracker.put("key-a", "model-1", "ap-1")
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.clear_all_for_api_key_hashes([]) == :ok
      assert StickyTracker.get("key-a", "model-1") == "ap-1"
    end
  end

  describe "clear_all/0" do
    test "drops every sticky entry in the table" do
      StickyTracker.put("key-a", "model-1", "ap-1")
      StickyTracker.put("key-b", "model-2", "ap-2")
      StickyTracker.put("key-c", "model-3", "ap-3")
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.clear_all() == :ok

      assert StickyTracker.get("key-a", "model-1") == nil
      assert StickyTracker.get("key-b", "model-2") == nil
      assert StickyTracker.get("key-c", "model-3") == nil
    end

    test "clear_all on empty table is a no-op" do
      assert StickyTracker.clear_all() == :ok
    end
  end
end
