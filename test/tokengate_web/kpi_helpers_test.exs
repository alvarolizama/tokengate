defmodule TokengateWeb.KpiHelpersTest do
  use ExUnit.Case, async: true

  alias TokengateWeb.KpiHelpers

  describe "cache_hit_rate/2" do
    test "returns the percentage of input tokens served from cache" do
      # 40 read out of 160 prompt + 40 read = 20.0%
      assert KpiHelpers.cache_hit_rate(40, 160) == 20.0
    end

    test "100% when every input token came from cache" do
      assert KpiHelpers.cache_hit_rate(1_000, 0) == 100.0
    end

    test "0% when there are no cache reads" do
      assert KpiHelpers.cache_hit_rate(0, 500) == 0.0
    end

    test "rounds to one decimal" do
      # 1/3 = 33.333...% → 33.3
      assert KpiHelpers.cache_hit_rate(1, 2) == 33.3
    end

    test "returns nil when there is no input traffic at all" do
      assert KpiHelpers.cache_hit_rate(0, 0) == nil
    end

    test "returns nil for non-integer input" do
      assert KpiHelpers.cache_hit_rate(nil, 100) == nil
      assert KpiHelpers.cache_hit_rate(100, nil) == nil
    end
  end

  describe "format_hit_rate/1" do
    test "formats a float rate with the percent sign" do
      assert KpiHelpers.format_hit_rate(42.5) == "42.5%"
    end

    test "formats an integer rate with a trailing .0" do
      assert KpiHelpers.format_hit_rate(20) == "20.0%"
    end

    test "renders an em dash when the rate is nil" do
      assert KpiHelpers.format_hit_rate(nil) == "—"
    end
  end
end
