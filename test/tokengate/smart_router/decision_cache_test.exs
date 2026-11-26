defmodule Tokengate.SmartRouter.DecisionCacheTest do
  use ExUnit.Case, async: true

  alias Tokengate.SmartRouter.DecisionCache

  test "fingerprints are stable and differ across inputs" do
    assert DecisionCache.fingerprint({1, [:a]}) == DecisionCache.fingerprint({1, [:a]})
    refute DecisionCache.fingerprint({1, [:a]}) == DecisionCache.fingerprint({1, [:b]})
  end

  test "a cached answer round-trips and expires" do
    key = DecisionCache.fingerprint({:test, System.unique_integer([:positive])})
    answer = %{use_case_key: "fast", effort: "low", confidence: 0.8}

    assert :ok = DecisionCache.put(key, answer, 60_000)
    assert DecisionCache.get(key) == answer

    DecisionCache.backdate_for_test(key, 61_000)
    assert DecisionCache.get(key) == nil
  end

  test "flush drops every entry" do
    key = DecisionCache.fingerprint({:flush, System.unique_integer([:positive])})
    DecisionCache.put(key, %{use_case_key: "fast"})
    DecisionCache.flush()
    assert DecisionCache.get(key) == nil
  end

  test "clear_all drops every entry too (used by SmartRouter.invalidate/0)" do
    key = DecisionCache.fingerprint({:clear_all, System.unique_integer([:positive])})
    DecisionCache.put(key, %{use_case_key: "writing"})
    assert DecisionCache.get(key) != nil

    assert :ok = DecisionCache.clear_all()
    assert DecisionCache.get(key) == nil
  end
end
