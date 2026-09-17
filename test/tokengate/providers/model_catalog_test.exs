defmodule Tokengate.Providers.ModelCatalogTest do
  @moduledoc """
  The model-level derivation, as a pure function: what comes out of the two
  models.dev payloads, what wins when a model is both canonical and served, and
  the two properties the picker depends on — it must include ids only a provider
  publishes, and it must never offer a model whose provider the gateway cannot
  serve.
  """

  use ExUnit.Case, async: true

  alias Tokengate.Providers.ModelCatalog

  # A normalized provider entry, as Catalog.normalize_providers/1 produces it.
  defp provider(key, opts \\ []) do
    %{
      key: key,
      name: Keyword.get(opts, :name, key),
      base_url: Keyword.get(opts, :base_url, "https://api.#{key}.example/v1"),
      doc_url: nil,
      logo_url: "https://models.dev/logos/#{key}.svg",
      env: [],
      npm: Keyword.get(opts, :npm, "@ai-sdk/openai-compatible"),
      status: "active"
    }
  end

  # A provider payload: one provider, with its per-model map.
  defp providers_payload(entries) do
    Map.new(entries, fn {key, models} -> {key, %{"id" => key, "models" => models}} end)
  end

  defp model_entry(id, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "name" => id,
        "limit" => %{"context" => 128_000, "output" => 8_192}
      },
      attrs
    )
  end

  describe "offers" do
    test "one offer per (provider, model) of every servable provider" do
      payload =
        providers_payload([
          {"alpha", %{"m-1" => model_entry("m-1"), "m-2" => model_entry("m-2")}},
          {"beta", %{"m-1" => model_entry("m-1")}}
        ])

      %{offers: offers} = ModelCatalog.derive([provider("alpha"), provider("beta")], payload, %{})

      assert length(offers) == 3

      assert Enum.any?(offers, &(&1.provider_key == "alpha" and &1.model_key == "m-1"))
      assert Enum.any?(offers, &(&1.provider_key == "alpha" and &1.model_key == "m-2"))
      assert Enum.any?(offers, &(&1.provider_key == "beta" and &1.model_key == "m-1"))

      # `provider_model` is the id to send upstream, taken from the provider's
      # own entry.
      assert Enum.all?(offers, &(&1.provider_model == &1.model_key))
    end

    test "a provider the gateway cannot serve contributes no offer" do
      # No base URL is unsupported (Catalog.unsupported_reason/1): zero offers, so
      # its models never enter the picker.
      payload = providers_payload([{"alpha", %{"m-1" => model_entry("m-1")}}])

      unsupported = %{provider("alpha") | base_url: nil}
      assert %{offers: [], models: []} = ModelCatalog.derive([unsupported], payload, %{})
    end

    test "carries the provider's price and its context tiers" do
      entry =
        model_entry("m-1", %{
          "cost" => %{
            "input" => 0.65,
            "output" => 3.25,
            "cache_read" => 0.13,
            "tiers" => [
              %{"input" => 1.17, "tier" => %{"type" => "context", "size" => 32_000}}
            ]
          }
        })

      payload = providers_payload([{"alpha", %{"m-1" => entry}}])
      %{offers: [offer]} = ModelCatalog.derive([provider("alpha")], payload, %{})

      assert Decimal.equal?(offer.cost_input, Decimal.new("0.65"))
      assert Decimal.equal?(offer.cost_output, Decimal.new("3.25"))
      assert [tier] = offer.tiers
      assert tier["size"] == 32_000
      assert tier["input"] == "1.17"
    end

    test "records the lifecycle models.dev flags for that provider" do
      entry = model_entry("m-1", %{"status" => "deprecated", "experimental" => true})
      payload = providers_payload([{"alpha", %{"m-1" => entry}}])

      %{offers: [offer]} = ModelCatalog.derive([provider("alpha")], payload, %{})
      assert offer.lifecycle == "deprecated"
      assert offer.experimental == true
    end
  end

  describe "models" do
    test "an id only a provider publishes still gets a model row" do
      # The picker cannot be built from /models.json: most served ids are not in
      # it (fireworks routers, @cf/*, z.ai's glm-*).
      entry = model_entry("accounts/fireworks/routers/kimi-latest", %{"name" => "Kimi Latest"})

      payload =
        providers_payload([
          {"fireworks-ai", %{"accounts/fireworks/routers/kimi-latest" => entry}}
        ])

      %{models: [model]} = ModelCatalog.derive([provider("fireworks-ai")], payload, %{})

      assert model.key == "accounts/fireworks/routers/kimi-latest"
      assert model.name == "Kimi Latest"
      assert model.canonical == false
      # A path of its own is not a lab/model pair: no lab to attribute it to.
      assert model.lab_key == nil
    end

    test "the canonical payload wins for what the model IS" do
      payload = providers_payload([{"alpha", %{"openai/gpt-5" => model_entry("openai/gpt-5")}}])

      canonical = %{
        "openai/gpt-5" => %{
          "id" => "openai/gpt-5",
          "name" => "GPT-5",
          "description" => "Frontier model",
          "limit" => %{"context" => 400_000, "output" => 128_000},
          "release_date" => "2025-08-07",
          "tool_call" => true
        }
      }

      %{models: [model]} = ModelCatalog.derive([provider("alpha")], payload, canonical)

      assert model.canonical == true
      assert model.name == "GPT-5"
      assert model.context_limit == 400_000
      assert model.lab_key == "openai"
      assert model.release_date == "2025-08-07"
      assert "tool_call" in model.features
    end

    test "the market price is the cheapest offer, since /models.json carries none" do
      payload =
        providers_payload([
          {"expensive", %{"m-1" => model_entry("m-1", %{"cost" => %{"input" => 9.0}})}},
          {"cheap", %{"m-1" => model_entry("m-1", %{"cost" => %{"input" => 0.5}})}}
        ])

      %{models: [model]} =
        ModelCatalog.derive([provider("cheap"), provider("expensive")], payload, %{})

      assert Decimal.equal?(model.cost_input, Decimal.new("0.5"))
    end

    test "an offer without a price never wins over one that has it" do
      payload =
        providers_payload([
          {"free_lane", %{"m-1" => model_entry("m-1")}},
          {"priced", %{"m-1" => model_entry("m-1", %{"cost" => %{"input" => 2.0}})}}
        ])

      %{models: [model]} =
        ModelCatalog.derive([provider("free_lane"), provider("priced")], payload, %{})

      assert Decimal.equal?(model.cost_input, Decimal.new("2.0"))
    end
  end

  describe "hints" do
    test "short_name strips a lab prefix and keeps the last segment of a path" do
      assert ModelCatalog.short_name("openai/gpt-5-nano") == "gpt-5-nano"
      assert ModelCatalog.short_name("glm-5.2") == "glm-5.2"
      assert ModelCatalog.short_name("accounts/fireworks/routers/kimi-latest") == "kimi-latest"
    end

    test "lab_key only for a lab/model id" do
      assert ModelCatalog.lab_key("anthropic/claude-opus-4.7") == "anthropic"
      assert ModelCatalog.lab_key("glm-5.2") == nil
      assert ModelCatalog.lab_key("accounts/fireworks/routers/kimi-latest") == nil
      assert ModelCatalog.lab_key("@cf/meta/llama-3.1-8b-instruct") == nil
    end

    test "model_type_hint reads the id, and the operator confirms it" do
      assert ModelCatalog.model_type_hint("google/gemini-embedding-001") == "embedding"
      assert ModelCatalog.model_type_hint("openai/gpt-5-nano") == "llm"
    end

    test "to_model_params prefills the form from a catalog row" do
      params =
        ModelCatalog.to_model_params(%{
          key: "openai/gpt-5-nano",
          lab_key: "openai",
          context_limit: 400_000
        })

      assert params.name == "gpt-5-nano"
      assert params.context_window == 400_000
      assert params.catalog_model_key == "openai/gpt-5-nano"
      assert params.lab_key == "openai"
    end
  end

  describe "snapshot round-trip" do
    test "encode/decode preserves the derivation" do
      payload =
        providers_payload([
          {"alpha",
           %{"openai/gpt-5" => model_entry("openai/gpt-5", %{"cost" => %{"input" => 1.25}})}}
        ])

      canonical = %{"openai/gpt-5" => %{"id" => "openai/gpt-5", "name" => "GPT-5"}}
      derived = ModelCatalog.derive([provider("alpha")], payload, canonical)
      round_trip = ModelCatalog.decode_snapshot(ModelCatalog.encode_snapshot(derived))

      assert length(round_trip.models) == length(derived.models)
      assert length(round_trip.offers) == length(derived.offers)

      [original] = derived.models
      [decoded] = round_trip.models
      assert decoded.key == original.key
      assert decoded.name == original.name
      assert Decimal.equal?(decoded.cost_input, original.cost_input)

      [offer_original] = derived.offers
      [offer_decoded] = round_trip.offers
      assert offer_decoded.provider_model == offer_original.provider_model
      assert Decimal.equal?(offer_decoded.cost_input, offer_original.cost_input)
    end

    test "a missing snapshot file is empty, never a crash" do
      assert %{models: [], offers: []} = ModelCatalog.snapshot_from("/nope/does-not-exist.json")
    end

    test "the vendored snapshot is present and usable" do
      # A fresh instance seeds from it, so it must decode to real rows.
      %{models: models, offers: offers} = ModelCatalog.snapshot()
      assert length(models) > 100
      assert length(offers) > 100
      assert Enum.all?(models, &is_binary(&1.key))
      assert Enum.all?(offers, &is_binary(&1.provider_key))
    end
  end
end
