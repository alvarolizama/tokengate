defmodule Tokengate.Proxy.CostCalculatorTest do
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.CostCalculator

  describe "provider_cost/3 — included billing mode" do
    test "included: always $0 regardless of reported cost" do
      assert Decimal.equal?(
               CostCalculator.provider_cost("included", nil, []),
               Decimal.new(0)
             )

      assert Decimal.equal?(
               CostCalculator.provider_cost("included", Decimal.new("0.5"), []),
               Decimal.new(0)
             )
    end

    test "included: ignores manual pricing even if set" do
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("2.50"),
          output_cost_per_million: Decimal.new("10.00")
        },
        usage: %{prompt_tokens: 1000, completion_tokens: 500}
      ]

      assert Decimal.equal?(
               CostCalculator.provider_cost("included", nil, opts),
               Decimal.new(0)
             )
    end
  end

  describe "provider_cost/3 — pay_per_token with reported cost" do
    test "reported Decimal takes precedence over manual pricing" do
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("2.50"),
          output_cost_per_million: Decimal.new("10.00")
        },
        usage: %{prompt_tokens: 1000, completion_tokens: 500}
      ]

      # The reported cost ($0.003) should win over the manual calculation
      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", Decimal.new("0.003"), opts),
               Decimal.new("0.003")
             )
    end

    test "reported Decimal: returns the reported value rounded to 6 places" do
      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", Decimal.new("0.003"), []),
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

  describe "provider_cost/3 — pay_per_token with nil reported, manual pricing fallback" do
    test "computes cost from manual pricing when reported is nil" do
      # 1000 prompt tokens @ $2.50/1M = $0.0025
      # 500 completion tokens @ $10.00/1M = $0.005
      # Total = $0.0075
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("2.50"),
          output_cost_per_million: Decimal.new("10.00")
        },
        usage: %{prompt_tokens: 1000, completion_tokens: 500}
      ]

      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", nil, opts),
               Decimal.new("0.0075")
             )
    end

    test "manual pricing with zero tokens: $0" do
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("2.50"),
          output_cost_per_million: Decimal.new("10.00")
        },
        usage: %{prompt_tokens: 0, completion_tokens: 0}
      ]

      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", nil, opts),
               Decimal.new(0)
             )
    end

    test "manual pricing with missing usage map: $0" do
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("2.50"),
          output_cost_per_million: Decimal.new("10.00")
        }
      ]

      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", nil, opts),
               Decimal.new(0)
             )
    end

    test "only input_cost set (output nil): $0 (both required)" do
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("2.50"),
          output_cost_per_million: nil
        },
        usage: %{prompt_tokens: 1000, completion_tokens: 500}
      ]

      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", nil, opts),
               Decimal.new(0)
             )
    end

    test "only output_cost set (input nil): $0 (both required)" do
      opts = [
        manual_pricing: %{
          input_cost_per_million: nil,
          output_cost_per_million: Decimal.new("10.00")
        },
        usage: %{prompt_tokens: 1000, completion_tokens: 500}
      ]

      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", nil, opts),
               Decimal.new(0)
             )
    end

    test "no manual_pricing in opts: $0 (original behaviour)" do
      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", nil, []),
               Decimal.new(0)
             )
    end

    test "empty manual_pricing map: $0" do
      opts = [
        manual_pricing: %{},
        usage: %{prompt_tokens: 1000, completion_tokens: 500}
      ]

      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", nil, opts),
               Decimal.new(0)
             )
    end

    test "large token counts compute correctly" do
      # 1M prompt tokens @ $1/1M = $1
      # 1M completion tokens @ $3/1M = $3
      # Total = $4
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("1"),
          output_cost_per_million: Decimal.new("3")
        },
        usage: %{prompt_tokens: 1_000_000, completion_tokens: 1_000_000}
      ]

      assert Decimal.equal?(
               CostCalculator.provider_cost("pay_per_token", nil, opts),
               Decimal.new("4")
             )
    end

    test "fractional per-million rates compute correctly" do
      # 14 prompt tokens @ $0.15/1M = $0.0000021 → rounds to $0.000002
      # 5 completion tokens @ $0.60/1M = $0.000003 → total $0.000005
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("0.15"),
          output_cost_per_million: Decimal.new("0.60")
        },
        usage: %{prompt_tokens: 14, completion_tokens: 5}
      ]

      result = CostCalculator.provider_cost("pay_per_token", nil, opts)
      assert Decimal.equal?(result, Decimal.new("0.000005"))
    end
  end

  describe "provider_cost/3 — unknown billing mode" do
    test "unknown mode: $0 fallback" do
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
