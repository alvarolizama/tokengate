defmodule Tokengate.Providers.PricingTest do
  @moduledoc """
  El vocabulario de unidades de precio y su puente con el tipo de modelo: qué
  unidades tiene sentido ofrecer para cada tipo, cuál es la de por defecto y el
  divisor con el que una cantidad se expresa en múltiplos de la unidad.
  """
  use ExUnit.Case, async: true

  alias Tokengate.Providers.Pricing
  alias Tokengate.Providers.ModelProvider

  @all_types ~w(llm embedding decision rerank stt tts image video music)

  describe "vocabulario" do
    test "las unidades son las ocho del CHECK de la migración" do
      assert Pricing.units() == ~w(
               per_1m_tokens per_1k_tokens per_request per_image per_megapixel
               per_second per_minute per_1k_characters
             )
    end

    test "la unidad por defecto es la de siempre (tokens por millón)" do
      assert Pricing.default_unit() == "per_1m_tokens"
    end

    test "token_unit?/1 y token_units/0 coinciden" do
      assert Pricing.token_units() == ~w(per_1m_tokens per_1k_tokens)

      for unit <- Pricing.token_units(), do: assert(Pricing.token_unit?(unit))
      refute Pricing.token_unit?("per_image")
      refute Pricing.token_unit?(nil)
    end
  end

  describe "divisor/1" do
    test "las unidades escaladas dividen; el resto no" do
      assert Pricing.divisor("per_1m_tokens") == 1_000_000
      assert Pricing.divisor("per_1k_tokens") == 1_000
      assert Pricing.divisor("per_1k_characters") == 1_000
      assert Pricing.divisor("per_image") == 1
      assert Pricing.divisor("per_second") == 1
      assert Pricing.divisor("per_request") == 1
      assert Pricing.divisor(nil) == 1
    end
  end

  describe "default_unit_for_type/1" do
    test "cada tipo de media arranca en su unidad real, no en tokens" do
      assert Pricing.default_unit_for_type("image") == "per_image"
      assert Pricing.default_unit_for_type("video") == "per_second"
      assert Pricing.default_unit_for_type("music") == "per_second"
      assert Pricing.default_unit_for_type("tts") == "per_1k_characters"
      assert Pricing.default_unit_for_type("stt") == "per_minute"
    end

    test "los tipos que sí se facturan por tokens se quedan en tokens" do
      for type <- ~w(llm embedding decision rerank) do
        assert Pricing.default_unit_for_type(type) == "per_1m_tokens"
      end
    end

    test "un tipo desconocido o ausente cae a la unidad por defecto" do
      assert Pricing.default_unit_for_type(nil) == "per_1m_tokens"
      assert Pricing.default_unit_for_type("no-existe") == "per_1m_tokens"
    end
  end

  describe "units_for_type/1" do
    test "las unidades de cada tipo" do
      assert Pricing.units_for_type("image") == ~w(per_image per_megapixel per_request)
      assert Pricing.units_for_type("video") == ~w(per_second per_request)
      assert Pricing.units_for_type("music") == ~w(per_second per_request)
      assert Pricing.units_for_type("tts") == ~w(per_1k_characters per_request)
      assert Pricing.units_for_type("stt") == ~w(per_minute per_second per_request)
    end

    test "los tipos de token ofrecen las dos variantes de token" do
      for type <- ~w(llm embedding decision rerank) do
        assert Pricing.units_for_type(type) == ~w(per_1m_tokens per_1k_tokens per_request)
      end
    end

    test "el vocabulario de un tipo nunca inventa una unidad" do
      for type <- @all_types, unit <- Pricing.units_for_type(type) do
        assert unit in Pricing.units(), "#{type} ofrece «#{unit}» que no está en units/0"
      end
    end

    test "la unidad por defecto de un tipo está SIEMPRE entre las que ofrece" do
      # Si no lo estuviera, el formulario abriría con una unidad que su propio
      # select no puede representar.
      for type <- @all_types do
        assert Pricing.default_unit_for_type(type) in Pricing.units_for_type(type),
               "#{type}: su unidad por defecto no está entre las ofrecidas"
      end
    end
  end

  describe "label/1 y options_for_type/1" do
    test "etiqueta legible (en el idioma por defecto del entorno: inglés)" do
      assert Pricing.label("per_1m_tokens") == "per 1M tokens"
      assert Pricing.label("per_1k_characters") == "per 1K characters"
      assert Pricing.label("per_image") == "per image"
    end

    test "una unidad desconocida se etiqueta como sí misma, sin romper" do
      assert Pricing.label("per_banana") == "per_banana"
    end

    test "options_for_type/1 da {key, label} para el select" do
      options = Pricing.options_for_type("image")

      assert options == [
               %{key: "per_image", label: "per image"},
               %{key: "per_megapixel", label: "per megapixel"},
               %{key: "per_request", label: "per request"}
             ]
    end
  end

  describe "model_provider: pricing_unit en el changeset" do
    test "acepta cualquier unidad del vocabulario" do
      for unit <- Pricing.units() do
        changeset =
          ModelProvider.changeset(%ModelProvider{}, %{
            model_id: Ecto.UUID.generate(),
            credential_id: Ecto.UUID.generate(),
            provider_model: "x",
            enabled: true,
            pricing_unit: unit
          })

        refute changeset.errors[:pricing_unit],
               "«#{unit}» debería ser una unidad válida"
      end
    end

    test "rechaza una unidad fuera del vocabulario" do
      changeset =
        ModelProvider.changeset(%ModelProvider{}, %{
          model_id: Ecto.UUID.generate(),
          credential_id: Ecto.UUID.generate(),
          provider_model: "x",
          enabled: true,
          pricing_unit: "per_banana"
        })

      assert {"is invalid", _} = changeset.errors[:pricing_unit]
    end

    test "un row sin pricing_unit toma la unidad por defecto" do
      changeset =
        ModelProvider.changeset(%ModelProvider{}, %{
          model_id: Ecto.UUID.generate(),
          credential_id: Ecto.UUID.generate(),
          provider_model: "x",
          enabled: true
        })

      refute changeset.errors[:pricing_unit]
    end

    test "unit_cost es opcional y persiste como Decimal" do
      changeset =
        ModelProvider.changeset(%ModelProvider{}, %{
          model_id: Ecto.UUID.generate(),
          credential_id: Ecto.UUID.generate(),
          provider_model: "x",
          enabled: true,
          pricing_unit: "per_image",
          unit_cost: "0.0400"
        })

      assert Ecto.Changeset.get_change(changeset, :unit_cost) == Decimal.new("0.0400")
    end
  end
end
