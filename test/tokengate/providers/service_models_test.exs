defmodule Tokengate.Providers.ServiceModelsTest do
  @moduledoc """
  El marcado por tipo que models.dev no publica: clasificación por familia de id,
  alias de superficie (DashScope), semilla verificada y endpoints de
  descubrimiento por servicio.

  Los ids de ejemplo NO son inventados: salen de la documentación de cada
  proveedor (ver las fuentes citadas en `ServiceModels`).
  """
  use ExUnit.Case, async: true

  alias Tokengate.Providers.ServiceModels

  doctest Tokengate.Providers.ServiceModels

  describe "vocabulary" do
    test "the three media types are exactly the ones models.dev cannot classify" do
      assert ServiceModels.media_types() == ~w(stt tts image)
    end

    test "media_type?/1 accepts the three and rejects the catalog-known ones" do
      for type <- ServiceModels.media_types() do
        assert ServiceModels.media_type?(type)
      end

      refute ServiceModels.media_type?("llm")
      refute ServiceModels.media_type?("embedding")
      refute ServiceModels.media_type?("decision")
      refute ServiceModels.media_type?(nil)
    end
  end

  describe "classify/2 — Alibaba / DashScope families" do
    test "stt" do
      assert ServiceModels.classify("alibaba", "qwen3-asr-flash") == "stt"
      assert ServiceModels.classify("alibaba", "qwen3-asr-flash-2026-02-10") == "stt"
      assert ServiceModels.classify("alibaba", "qwen-audio-3.0-asr-flash") == "stt"
      assert ServiceModels.classify("alibaba", "fun-asr-realtime-2026-02-28") == "stt"
      assert ServiceModels.classify("alibaba", "paraformer-realtime-v2") == "stt"
    end

    test "tts" do
      assert ServiceModels.classify("alibaba", "qwen3-tts") == "tts"
      assert ServiceModels.classify("alibaba", "qwen3-tts-flash-realtime-2025-11-27") == "tts"
      assert ServiceModels.classify("alibaba", "qwen-audio-3.0-tts-flash") == "tts"
      assert ServiceModels.classify("alibaba", "cosyvoice-v3.5-plus") == "tts"
    end

    test "image" do
      assert ServiceModels.classify("alibaba", "qwen-image-2.0-pro") == "image"
      assert ServiceModels.classify("alibaba", "wan2.7-image-pro") == "image"
      assert ServiceModels.classify("alibaba", "wan2.6-t2i") == "image"
      assert ServiceModels.classify("alibaba", "wan2.5-i2i-preview") == "image"
      assert ServiceModels.classify("alibaba", "wanx2.1-imageedit") == "image"
    end

    test "an llm id is NOT classified as a service" do
      assert ServiceModels.classify("alibaba", "qwen3-max") == nil
      assert ServiceModels.classify("alibaba", "qwen3-235b-a22b") == nil
    end
  end

  describe "classify/2 — OpenRouter families" do
    test "stt / tts (sin endpoint de listado)" do
      assert ServiceModels.classify("openrouter", "openai/whisper-1") == "stt"
      assert ServiceModels.classify("openrouter", "openai/gpt-4o-transcribe") == "stt"
      assert ServiceModels.classify("openrouter", "microsoft/mai-transcribe-2") == "stt"
      assert ServiceModels.classify("openrouter", "openai/gpt-4o-mini-tts-2025-12-15") == "tts"
      assert ServiceModels.classify("openrouter", "microsoft/mai-voice-2") == "tts"
    end

    test "image (verificado contra /images/models)" do
      assert ServiceModels.classify("openrouter", "qwen/qwen-image-3") == "image"
      assert ServiceModels.classify("openrouter", "black-forest-labs/flux.2-pro") == "image"
      assert ServiceModels.classify("openrouter", "openai/gpt-image-2") == "image"
    end

    test "un modelo de chat con salida de audio NO es tts (es llm)" do
      assert ServiceModels.classify("openrouter", "openai/gpt-audio") == nil
      assert ServiceModels.type_of("openrouter", "openai/gpt-audio") == "llm"
    end

    # TypeSafe sólo sirve decisiones y sus ids son aliases de Jev: sin patrón,
    # el paso 3 no podría ofrecer nada para el tipo `decision`.
    test "los aliases de Jev son `decision`" do
      assert ServiceModels.classify("typesafe", "jev-latest") == "decision"
      assert ServiceModels.classify("typesafe", "jev-1.13.0") == "decision"
      assert ServiceModels.type_of("typesafe", "jev-latest") == "decision"
    end

    test "un chat cualquiera no se clasifica como servicio" do
      assert ServiceModels.classify("openrouter", "anthropic/claude-opus-4.7") == nil
      assert ServiceModels.type_of("openrouter", "anthropic/claude-opus-4.7") == "llm"
    end
  end

  describe "classify/2 — NaN families" do
    # El catálogo REAL de api.nan.builders/v1/models (20 ids, verificado contra
    # la API). Esa respuesta trae un campo `mode`, pero el listado del gateway
    # sólo extrae ids, así que lo que ata cada id a su tipo es el patrón del
    # proveedor: este mapa es el contrato.
    test "cada id del catálogo cae en su tipo" do
      catalogue = %{
        "whisper" => "stt",
        "kokoro" => "tts",
        "flux-2-klein" => "image",
        "qwen-image-2.1" => "image",
        "qwen3-embedding" => "embedding",
        # Los trece de chat: ninguno casa con los patrones de media.
        "glm5.3" => "llm",
        "glm5.3-flash" => "llm",
        "deepseek-v4-flash" => "llm",
        "deepseek-v4-pro" => "llm",
        "qwen3.8-flash" => "llm",
        "qwen3.8-max" => "llm",
        "qwen3.6" => "llm",
        "qwen4-max" => "llm",
        "kimi-k3.1-pro" => "llm",
        "hy4" => "llm",
        "hy4-flash" => "llm",
        "gemma4" => "llm",
        "mimo-v2.6-flash" => "llm"
      }

      for {id, type} <- catalogue do
        assert ServiceModels.type_of("nan", id) == type,
               "nan/#{id} debería ser #{type}, fue #{inspect(ServiceModels.type_of("nan", id))}"
      end
    end

    test "un chat omnimodal NO es tts: la entrada de audio no es el endpoint de voz" do
      assert ServiceModels.classify("nan", "mimo-v2.6-flash") == nil
    end

    test "un id sin superficie conocida no se inventa un tipo" do
      # `minimax-h3` viene en /models sin `mode`, no está en la doc del
      # proveedor y con la key del operador responde 403: no hay nada que
      # clasificar más allá del hint del id.
      assert ServiceModels.type_of("nan", "minimax-h3") == "llm"
    end

    test "la semilla es exactamente lo que el proveedor publica" do
      assert ServiceModels.known_ids("nan", "stt") == ~w(whisper)
      assert ServiceModels.known_ids("nan", "tts") == ~w(kokoro)
      assert ServiceModels.known_ids("nan", "image") == ~w(flux-2-klein qwen-image-2.1)
      assert ServiceModels.known_ids("nan", "embedding") == ~w(qwen3-embedding)

      # `rerank` no se siembra: el gateway no tiene esa superficie (`rerank`
      # se retiró por completo en 887a1a9), y sembrarlo ofrecería un tipo que
      # ninguna ruta sirve.
      assert ServiceModels.known_ids("nan", "rerank") == []
    end
  end

  describe "classify/2 — Alibaba Token Plan" do
    # El plan sirve un SUBCONJUNTO de Model Studio, con las mismas familias de
    # id: comparte los patrones de `alibaba` vía `@shared_surfaces`, pero su
    # semilla es propia.
    test "las familias de Model Studio clasifican igual" do
      assert ServiceModels.classify("alibaba-token-plan", "qwen-audio-3.0-asr-flash") == "stt"
      assert ServiceModels.classify("alibaba-token-plan", "qwen-audio-3.0-tts-plus") == "tts"
      assert ServiceModels.classify("alibaba-token-plan", "qwen-image-3.0-pro") == "image"
      assert ServiceModels.classify("alibaba-token-plan", "wan2.7-image-pro") == "image"
      assert ServiceModels.classify("alibaba-token-plan-cn", "qwen-audio-3.0-tts-plus") == "tts"
    end

    test "los modelos de chat del plan no se clasifican como servicio" do
      for id <- ~w(qwen3.7-max qwen3.8-flash qwen4-max glm-5.3 deepseek-v4.1-flash auto) do
        assert ServiceModels.type_of("alibaba-token-plan", id) == "llm"
      end
    end

    test "la semilla es la del PLAN, no la de DashScope entero" do
      assert ServiceModels.known_ids("alibaba-token-plan", "stt") ==
               ~w(qwen-audio-3.0-asr-flash)

      assert ServiceModels.known_ids("alibaba-token-plan", "tts") ==
               ~w(qwen-audio-3.0-tts-plus)

      assert ServiceModels.known_ids("alibaba-token-plan", "image") ==
               ~w(qwen-image-3.0-pro wan2.7-image wan2.7-image-pro)

      # CosyVoice y los wan*-t2i están en la semilla de `alibaba` pero el plan
      # NO los sirve: heredarlos ofrecería ids que el upstream rechaza.
      refute "cosyvoice-v3-plus" in ServiceModels.known_ids("alibaba-token-plan", "tts")
      refute "wan2.6-t2i" in ServiceModels.known_ids("alibaba-token-plan", "image")

      # El alias de la región comparte la tabla (mismo catálogo, otro host).
      assert ServiceModels.known_ids("alibaba-token-plan-cn", "stt") ==
               ServiceModels.known_ids("alibaba-token-plan", "stt")
    end
  end

  describe "superficies compartidas" do
    test "alibaba-cn resuelve a la tabla de alibaba" do
      for key <- ~w(alibaba alibaba-cn) do
        assert ServiceModels.classify(key, "qwen3-asr-flash") == "stt"
        assert ServiceModels.known_ids(key, "stt") == ServiceModels.known_ids("alibaba", "stt")
      end
    end
  end

  describe "type_of/2" do
    test "el patrón del proveedor gana sobre el hint del id" do
      # "qwen3-tts-flash" no lleva señal en el id — sólo la familia lo clasifica.
      assert ServiceModels.type_of("alibaba", "qwen3-tts-flash") == "tts"
    end

    test "cae al hint de models.dev cuando ningún patrón casa" do
      assert ServiceModels.type_of("openai", "google/gemini-embedding-001") == "embedding"
      assert ServiceModels.type_of("typesafe", "typesafe/jev") == "decision"
      assert ServiceModels.type_of("no-such-provider", "text-embedding-3-large") == "embedding"
    end

    test "un proveedor desconocido no rompe: hint del id" do
      assert ServiceModels.type_of(nil, "openai/gpt-5-nano") == "llm"
      assert ServiceModels.type_of("alibaba", nil) == "llm"
    end
  end

  describe "semilla verificada (@known_ids)" do
    test "cada id de la semilla clasifica a SU propio tipo — invariante" do
      entries =
        for provider_key <- ServiceModels.provider_keys(),
            type <- ServiceModels.media_types(),
            model_id <- ServiceModels.known_ids(provider_key, type) do
          {provider_key, model_id, type}
        end

      assert entries != []

      for {provider_key, model_id, type} <- entries do
        assert ServiceModels.classify(provider_key, model_id) == type,
               "#{provider_key}/#{model_id} debería clasificar como #{type}, " <>
                 "clasificó como #{inspect(ServiceModels.classify(provider_key, model_id))}"
      end
    end

    test "seed_models_of_type/1 cruza proveedores" do
      assert {"alibaba", "qwen3-asr-flash"} in ServiceModels.seed_models_of_type("stt")

      assert {"openrouter", "openai/gpt-image-2"} in ServiceModels.seed_models_of_type("image")
    end

    # Invariante que ata la semilla con el paso 1 del wizard: cada fila tiene que
    # estar en un proveedor que DECLARE ese tipo. Si no, es INALCANZABLE — el paso
    # 1 filtra por capability, así que el proveedor no aparece para ese tipo y el
    # id sembrado jamás se ofrece.
    test "toda fila de la semilla está en un proveedor que DECLARA su tipo" do
      inalcanzables =
        for type <- ServiceModels.media_types(),
            {provider_key, id} <- ServiceModels.seed_models_of_type(type),
            not Tokengate.Providers.Catalog.declares?(provider_key, type) do
          {provider_key, type, id}
        end

      assert inalcanzables == []
    end

    test "la semilla de TypeSafe cubre `decision`, que su proveedor declara" do
      assert ServiceModels.known_ids("typesafe", "decision") == ~w(jev-latest jev-1.13.0)
      assert Tokengate.Providers.Catalog.declares?("typesafe", "decision")
    end

    test "known_ids/2 vacío para un tipo o proveedor sin semilla" do
      assert ServiceModels.known_ids("alibaba", "decision") == []
      assert ServiceModels.known_ids("openai", "stt") == []
      assert ServiceModels.known_ids(nil, "stt") == []
    end

    test "provider_keys/0 lista los proveedores con semilla" do
      keys = ServiceModels.provider_keys()
      assert "alibaba" in keys
      assert "openrouter" in keys
      refute "fireworks-ai" in keys
      refute "alibaba-cn" in keys
    end
  end

  describe "descubrimiento por servicio (@discovery)" do
    test "OpenRouter publica catálogo por servicio para sus media types" do
      assert ServiceModels.discovery("openrouter", "stt") ==
               "/models?output_modalities=transcription"

      assert ServiceModels.discovery("openrouter", "tts") == "/models?output_modalities=speech"
      assert ServiceModels.discovery("openrouter", "image") == "/models?output_modalities=image"

      assert ServiceModels.discovery("openrouter", "embedding") ==
               "/models?output_modalities=embeddings"
    end

    test "un proveedor sin catálogo por servicio no tiene discovery" do
      assert ServiceModels.discovery("alibaba", "image") == nil
      assert ServiceModels.discovery("fireworks-ai", "image") == nil
      assert ServiceModels.discovery(nil, "image") == nil
    end

    test "discoverable_provider_keys/0" do
      assert ServiceModels.discoverable_provider_keys() == ["openrouter"]
    end
  end
end
