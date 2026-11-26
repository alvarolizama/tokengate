defmodule Tokengate.SmartRouter.CostRankerTest do
  use ExUnit.Case, async: true

  alias Tokengate.SmartRouter.CostRanker
  alias Tokengate.SmartRouterFixtures, as: F

  defp analysis(prompt \\ 1_000, output \\ 500) do
    %{prompt_tokens: prompt, estimated_output_tokens: output}
  end

  test "mirrors the token formula: tokens × rate / divisor" do
    lane =
      F.lane("a", %{
        input_cost_per_million: Decimal.new("2"),
        output_cost_per_million: Decimal.new("4")
      })

    cost = CostRanker.estimate(analysis(), lane)

    assert Decimal.equal?(cost, Decimal.new("0.004"))
  end

  test "a per_1k_tokens lane divides by 1_000, not by 1M" do
    lane =
      F.lane("a", %{
        pricing_unit: "per_1k_tokens",
        input_cost_per_million: Decimal.new("2"),
        output_cost_per_million: Decimal.new("0")
      })

    cost = CostRanker.estimate(analysis(1_000, 0), lane)

    assert Decimal.equal?(cost, Decimal.new("2.0"))
  end

  test "falls back to the model's market prices when the lane has none" do
    lane = F.lane("a", %{input_cost_per_million: nil, output_cost_per_million: nil})

    model = %{
      market_input_price_per_1m: Decimal.new("3"),
      market_output_price_per_1m: Decimal.new("6")
    }

    cost = CostRanker.estimate(analysis(), lane, model)

    assert Decimal.equal?(cost, Decimal.new("0.006"))
  end

  test "no price anywhere is unpriced, not zero, and sorts last" do
    lane = F.lane("a", %{input_cost_per_million: nil, output_cost_per_million: nil})

    assert CostRanker.estimate(analysis(), lane) == nil

    priced =
      F.candidate("uc", "cheap", "low", %{
        lane: %{
          input_cost_per_million: Decimal.new("2"),
          output_cost_per_million: Decimal.new("2")
        }
      })

    unpriced =
      F.candidate("uc", "unknown", "low", %{
        lane: %{input_cost_per_million: nil, output_cost_per_million: nil}
      })

    ranked = CostRanker.rank([unpriced, priced], analysis())

    assert [%{model_name: "cheap"}, %{model_name: "unknown"}] = ranked
    assert hd(ranked).cost != nil
    assert List.last(ranked).cost == nil
  end

  test "ranks the cheapest priced lane of a destination" do
    candidate =
      F.candidate("uc", "a", "low", %{
        lanes: [
          F.lane("a", %{
            credential_id: "cred-1",
            input_cost_per_million: Decimal.new("9"),
            output_cost_per_million: Decimal.new("9")
          }),
          F.lane("a", %{
            credential_id: "cred-2",
            input_cost_per_million: Decimal.new("1"),
            output_cost_per_million: Decimal.new("1")
          })
        ]
      })

    [ranked] = CostRanker.rank([candidate], analysis())

    assert ranked.lane.credential_id == "cred-2"
    assert Decimal.equal?(ranked.cost, Decimal.new("0.0015"))
  end

  test "cost mode orders by price; potency mode orders higher tiers first" do
    cheap_low = F.candidate("uc", "cheap", "low")

    pricey_high =
      F.candidate("uc", "pricey", "high", %{
        lane: %{
          input_cost_per_million: Decimal.new("10"),
          output_cost_per_million: Decimal.new("10")
        }
      })

    assert [%{model_name: "cheap"} | _] =
             CostRanker.rank([pricey_high, cheap_low], analysis(), mode: :cost)

    assert hd(CostRanker.rank([cheap_low, pricey_high], analysis(), mode: :potency)).model_name ==
             "pricey"
  end

  test "tier helpers" do
    assert CostRanker.tier_rank("high") > CostRanker.tier_rank("medium")
    assert CostRanker.tiers_above("low") == ~w(medium high)
    assert CostRanker.tiers_below("high") == ~w(medium low)
  end

  test "a healthy destination sorts before a cheaper degraded one" do
    degraded =
      F.candidate("uc", "cheap", "low", %{
        lanes: [
          F.lane("cheap", %{
            credential_id: "cred-dead",
            input_cost_per_million: Decimal.new("1"),
            output_cost_per_million: Decimal.new("1")
          })
        ]
      })

    healthy =
      F.candidate("uc", "pricey", "low", %{
        lanes: [
          F.lane("pricey", %{
            credential_id: "cred-live",
            input_cost_per_million: Decimal.new("9"),
            output_cost_per_million: Decimal.new("9")
          })
        ]
      })

    health = fn lane -> lane.credential_id != "cred-dead" end

    assert [%{model_name: "pricey"}, %{model_name: "cheap"}] =
             CostRanker.rank([degraded, healthy], analysis(), health_fun: health)

    assert hd(CostRanker.rank([degraded, healthy], analysis(), health_fun: health)).healthy
    refute List.last(CostRanker.rank([degraded, healthy], analysis(), health_fun: health)).healthy
  end

  test "potency mode also prefers a healthy low tier over a degraded high tier" do
    degraded_high =
      F.candidate("uc", "degraded", "high", %{
        lanes: [F.lane("degraded", %{credential_id: "cred-dead"})]
      })

    healthy_low = F.candidate("uc", "healthy", "low")

    health = fn lane -> lane.credential_id != "cred-dead" end

    assert [%{model_name: "healthy"}, %{model_name: "degraded"}] =
             CostRanker.rank([degraded_high, healthy_low], analysis(),
               mode: :potency,
               health_fun: health
             )
  end

  test "an unpriced destination never outranks a priced one, whatever its priority" do
    unpriced =
      F.candidate("uc", "unpriced", "low", %{
        priority: 1,
        lane: %{input_cost_per_million: nil, output_cost_per_million: nil}
      })

    priced =
      F.candidate("uc", "priced", "low", %{
        priority: 99,
        lane: %{
          input_cost_per_million: Decimal.new("1.50"),
          output_cost_per_million: Decimal.new("1.50")
        }
      })

    assert [%{model_name: "priced"}, %{model_name: "unpriced"}] =
             CostRanker.rank([unpriced, priced], analysis())
  end
end
