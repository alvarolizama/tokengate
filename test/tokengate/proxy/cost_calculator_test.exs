defmodule Tokengate.Proxy.CostCalculatorTest do
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.CostCalculator

  describe "provider_cost/2" do
    test "included: always $0" do
      assert Decimal.equal?(
               CostCalculator.provider_cost("included", nil),
               Decimal.new(0)
             )

      assert Decimal.equal?(
               CostCalculator.provider_cost("included", Decimal.new("0.5")),
               Decimal.new(0)
             )
    end

    test "pay_per_token with reported Decimal: returns the reported value rounded to 6 places" do
      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", Decimal.new("0.003")),
               Decimal.new("0.003")
             )
    end

    test "pay_per_token rounds to 6 decimal places" do
      # 0.003123456 should round to 0.003123
      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", Decimal.new("0.003123456")),
               Decimal.new("0.003123")
             )
    end

    test "pay_per_token accepts numeric input" do
      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", 0.0125),
               Decimal.new("0.0125")
             )
    end

    test "pay_per_token accepts binary input" do
      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", "0.0007"),
               Decimal.new("0.0007")
             )
    end

    test "pay_per_token with nil: honest $0 fallback (no phantom estimate)" do
      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", nil),
               Decimal.new(0)
             )
    end

    test "pay_per_token with unparseable binary: $0 fallback" do
      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", "not a number"),
               Decimal.new(0)
             )
    end

    test "unknown billing mode: $0 fallback" do
      assert Decimal.equal?(
               CostCalculator.provider_cost("unknown_mode", nil),
               Decimal.new(0)
             )

      assert Decimal.equal?(
               CostCalculator.provider_cost("unknown_mode", Decimal.new("0.5")),
               Decimal.new(0)
             )
    end
  end
end
