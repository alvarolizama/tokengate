defmodule Tokengate.Proxy.ServiceUsageTest do
  @moduledoc """
  La cantidad facturable por tipo: lo que hace posible cobrar image/video/tts/stt
  sin que el upstream reporte nada.
  """
  use ExUnit.Case, async: true

  alias Tokengate.Proxy.ServiceUsage
  alias Tokengate.Providers.Pricing

  doctest Tokengate.Proxy.ServiceUsage

  # 4 bytes de audio en base64 ("AAAA" decodifica a 3 bytes).
  @audio_data_url "data:audio/mpeg;base64,AAAA"

  describe "quantities/3 — tokens (llm/embedding/decision/rerank)" do
    test "lo reportado por el upstream gana" do
      q =
        ServiceUsage.quantities(
          "llm",
          %{"messages" => [%{"content" => "hola"}]},
          %{"usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50}}
        )

      assert q["per_1m_tokens"] == 150
      assert q["per_1k_tokens"] == 150
      assert q["per_request"] == 1
    end

    test "sin usage, estima del texto de la request" do
      q = ServiceUsage.quantities("rerank", %{"query" => "abcdefghij"}, %{})
      assert q["per_1m_tokens"] == 10
    end

    test "acepta la nomenclatura de la API de imágenes (input/output_tokens)" do
      q =
        ServiceUsage.quantities("rerank", %{}, %{
          "usage" => %{"input_tokens" => 7, "output_tokens" => 3}
        })

      assert q["per_1m_tokens"] == 10
    end
  end

  describe "quantities/3 — image" do
    test "cuenta las imágenes pedidas: `n` de la request" do
      q = ServiceUsage.quantities("image", %{"n" => 3}, %{})
      assert q["per_image"] == 3
    end

    test "cuenta las imágenes DEVUELTAS cuando el upstream responde" do
      q = ServiceUsage.quantities("image", %{"n" => 9}, %{"data" => [%{}, %{}]})
      assert q["per_image"] == 2
    end

    test "sin `n` ni `data` asume 1 (una generación)" do
      assert ServiceUsage.quantities("image", %{}, %{})["per_image"] == 1
    end

    test "megapíxeles = área × nº de imágenes" do
      q = ServiceUsage.quantities("image", %{"n" => 2, "size" => "1024x1024"}, %{})
      assert_in_delta q["per_megapixel"], 2.097152, 0.000001
    end

    test "sin tamaño no hay área: 0 megapíxeles (nunca se inventa)" do
      assert ServiceUsage.quantities("image", %{"n" => 2}, %{})["per_megapixel"] == 0
    end

    test "un tamaño con basura no rompe" do
      assert ServiceUsage.quantities("image", %{"size" => "auto"}, %{})["per_megapixel"] == 0
      assert ServiceUsage.quantities("image", %{"size" => "0x0"}, %{})["per_megapixel"] == 0
    end
  end

  describe "quantities/3 — video y music" do
    test "segundos reportados por el upstream" do
      assert ServiceUsage.quantities("video", %{}, %{"duration" => 8})["per_second"] == 8
      assert ServiceUsage.quantities("music", %{}, %{"seconds" => 12})["per_second"] == 12
    end

    test "segundos pedidos en la request, como string" do
      assert ServiceUsage.quantities("video", %{"seconds" => "5"}, %{})["per_second"] == 5.0
    end

    test "sin señal: 0 segundos" do
      assert ServiceUsage.quantities("video", %{}, %{})["per_second"] == 0
    end
  end

  describe "quantities/3 — tts" do
    test "cuenta los caracteres del texto de entrada" do
      assert ServiceUsage.quantities("tts", %{"input" => "hola mundo"}, %{})["per_1k_characters"] ==
               10
    end

    test "suma los elementos cuando `input` es una lista" do
      assert ServiceUsage.quantities("tts", %{"input" => ["uno", "dos"]}, %{})[
               "per_1k_characters"
             ] == 6
    end

    test "sin texto: 0 caracteres" do
      assert ServiceUsage.quantities("tts", %{}, %{})["per_1k_characters"] == 0
    end
  end

  describe "quantities/3 — stt" do
    test "usa la duración reportada por el upstream (y la expresa en minutos)" do
      q = ServiceUsage.quantities("stt", %{}, %{"usage" => %{"duration" => 120}})
      assert q["per_second"] == 120
      assert q["per_minute"] == 2.0
    end

    test "sin duración reportada, la estima del audio (data URL base64)" do
      q = ServiceUsage.quantities("stt", %{"input_audio" => %{"data" => @audio_data_url}}, %{})
      # 3 bytes × 8 / 128_000 = 0.0001875 → redondeado a 3 decimales
      assert q["per_second"] == 0.0
      assert q["per_minute"] == 0.0
    end

    test "un audio grande sí da segundos" do
      # 1.6 MB → 10 s a 128 kbps
      audio = Base.encode64(:binary.copy(<<0>>, 1_600_000))

      q =
        ServiceUsage.quantities(
          "stt",
          %{"input_audio" => %{"data" => "data:audio/mpeg;base64," <> audio}},
          %{}
        )

      assert_in_delta q["per_second"], 100.0, 0.01
    end

    test "cuenta los caracteres de la transcripción cuando el upstream la trae" do
      q = ServiceUsage.quantities("stt", %{}, %{"text" => "hola"})
      assert q["per_1k_characters"] == 4
    end
  end

  describe "audio_seconds_from_bytes/1" do
    test "convierte bytes a segundos al bitrate nominal" do
      assert ServiceUsage.audio_seconds_from_bytes(160_000) == 10.0
    end

    test "nil y 0 son 0, no un crash" do
      assert ServiceUsage.audio_seconds_from_bytes(nil) == 0
      assert ServiceUsage.audio_seconds_from_bytes(0) == 0
    end
  end

  describe "quantity/4" do
    test "devuelve la cantidad de una unidad concreta" do
      assert ServiceUsage.quantity("image", "per_image", %{"n" => 4}, %{}) == 4
      assert ServiceUsage.quantity("image", "per_second", %{"n" => 4}, %{}) == nil
    end
  end

  # Invariante que ata las dos mitades: TODA unidad que el formulario ofrece para
  # un tipo tiene que ser producible por el extractor. Si se añade una unidad al
  # vocabulario sin enseñarle al extractor a medirla, el lane cobraría $0 en
  # silencio — este test es el que lo impide.
  describe "invariante unidades ↔ cantidades" do
    # 160_000 bytes → 10 s a 128 kbps: un audio con señal de verdad, para que el
    # invariante no se conforme con un cero.
    @ten_second_audio Base.encode64(:binary.copy(<<0>>, 160_000))

    @fixtures %{
      "llm" =>
        {%{"messages" => [%{"content" => "hola"}]}, %{"usage" => %{"prompt_tokens" => 10}}},
      "embedding" => {%{"input" => "hola"}, %{"usage" => %{"prompt_tokens" => 5}}},
      "decision" => {%{"questions" => ["a"]}, %{"usage" => %{"prompt_tokens" => 5}}},
      "rerank" => {%{"query" => "hola", "documents" => ["a"]}, %{}},
      "image" => {%{"n" => 1, "size" => "1024x1024"}, %{"data" => [%{}]}},
      "video" => {%{"seconds" => 5}, %{"duration" => 5}},
      "music" => {%{"seconds" => 5}, %{"duration" => 5}},
      "tts" => {%{"input" => "hola"}, %{}},
      "stt" =>
        {%{"input_audio" => %{"data" => "data:audio/mpeg;base64," <> @ten_second_audio}},
         %{"text" => "hola"}}
    }

    test "cada unidad ofrecida para un tipo la sabe medir el extractor" do
      for {type, {payload, body}} <- @fixtures do
        quantities = ServiceUsage.quantities(type, payload, body)

        for unit <- Pricing.units_for_type(type) do
          assert Map.has_key?(quantities, unit),
                 "#{type}: el formulario ofrece «#{unit}» pero ServiceUsage no lo mide"
        end
      end
    end

    test "ninguna unidad ofrecida es un cero garantizado" do
      # Con una request real, cada unidad ofrecida tiene que dar cantidad > 0.
      # Una unidad que siempre mide 0 está muerta por construcción: se ofrece en
      # el formulario y nunca cobra.
      muertas =
        for {type, {payload, body}} <- @fixtures,
            unit <- Pricing.units_for_type(type),
            ServiceUsage.quantity(type, unit, payload, body) in [0, 0.0, nil] do
          {type, unit}
        end

      assert muertas == []
    end
  end
end
