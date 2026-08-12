defmodule Tokengate.Proxy.CostCalculatorTest do
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.CostCalculator

  describe "provider_cost/3 — included billing mode" do
    test "included: always $0 regardless of reported cost" do
      assert Decimal.equal?(CostCalculator.provider_cost("included", nil, []), Decimal.new(0))
      assert Decimal.equal?(CostCalculator.provider_cost("included", Decimal.new("0.5"), []), Decimal.new(0))
    end

    test "included: ignores manual pricing even if set" do
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("2.50"),
          output_cost_per_million: Decimal.new("10.00"),
          cache_cost_per_million: Decimal.new("0.50")
        },
        usage: %{prompt_tokens: 1000, completion_tokens: 500}
      ]

      assert Decimal.equal?(CostCalculator.provider_cost("included", nil, opts), Decimal.new(0))
    end
  end

  describe "provider_cost/3 — pay_per_token with reported cost" do
    test "reported Decimal takes precedence over manual pricing" do
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("2.50"),
          output_cost_per_million: Decimal.new("10.00"),
          cache_cost_per_million: Decimal.new("0.50")
        },
        usage: %{prompt_tokens: 1000, completion_tokens: 500}
      ]

      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", Decimal.new("0.003"), opts),
               Decimal.new("0.003")
             )
    end

    test "rounds to 6 decimal places" do
      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", Decimal.new("0.003123456"), []),
               Decimal.new("0.003123")
             )
    end

    test "accepts numeric input" do
      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", 0.0125, []),
               Decimal.new("0.0125")
             )
    end

    test "accepts binary input" do
      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", "0.0007", []),
               Decimal.new("0.0007")
             )
    end

    test "unparseable binary: $0 fallback" do
      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", "not a number", []),
               Decimal.new(0)
             )
    end
  end

  describe "provider_cost/3 — 3-term manual fallback (input + cache + output)" do
    test "3-term: non_cached × input + cached × cache + completion × output" do
      # prompt=113, cached=64, completion=10
      # non_cached=49, input=$0.14, cache=$0.026, output=$0.44 per 1M
      # = (49×0.14 + 64×0.026 + 10×0.44) / 1M = 12.924 / 1M = 0.000012924
      # Rounded to 6 decimal places (numeric(12,6)): 0.000013
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("0.14"),
          output_cost_per_million: Decimal.new("0.44"),
          cache_cost_per_million: Decimal.new("0.026")
        },
        usage: %{prompt_tokens: 113, completion_tokens: 10, cache_read_tokens: 64}
      ]

      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", nil, opts),
               Decimal.new("0.000013")
             )
    end

    test "matches nube provider cost for cache hit (validated)" do
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("0.14"),
          output_cost_per_million: Decimal.new("0.44"),
          cache_cost_per_million: Decimal.new("0.026")
        },
        usage: %{prompt_tokens: 113, completion_tokens: 10, cache_read_tokens: 64}
      ]

      result = CostCalculator.provider_cost("pay_per_token", nil, opts)
      assert Decimal.equal?(result, Decimal.new("0.000013"))
    end

    test "matches nube provider cost for no cache (validated)" do
      # 113 prompt, 0 cached, 10 completion
      # = (113×0.14 + 0×0.026 + 10×0.44) / 1M = 20.22 / 1M = 0.000020220
      # Rounded to 6 decimal places: 0.000020
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("0.14"),
          output_cost_per_million: Decimal.new("0.44"),
          cache_cost_per_million: Decimal.new("0.026")
        },
        usage: %{prompt_tokens: 113, completion_tokens: 10, cache_read_tokens: 0}
      ]

      result = CostCalculator.provider_cost("pay_per_token", nil, opts)
      assert Decimal.equal?(result, Decimal.new("0.000020"))
    end
  end

  describe "provider_cost/3 — 2-term fallback (no cache cost set)" do
    test "2-term: all prompt × input + completion × output" do
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("2.50"),
          output_cost_per_million: Decimal.new("10.00"),
          cache_cost_per_million: nil
        },
        usage: %{prompt_tokens: 1000, completion_tokens: 500, cache_read_tokens: 200}
      ]

      # 1000×2.50 + 500×10.00 = 2500 + 5000 = 7500 / 1M = 0.0075
      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", nil, opts),
               Decimal.new("0.0075")
             )
    end

    test "2-term with zero tokens: $0" do
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("2.50"),
          output_cost_per_million: Decimal.new("10.00"),
          cache_cost_per_million: nil
        },
        usage: %{prompt_tokens: 0, completion_tokens: 0}
      ]

      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", nil, opts),
               Decimal.new(0)
             )
    end
  end

  describe "provider_cost/3 — edge cases" do
    test "only input set (output nil): $0 (both required)" do
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("2.50"),
          output_cost_per_million: nil,
          cache_cost_per_million: Decimal.new("0.50")
        },
        usage: %{prompt_tokens: 1000, completion_tokens: 500}
      ]

      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", nil, opts),
               Decimal.new(0)
             )
    end

    test "no manual_pricing in opts: $0" do
      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", nil, []),
               Decimal.new(0)
             )
    end

    test "empty manual_pricing map: $0" do
      opts = [manual_pricing: %{}, usage: %{prompt_tokens: 1000, completion_tokens: 500}]

      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", nil, opts),
               Decimal.new(0)
             )
    end

    test "unknown billing mode: $0 fallback" do
      assert Decimal.equal?(
               CostCalculator.provider_cost("unknown_mode", nil, []),
               Decimal.new(0)
             )

      assert Decimal.equal?(
               CostCalculator.provider_cost("unknown_mode", Decimal.new("0.5"), []),
               Decimal.new(0)
             )
    end
  end
end