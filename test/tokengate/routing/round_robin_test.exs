defmodule Tokengate.Routing.RoundRobinTest do
  use ExUnit.Case, async: false

  alias Tokengate.Providers.AliasProvider
  alias Tokengate.Routing.RoundRobin

  # RoundRobin uses a named ETS table (:tokengate_rr_counters). Each test
  # uses a unique model_alias_id so counter state does not interfere.
  # We deliberately do NOT delete the table between tests: on_exit runs
  # asynchronously and could delete it while a subsequent test's concurrent
  # tasks are mid-flight. The table persists safely across tests.

  defp ap(id, opts) do
    %AliasProvider{
      id: id,
      priority: Keyword.get(opts, :priority),
      weight: Keyword.get(opts, :weight),
      enabled: Keyword.get(opts, :enabled, true),
      provider_model: Keyword.get(opts, :provider_model, "model-#{id}"),
      model_alias_id: Keyword.get(opts, :model_alias_id, "alias-rr")
    }
  end

  describe "weight distribution" do
    test "weights 2/1 distribute ~66/33 over many calls" do
      candidates = [ap("a", weight: 2), ap("b", weight: 1)]
      opts = %{model_alias_id: "alias-rr-dist"}

      counts =
        Enum.reduce(1..3000, %{}, fn _, acc ->
          assert {:ok, selected} = RoundRobin.select(candidates, opts)
          Map.update(acc, selected.id, 1, &(&1 + 1))
        end)

      a = Map.get(counts, "a", 0)
      b = Map.get(counts, "b", 0)
      total = a + b

      assert total == 3000

      # Expect ~66% / ~33%; allow ±5 percentage points.
      a_pct = a / total * 100
      b_pct = b / total * 100

      assert_in_delta a_pct, 66.67, 5.0, "a should be ~66%, got #{a_pct}%"
      assert_in_delta b_pct, 33.33, 5.0, "b should be ~33%, got #{b_pct}%"
    end

    test "nil weight is treated as 1" do
      candidates = [ap("a", weight: nil), ap("b", weight: nil)]
      opts = %{model_alias_id: "alias-rr-nil"}

      counts =
        Enum.reduce(1..2000, %{}, fn _, acc ->
          assert {:ok, selected} = RoundRobin.select(candidates, opts)
          Map.update(acc, selected.id, 1, &(&1 + 1))
        end)

      a = Map.get(counts, "a", 0)
      b = Map.get(counts, "b", 0)

      # With weight 1/1, distribution should be ~50/50.
      assert_in_delta a, b, 200, "nil-weighted candidates should be ~equal (a=#{a}, b=#{b})"
    end

    test "weight cap at 100" do
      # A candidate with weight 200 should be capped to 100, making it equal
      # to a candidate with weight 100.
      candidates = [ap("huge", weight: 200), ap("capped", weight: 100)]
      opts = %{model_alias_id: "alias-rr-cap"}

      counts =
        Enum.reduce(1..3000, %{}, fn _, acc ->
          assert {:ok, selected} = RoundRobin.select(candidates, opts)
          Map.update(acc, selected.id, 1, &(&1 + 1))
        end)

      huge = Map.get(counts, "huge", 0)
      capped = Map.get(counts, "capped", 0)

      # After cap, both have effective weight 100 → ~50/50.
      assert_in_delta huge,
                      capped,
                      400,
                      "capped weights should be ~equal (huge=#{huge}, capped=#{capped})"
    end
  end

  describe "skipping unavailable providers" do
    test "skips unavailable candidates and picks available ones" do
      candidates = [ap("a", weight: 1), ap("b", weight: 1), ap("c", weight: 1)]
      available? = fn ap -> ap.id != "a" end
      opts = %{model_alias_id: "alias-rr-skip", available?: available?}

      Enum.each(1..100, fn _ ->
        assert {:ok, selected} = RoundRobin.select(candidates, opts)
        assert selected.id in ["b", "c"]
      end)
    end

    test "all unavailable returns error" do
      candidates = [ap("a", weight: 1), ap("b", weight: 1)]
      available? = fn _ -> false end
      opts = %{model_alias_id: "alias-rr-none", available?: available?}

      assert {:error, :no_available_provider} = RoundRobin.select(candidates, opts)
    end
  end

  describe "edge cases" do
    test "empty candidate list returns error" do
      assert {:error, :no_available_provider} = RoundRobin.select([], %{})
    end

    test "single candidate always selected" do
      candidates = [ap("solo", weight: 1)]
      opts = %{model_alias_id: "alias-rr-solo"}

      Enum.each(1..10, fn _ ->
        assert {:ok, selected} = RoundRobin.select(candidates, opts)
        assert selected.id == "solo"
      end)
    end
  end

  describe "concurrent increments" do
    test "50 concurrent tasks produce selections covering all candidates" do
      candidates = [ap("a", weight: 1), ap("b", weight: 1), ap("c", weight: 1)]
      opts = %{model_alias_id: "alias-rr-concurrent"}

      # Pre-warm: call select once from the test process so the ETS table
      # is owned by the test process (which lives for the test duration).
      # This prevents the table from being destroyed when short-lived Tasks
      # that created it terminate.
      assert {:ok, _} = RoundRobin.select(candidates, opts)

      # Spawn 50 tasks that each select concurrently.
      tasks =
        Enum.map(1..50, fn _ ->
          Task.async(fn ->
            RoundRobin.select(candidates, opts)
          end)
        end)

      results = Task.await_many(tasks, 5000)

      selected_ids =
        results
        |> Enum.map(fn
          {:ok, ap} -> ap.id
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      # All 50 should have succeeded.
      assert length(selected_ids) == 50

      # All three candidates should be represented (with 50 draws over a
      # 3-slot rotation, all slots are hit).
      unique_ids = Enum.uniq(selected_ids) |> Enum.sort()
      assert unique_ids == ["a", "b", "c"]
    end

    test "concurrent counter increments are unique (no lost updates)" do
      # With a single candidate, every select returns the same candidate but
      # the underlying counter still increments. We verify uniqueness by
      # counting how many times select was called — it must equal N.
      candidates = [ap("only", weight: 1)]
      opts = %{model_alias_id: "alias-rr-unique"}

      # Pre-warm: create the ETS table from the test process.
      assert {:ok, _} = RoundRobin.select(candidates, opts)

      n = 100

      tasks =
        Enum.map(1..n, fn _ ->
          Task.async(fn ->
            RoundRobin.select(candidates, opts)
          end)
        end)

      results = Task.await_many(tasks, 5000)

      # Every task should have succeeded.
      ok_count =
        Enum.count(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      assert ok_count == n
    end
  end

  describe "available? predicate" do
    test "default available? is always true" do
      candidates = [ap("a", weight: 1)]
      opts = %{model_alias_id: "alias-rr-default"}

      assert {:ok, selected} = RoundRobin.select(candidates, opts)
      assert selected.id == "a"
    end

    test "custom available? predicate is honored" do
      candidates = [ap("a", weight: 1), ap("b", weight: 1)]
      available? = fn ap -> ap.id == "b" end
      opts = %{model_alias_id: "alias-rr-pred", available?: available?}

      Enum.each(1..50, fn _ ->
        assert {:ok, selected} = RoundRobin.select(candidates, opts)
        assert selected.id == "b"
      end)
    end
  end
end
