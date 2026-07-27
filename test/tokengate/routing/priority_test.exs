defmodule Tokengate.Routing.PriorityTest do
  use ExUnit.Case, async: false

  alias Tokengate.Providers.ModelProvider
  alias Tokengate.Routing.Priority
  alias Tokengate.Routing.StickyTracker

  # Priority uses the singleton StickyTracker (named GenServer + named ETS
  # table). async: false avoids collisions.

  setup do
    pid = Process.whereis(StickyTracker) || start_supervised!(StickyTracker)
    _ = :sys.get_state(pid)
    # Shared app-tree instance: clear sticky state between tests
    if :ets.whereis(:tokengate_sticky_routes) != :undefined do
      :ets.delete_all_objects(:tokengate_sticky_routes)
    end

    {:ok, %{}}
  end

  defp ap(id, opts \\ []) do
    %ModelProvider{
      id: id,
      priority: Keyword.get(opts, :priority),
      enabled: Keyword.get(opts, :enabled, true),
      provider_model: Keyword.get(opts, :provider_model, "model-#{id}"),
      model_alias_id: Keyword.get(opts, :model_alias_id, "alias-1")
    }
  end

  describe "priority ordering" do
    test "sorts by priority ASC with nils last" do
      candidates = [
        ap("p-nil-1", priority: nil),
        ap("p-2", priority: 2),
        ap("p-1", priority: 1),
        ap("p-nil-2", priority: nil)
      ]

      assert {:ok, selected} = Priority.select(candidates, %{})
      assert selected.id == "p-1"
    end

    test "stable within the same priority tier" do
      # Two priority-1 candidates; the first in the input list wins ties.
      first = ap("first", priority: 1)
      second = ap("second", priority: 1)
      candidates = [first, second]

      assert {:ok, selected} = Priority.select(candidates, %{})
      assert selected.id == "first"
    end

    test "all-nil priorities preserve input order" do
      candidates = [ap("a"), ap("b"), ap("c")]

      assert {:ok, selected} = Priority.select(candidates, %{})
      assert selected.id == "a"
    end
  end

  describe "without api_key_hash" do
    test "pure priority order, no stickiness applied" do
      candidates = [
        ap("low", priority: 5),
        ap("high", priority: 1)
      ]

      assert {:ok, selected} = Priority.select(candidates, %{})
      assert selected.id == "high"

      # Nothing should be stored in the sticky tracker.
      assert StickyTracker.get("any-key", "alias-1") == nil
    end
  end

  describe "with api_key_hash (sticky behavior)" do
    test "sticky hit returns the stuck provider" do
      candidates = [ap("high", priority: 1), ap("low", priority: 5)]

      opts = %{api_key_hash: "key-1", model_alias_id: "alias-1"}

      # First selection sticks to the highest-priority provider.
      assert {:ok, first} = Priority.select(candidates, opts)
      assert first.id == "high"

      _ = :sys.get_state(StickyTracker)
      assert StickyTracker.get("key-1", "alias-1") == "high"

      # Even if candidate order changes, the sticky entry wins.
      reordered = [ap("low", priority: 5), ap("high", priority: 1)]

      assert {:ok, second} = Priority.select(reordered, opts)
      assert second.id == "high"
    end

    test "sticky miss when stuck provider unavailable falls to next and re-sticks" do
      candidates = [ap("high", priority: 1), ap("low", priority: 5)]
      opts = %{api_key_hash: "key-2", model_alias_id: "alias-1"}

      # Initial stick to "high".
      assert {:ok, first} = Priority.select(candidates, opts)
      assert first.id == "high"
      _ = :sys.get_state(StickyTracker)

      # Now make "high" unavailable — should fall back to "low" and re-stick.
      available? = fn ap -> ap.id != "high" end

      assert {:ok, second} = Priority.select(candidates, Map.put(opts, :available?, available?))
      assert second.id == "low"

      _ = :sys.get_state(StickyTracker)
      assert StickyTracker.get("key-2", "alias-1") == "low"
    end

    test "sticks on first selection when no prior sticky entry" do
      candidates = [ap("a", priority: 1), ap("b", priority: 2)]
      opts = %{api_key_hash: "key-3", model_alias_id: "alias-1"}

      assert {:ok, selected} = Priority.select(candidates, opts)
      assert selected.id == "a"

      _ = :sys.get_state(StickyTracker)
      assert StickyTracker.get("key-3", "alias-1") == "a"
    end

    test "different api keys get independent stickies" do
      candidates = [ap("high", priority: 1), ap("low", priority: 5)]

      opts_a = %{api_key_hash: "key-a", model_alias_id: "alias-1"}
      opts_b = %{api_key_hash: "key-b", model_alias_id: "alias-1"}

      assert {:ok, a} = Priority.select(candidates, opts_a)
      assert {:ok, b} = Priority.select(candidates, opts_b)
      assert a.id == "high"
      assert b.id == "high"

      _ = :sys.get_state(StickyTracker)
      assert StickyTracker.get("key-a", "alias-1") == "high"
      assert StickyTracker.get("key-b", "alias-1") == "high"
    end
  end

  describe "available? predicate" do
    test "skips unavailable candidates" do
      candidates = [ap("a", priority: 1), ap("b", priority: 2), ap("c", priority: 3)]
      available? = fn ap -> ap.id != "a" end

      assert {:ok, selected} = Priority.select(candidates, %{available?: available?})
      assert selected.id == "b"
    end

    test "all unavailable returns error" do
      candidates = [ap("a", priority: 1), ap("b", priority: 2)]
      available? = fn _ -> false end

      assert {:error, :no_available_provider} =
               Priority.select(candidates, %{available?: available?})
    end
  end

  describe "error cases" do
    test "empty candidate list returns error" do
      assert {:error, :no_available_provider} = Priority.select([], %{})
    end

    test "all unavailable returns error" do
      candidates = [ap("a", priority: 1)]
      available? = fn _ -> false end

      assert {:error, :no_available_provider} =
               Priority.select(candidates, %{available?: available?})
    end
  end

  describe "tracker not running" do
    test "continues without stickiness when StickyTracker is down" do
      # Stop the supervised tracker so named table/GenServer don't exist.
      stop_supervised(StickyTracker)

      candidates = [ap("high", priority: 1), ap("low", priority: 5)]
      opts = %{api_key_hash: "key-down", model_alias_id: "alias-1"}

      # Should still work — just without stickiness.
      assert {:ok, selected} = Priority.select(candidates, opts)
      assert selected.id == "high"
    end
  end
end
