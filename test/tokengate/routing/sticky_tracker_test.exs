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
      StickyTracker.put("key-hash-1", "alias-1", "ap-1")

      # put is async; sync with the GenServer before asserting.
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.get("key-hash-1", "alias-1") == "ap-1"
    end

    test "overwrites an existing sticky route" do
      StickyTracker.put("key-hash-1", "alias-1", "ap-1")
      _ = :sys.get_state(StickyTracker)

      StickyTracker.put("key-hash-1", "alias-1", "ap-2")
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.get("key-hash-1", "alias-1") == "ap-2"
    end

    test "returns nil for an unknown key" do
      assert StickyTracker.get("unknown-key", "unknown-alias") == nil
    end
  end

  describe "clear/2" do
    test "removes a single sticky entry" do
      StickyTracker.put("key-hash-1", "alias-1", "ap-1")
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.get("key-hash-1", "alias-1") == "ap-1"

      assert StickyTracker.clear("key-hash-1", "alias-1") == :ok
      assert StickyTracker.get("key-hash-1", "alias-1") == nil
    end

    test "clearing a non-existent key is a no-op" do
      assert StickyTracker.clear("nope", "nope") == :ok
    end
  end

  describe "clear_all_for_provider/1" do
    test "drops all stickies pointing at the given alias_provider_ids" do
      StickyTracker.put("key-a", "alias-1", "ap-1")
      StickyTracker.put("key-b", "alias-1", "ap-1")
      StickyTracker.put("key-c", "alias-2", "ap-2")
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.clear_all_for_provider(["ap-1"]) == :ok

      assert StickyTracker.get("key-a", "alias-1") == nil
      assert StickyTracker.get("key-b", "alias-1") == nil
      assert StickyTracker.get("key-c", "alias-2") == "ap-2"
    end

    test "clears multiple alias_provider_ids at once" do
      StickyTracker.put("key-a", "alias-1", "ap-1")
      StickyTracker.put("key-b", "alias-2", "ap-2")
      StickyTracker.put("key-c", "alias-3", "ap-3")
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.clear_all_for_provider(["ap-1", "ap-2"]) == :ok

      assert StickyTracker.get("key-a", "alias-1") == nil
      assert StickyTracker.get("key-b", "alias-2") == nil
      assert StickyTracker.get("key-c", "alias-3") == "ap-3"
    end

    test "empty list clears nothing" do
      StickyTracker.put("key-a", "alias-1", "ap-1")
      _ = :sys.get_state(StickyTracker)

      assert StickyTracker.clear_all_for_provider([]) == :ok
      assert StickyTracker.get("key-a", "alias-1") == "ap-1"
    end
  end
end
