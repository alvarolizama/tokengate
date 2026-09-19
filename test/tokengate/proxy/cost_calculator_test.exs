defmodule Tokengate.Proxy.CostCalculatorTest do
  use ExUnit.Case, async: true
  alias Tokengate.Proxy.CostCalculator

  describe "provider_cost/2 — billing surface no longer exempts" do
    test "reported cost is recorded for every provider" do
      # There is no billing_mode argument anymore: a subscription provider is
      # priced by the same chain. A reported cost is never forced to $0.
      assert Decimal.equal?(
               CostCalculator.provider_cost(Decimal.new("0.5"), []),
               Decimal.new("0.5")
             )
    end

    test "manual pricing applies for every provider" do
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("2.50"),
          output_cost_per_million: Decimal.new("10.00"),
          cache_cost_per_million: Decimal.new("0.50")
        },
        usage: %{prompt_tokens: 1000, completion_tokens: 500}
      ]

      # 1000×2.50 + 500×10.00 = 7500 / 1M = 0.0075
      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new("0.0075"))
    end
  end

  describe "provider_cost/2 — reported cost" do
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
               CostCalculator.provider_cost(Decimal.new("0.003"), opts),
               Decimal.new("0.003")
             )
    end

    test "rounds to 6 decimal places" do
      assert Decimal.equal?(
               CostCalculator.provider_cost(Decimal.new("0.003123456"), []),
               Decimal.new("0.003123")
             )
    end

    test "accepts numeric input" do
      assert Decimal.equal?(CostCalculator.provider_cost(0.0125, []), Decimal.new("0.0125"))
    end

    test "accepts binary input" do
      assert Decimal.equal?(CostCalculator.provider_cost("0.0007", []), Decimal.new("0.0007"))
    end

    test "unparseable binary: $0 fallback" do
      assert Decimal.equal?(CostCalculator.provider_cost("not a number", []), Decimal.new(0))
    end
  end

  describe "provider_cost/2 — 3-term manual fallback (input + cache + output)" do
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

      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new("0.000013"))
    end

    test "cache hit prices cached tokens at the cache rate (validated)" do
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("0.14"),
          output_cost_per_million: Decimal.new("0.44"),
          cache_cost_per_million: Decimal.new("0.026")
        },
        usage: %{prompt_tokens: 113, completion_tokens: 10, cache_read_tokens: 64}
      ]

      result = CostCalculator.provider_cost(nil, opts)
      assert Decimal.equal?(result, Decimal.new("0.000013"))
    end

    test "no cache prices all prompt tokens at input rate (validated)" do
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

      result = CostCalculator.provider_cost(nil, opts)
      assert Decimal.equal?(result, Decimal.new("0.000020"))
    end
  end

  describe "provider_cost/2 — 2-term fallback (no cache cost set)" do
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
      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new("0.0075"))
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

      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new(0))
    end
  end

  describe "provider_cost/2 — edge cases" do
    test "only input set (output nil): $0 (both required)" do
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("2.50"),
          output_cost_per_million: nil,
          cache_cost_per_million: Decimal.new("0.50")
        },
        usage: %{prompt_tokens: 1000, completion_tokens: 500}
      ]

      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new(0))
    end

    test "no manual_pricing in opts: $0" do
      assert Decimal.equal?(CostCalculator.provider_cost(nil, []), Decimal.new(0))
    end

    test "empty manual_pricing map: $0" do
      opts = [manual_pricing: %{}, usage: %{prompt_tokens: 1000, completion_tokens: 500}]

      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new(0))
    end

    test "non-parsable reported value (map/list): $0 fallback" do
      assert Decimal.equal?(CostCalculator.provider_cost(%{cost: 1}, []), Decimal.new(0))
      assert Decimal.equal?(CostCalculator.provider_cost([1, 2], []), Decimal.new(0))
    end
  end

  describe "provider_cost/2 — precio por unidad (image/video/tts/stt/music)" do
    # `pricing_unit` no es token: la cantidad facturable la produce
    # `ServiceUsage` (imágenes, segundos, caracteres…) y el precio es
    # `unit_cost`. Sin esta ruta esos tipos sólo se cobraban si el upstream
    # reportaba el coste.

    test "per_image: cantidad × precio, sin divisor" do
      opts = [
        pricing_unit: "per_image",
        unit_cost: Decimal.new("0.04"),
        quantities: %{"per_image" => 3, "per_request" => 1}
      ]

      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new("0.12"))
    end

    test "per_megapixel: cantidad fraccionaria × precio" do
      opts = [
        pricing_unit: "per_megapixel",
        unit_cost: Decimal.new("0.02"),
        quantities: %{"per_megapixel" => 2.0}
      ]

      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new("0.04"))
    end

    test "per_second: cantidad fraccionaria × precio" do
      opts = [
        pricing_unit: "per_second",
        unit_cost: Decimal.new("0.09"),
        quantities: %{"per_second" => 12.5}
      ]

      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new("1.125"))
    end

    test "per_minute" do
      opts = [
        pricing_unit: "per_minute",
        unit_cost: Decimal.new("0.006"),
        quantities: %{"per_minute" => 2}
      ]

      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new("0.012"))
    end

    test "per_1k_characters: el divisor de 1000 entra en la fórmula" do
      opts = [
        pricing_unit: "per_1k_characters",
        unit_cost: Decimal.new("0.015"),
        quantities: %{"per_1k_characters" => 4000}
      ]

      # 4000 × 0.015 / 1000 = 0.06
      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new("0.06"))
    end

    test "per_request: la cantidad es la llamada misma (1)" do
      opts = [
        pricing_unit: "per_request",
        unit_cost: Decimal.new("0.25"),
        quantities: %{"per_request" => 1}
      ]

      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new("0.25"))
    end

    test "sin precio unitario: $0 (nunca se inventa)" do
      opts = [pricing_unit: "per_image", quantities: %{"per_image" => 3}]
      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new(0))
    end

    test "cantidad 0: $0" do
      opts = [
        pricing_unit: "per_second",
        unit_cost: Decimal.new("0.09"),
        quantities: %{"per_second" => 0}
      ]

      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new(0))
    end

    test "unidad que no está en las cantidades de la llamada: $0" do
      opts = [
        pricing_unit: "per_minute",
        unit_cost: Decimal.new("0.006"),
        quantities: %{"per_image" => 3}
      ]

      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new(0))
    end

    test "el coste reportado por el upstream SIGUE ganando a la unidad" do
      opts = [
        pricing_unit: "per_image",
        unit_cost: Decimal.new("0.04"),
        quantities: %{"per_image" => 3}
      ]

      assert Decimal.equal?(
               CostCalculator.provider_cost(Decimal.new("0.99"), opts),
               Decimal.new("0.99")
             )
    end
  end

  describe "provider_cost/2 — la ruta por tokens no cambia" do
    test "sin pricing_unit explícito se asume la unidad de siempre (tokens)" do
      opts = [
        manual_pricing: %{
          input_cost_per_million: Decimal.new("2.50"),
          output_cost_per_million: Decimal.new("10.00"),
          cache_cost_per_million: Decimal.new("0.50")
        },
        usage: %{prompt_tokens: 1000, completion_tokens: 500}
      ]

      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new("0.0075"))
    end

    test "pricing_unit token explícito usa los tres campos de token, no unit_cost" do
      opts = [
        pricing_unit: "per_1m_tokens",
        unit_cost: Decimal.new("999"),
        quantities: %{"per_1m_tokens" => 100},
        manual_pricing: %{
          input_cost_per_million: Decimal.new("2.50"),
          output_cost_per_million: Decimal.new("10.00"),
          cache_cost_per_million: Decimal.new("0.50")
        },
        usage: %{prompt_tokens: 1000, completion_tokens: 500}
      ]

      # gana la fórmula de tokens: unit_cost no participa.
      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new("0.0075"))
    end

    test "per_1k_tokens es token: sigue leyendo manual_pricing" do
      opts = [
        pricing_unit: "per_1k_tokens",
        unit_cost: Decimal.new("999"),
        manual_pricing: %{
          input_cost_per_million: Decimal.new("2.50"),
          output_cost_per_million: Decimal.new("10.00"),
          cache_cost_per_million: nil
        },
        usage: %{prompt_tokens: 1000, completion_tokens: 500}
      ]

      # 2-term: (1000×2.50 + 500×10.00)/1M = 0.0075
      assert Decimal.equal?(CostCalculator.provider_cost(nil, opts), Decimal.new("0.0075"))
    end
  end
end
