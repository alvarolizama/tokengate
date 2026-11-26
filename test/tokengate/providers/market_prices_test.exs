defmodule Tokengate.Providers.MarketPricesTest do
  use Tokengate.DataCase, async: false

  alias Tokengate.Providers
  alias Tokengate.Providers.{MarketPrices, Model}

  setup do
    MarketPrices.clear_index()
    on_exit(fn -> MarketPrices.clear_index() end)
    :ok
  end

  test "extract_index/1 and lookup/2 prefer lane provider, then lab, then id/short name" do
    payload = %{
      "openai" => %{
        "models" => %{
          "gpt-4o" => %{"cost" => %{"input" => 2.5, "output" => 10.0, "cache_read" => 1.25}}
        }
      },
      "openrouter" => %{
        "models" => %{
          "openai/gpt-4o" => %{
            "cost" => %{"input" => 3.0, "output" => 12.0, "cache_read" => 1.5}
          }
        }
      }
    }

    index = MarketPrices.extract_index(payload)

    assert {:ok, lane_hit} =
             MarketPrices.lookup(index,
               name: "gpt-4o",
               lab_key: "openai",
               lanes: [{"openrouter", "openai/gpt-4o"}]
             )

    assert lane_hit.provider_key == "openrouter"
    assert Decimal.equal?(lane_hit.input, Decimal.new("3.0"))

    assert {:ok, lab_hit} = MarketPrices.lookup(index, name: "gpt-4o", lab_key: "openai")
    assert lab_hit.provider_key == "openai"
    assert Decimal.equal?(lab_hit.input, Decimal.new("2.5"))
    assert Decimal.equal?(lab_hit.output, Decimal.new("10.0"))
    assert Decimal.equal?(lab_hit.cache, Decimal.new("1.25"))
  end

  test "sync_configured_models/2 updates models.dev models and preserves manual overrides" do
    u = System.unique_integer([:positive])

    {:ok, auto_model} =
      Providers.create_model(%{
        name: "gpt-4o-#{u}",
        context_window: 128_000,
        lab_key: "openai"
      })

    {:ok, manual_model} =
      Providers.create_model(%{
        name: "claude-manual-#{u}",
        context_window: 200_000,
        lab_key: "anthropic",
        market_input_price_per_1m: Decimal.new("9.99"),
        market_output_price_per_1m: Decimal.new("19.99"),
        market_price_source: "manual"
      })

    payload = %{
      "openai" => %{
        "models" => %{
          "gpt-4o-#{u}" => %{
            "cost" => %{"input" => 2.5, "output" => 10.0, "cache_read" => 1.25}
          }
        }
      },
      "anthropic" => %{
        "models" => %{
          "claude-manual-#{u}" => %{"cost" => %{"input" => 3.0, "output" => 15.0}}
        }
      }
    }

    assert %{updated: 1} = MarketPrices.sync_configured_models(payload)

    reloaded_auto = Repo.get!(Model, auto_model.id)
    assert reloaded_auto.market_price_source == "models.dev"
    assert Decimal.equal?(reloaded_auto.market_input_price_per_1m, Decimal.new("2.5"))
    assert Decimal.equal?(reloaded_auto.market_output_price_per_1m, Decimal.new("10.0"))
    assert Decimal.equal?(reloaded_auto.market_cache_price_per_1m, Decimal.new("1.25"))
    assert reloaded_auto.market_price_synced_at != nil

    reloaded_manual = Repo.get!(Model, manual_model.id)
    assert reloaded_manual.market_price_source == "manual"
    assert Decimal.equal?(reloaded_manual.market_input_price_per_1m, Decimal.new("9.99"))
  end

  test "extract_index/1 captures context_window and sync_configured_models skips limit-only entries" do
    u = System.unique_integer([:positive])

    {:ok, limit_only_model} =
      Providers.create_model(%{
        name: "limit-only-#{u}",
        context_window: 128_000,
        lab_key: "openai"
      })

    payload = %{
      "openai" => %{
        "models" => %{
          "limit-only-#{u}" => %{
            "limit" => %{"context" => 256_000, "output" => 16_384}
          },
          "gpt-priced-#{u}" => %{
            "cost" => %{"input" => 1.0, "output" => 2.0},
            "limit" => %{"context" => 1_000_000}
          }
        }
      }
    }

    index = MarketPrices.extract_index(payload)

    assert {:ok, limit_entry} =
             MarketPrices.lookup(index, name: "limit-only-#{u}", lab_key: "openai")

    assert limit_entry.context_window == 256_000
    assert limit_entry.input == nil

    assert {:ok, priced_entry} =
             MarketPrices.lookup(index, name: "gpt-priced-#{u}", lab_key: "openai")

    assert priced_entry.context_window == 1_000_000
    assert Decimal.equal?(priced_entry.input, Decimal.new("1.0"))

    assert %{updated: 0} = MarketPrices.sync_configured_models(payload)
    reloaded = Repo.get!(Model, limit_only_model.id)
    assert reloaded.market_price_source == nil
  end
end
