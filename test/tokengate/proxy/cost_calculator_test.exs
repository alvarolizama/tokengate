defmodule Tokengate.Proxy.CostCalculatorTest do
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.CostCalculator

  @alias_gpt4o %{
    market_input_price_per_1m: Decimal.new("5.00"),
    market_output_price_per_1m: Decimal.new("15.00")
  }

  @pricing %{
    input_price_per_1m: Decimal.new("2.50"),
    output_price_per_1m: Decimal.new("10.00"),
    cache_read_price_per_1m: Decimal.new("1.25"),
    cache_creation_price_per_1m: nil
  }

  @usage %{
    prompt_tokens: 1_000,
    completion_tokens: 500,
    cache_read_tokens: 0,
    cache_creation_tokens: 0
  }

  describe "market_cost/2" do
    test "input + output at market prices" do
      # 1000 * 5/1M + 500 * 15/1M = 0.005 + 0.0075
      assert Decimal.equal?(
               CostCalculator.market_cost(@alias_gpt4o, @usage),
               Decimal.new("0.0125")
             )
    end

    test "cache tokens count as input at market" do
      usage = %{
        prompt_tokens: 0,
        completion_tokens: 0,
        cache_read_tokens: 1_000_000,
        cache_creation_tokens: 0
      }

      assert Decimal.equal?(CostCalculator.market_cost(@alias_gpt4o, usage), Decimal.new("5.0"))
    end
  end

  describe "provider_priced_cost/2" do
    test "uses provider prices including cache read price" do
      usage = %{
        prompt_tokens: 1_000_000,
        completion_tokens: 0,
        cache_read_tokens: 1_000_000,
        cache_creation_tokens: 0
      }

      # 2.50 + 1.25
      assert Decimal.equal?(
               CostCalculator.provider_priced_cost(@pricing, usage),
               Decimal.new("3.75")
             )
    end

    test "cache creation falls back to input price when not set" do
      usage = %{
        prompt_tokens: 0,
        completion_tokens: 0,
        cache_read_tokens: 0,
        cache_creation_tokens: 1_000_000
      }

      assert Decimal.equal?(
               CostCalculator.provider_priced_cost(@pricing, usage),
               Decimal.new("2.5")
             )
    end

    test "nil pricing returns nil" do
      assert CostCalculator.provider_priced_cost(nil, @usage) == nil
    end
  end

  describe "savings/2" do
    test "estimated minus real provider cost" do
      assert Decimal.equal?(
               CostCalculator.savings(Decimal.new("0.0125"), Decimal.new("0.005")),
               Decimal.new("0.0075")
             )
    end
  end

  describe "breakdown/4" do
    test "pay_per_token with pricing: all four dimensions" do
      result =
        CostCalculator.breakdown(@alias_gpt4o, @pricing, @usage, billing_mode: "pay_per_token")

      # market: 1000*5/1M + 500*15/1M = 0.0125
      assert Decimal.equal?(result.estimated_cost_usd, Decimal.new("0.0125"))
      # provider: 1000*2.5/1M + 500*10/1M = 0.0075
      assert Decimal.equal?(result.cost_usd, Decimal.new("0.0075"))
      assert Decimal.equal?(result.provider_cost_usd, Decimal.new("0.0075"))
      assert Decimal.equal?(result.savings_usd, Decimal.new("0.005"))
    end

    test "pay_per_token with nil pricing: honest fallback, no phantom savings" do
      result = CostCalculator.breakdown(@alias_gpt4o, nil, @usage, billing_mode: "pay_per_token")

      assert Decimal.equal?(result.estimated_cost_usd, Decimal.new("0.0125"))
      assert Decimal.equal?(result.cost_usd, Decimal.new("0.0125"))
      # Unknown real cost → falls back to the estimate instead of $0,
      # so savings is 0 rather than an inflated 100%.
      assert Decimal.equal?(result.provider_cost_usd, Decimal.new("0.0125"))
      assert Decimal.equal?(result.savings_usd, Decimal.new("0"))
    end

    test "pay_per_token with cache tokens: no double-counting" do
      # prompt_tokens is regular (non-cached) input per UsageNormalizer
      # semantics; cache tokens are billed only at their cache price.
      usage = %{
        prompt_tokens: 800,
        completion_tokens: 500,
        cache_read_tokens: 200,
        cache_creation_tokens: 0
      }

      result = CostCalculator.breakdown(@alias_gpt4o, @pricing, usage)

      # provider: 800*2.5/1M + 500*10/1M + 200*1.25/1M = 0.002 + 0.005 + 0.00025
      assert Decimal.equal?(result.provider_cost_usd, Decimal.new("0.00725"))
    end

    test "included billing_mode: cost_usd = 0, provider_cost = 0" do
      result = CostCalculator.breakdown(@alias_gpt4o, @pricing, @usage, billing_mode: "included")

      assert Decimal.equal?(result.estimated_cost_usd, Decimal.new("0.0125"))
      assert Decimal.equal?(result.cost_usd, Decimal.new(0))
      assert Decimal.equal?(result.provider_cost_usd, Decimal.new(0))
      assert Decimal.equal?(result.savings_usd, Decimal.new("0.0125"))
    end

    test "pay_per_token with provider_reported_cost overrides pricing calculation" do
      result =
        CostCalculator.breakdown(@alias_gpt4o, @pricing, @usage,
          billing_mode: "pay_per_token",
          provider_reported_cost: Decimal.new("0.003")
        )

      # cost_usd still uses pricing row, but provider_cost_usd uses reported
      assert Decimal.equal?(result.cost_usd, Decimal.new("0.0075"))
      assert Decimal.equal?(result.provider_cost_usd, Decimal.new("0.003"))
      # savings = estimated - provider_cost = 0.0125 - 0.003
      assert Decimal.equal?(result.savings_usd, Decimal.new("0.0095"))
    end

    test "included billing_mode ignores provider_reported_cost" do
      result =
        CostCalculator.breakdown(@alias_gpt4o, @pricing, @usage,
          billing_mode: "included",
          provider_reported_cost: Decimal.new("0.003")
        )

      assert Decimal.equal?(result.cost_usd, Decimal.new(0))
      assert Decimal.equal?(result.provider_cost_usd, Decimal.new(0))
    end

    test "default opts: behaves as pay_per_token" do
      result = CostCalculator.breakdown(@alias_gpt4o, @pricing, @usage)

      assert Decimal.equal?(result.cost_usd, Decimal.new("0.0075"))
      assert Decimal.equal?(result.provider_cost_usd, Decimal.new("0.0075"))
    end
  end
end
