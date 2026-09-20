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
    test "the six media types are exactly the ones models.dev cannot classify" do
      assert ServiceModels.media_types() == ~w(rerank stt tts image video music)
    end

    test "media_type?/1 accepts the six and rejects the three catalog-known ones" do
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
    test "rerank" do
      assert ServiceModels.classify("alibaba", "qwen3-rerank") == "rerank"
      assert ServiceModels.classify("alibaba", "qwen3-vl-rerank") == "rerank"
    end

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

    test "video (y que NO caiga en image pese a compartir familia wan*)" do
      assert ServiceModels.classify("alibaba", "wan2.7-t2v") == "video"
      assert ServiceModels.classify("alibaba", "wan2.7-t2v-2026-04-25") == "video"
      assert ServiceModels.classify("alibaba", "wan2.2-i2v-flash") == "video"
      assert ServiceModels.classify("alibaba", "wan2.2-kf2v-flash") == "video"
      assert ServiceModels.classify("alibaba", "wan2.6-r2v") == "video"
      assert ServiceModels.classify("alibaba", "wan2.2-s2v") == "video"
      assert ServiceModels.classify("alibaba", "animate-anyone-gen2") == "video"
      assert ServiceModels.classify("alibaba", "liveportrait") == "video"
    end

    test "music (Fun-Music, sólo región CN)" do
      assert ServiceModels.classify("alibaba", "fun-music-v1") == "music"
    end

    test "an llm id is NOT classified as a service" do
      assert ServiceModels.classify("alibaba", "qwen3-max") == nil
      assert ServiceModels.classify("alibaba", "qwen3-235b-a22b") == nil
    end
  end

  describe "classify/2 — OpenRouter families" do
    test "stt / tts / rerank / music (los que no tienen endpoint de listado)" do
      assert ServiceModels.classify("openrouter", "openai/whisper-1") == "stt"
      assert ServiceModels.classify("openrouter", "openai/gpt-4o-transcribe") == "stt"
      assert ServiceModels.classify("openrouter", "microsoft/mai-transcribe-2") == "stt"
      assert ServiceModels.classify("openrouter", "openai/gpt-4o-mini-tts-2025-12-15") == "tts"
      assert ServiceModels.classify("openrouter", "microsoft/mai-voice-2") == "tts"
      assert ServiceModels.classify("openrouter", "cohere/rerank-v3.5") == "rerank"
      assert ServiceModels.classify("openrouter", "google/lyria-3-pro-preview") == "music"
    end

    test "image y video (verificados contra /images/models y /videos/models)" do
      assert ServiceModels.classify("openrouter", "qwen/qwen-image-3") == "image"
      assert ServiceModels.classify("openrouter", "black-forest-labs/flux.2-pro") == "image"
      assert ServiceModels.classify("openrouter", "openai/gpt-image-2") == "image"

      assert ServiceModels.classify("openrouter", "google/veo-3.1") == "video"
      assert ServiceModels.classify("openrouter", "openai/sora-2-pro") == "video"
      assert ServiceModels.classify("openrouter", "kwaivgi/kling-v3.0-pro") == "video"
      assert ServiceModels.classify("openrouter", "alibaba/wan-2.7") == "video"
    end

    test "flux-video-* cae en video, no en image (el orden de los patrones importa)" do
      assert ServiceModels.classify("openrouter", "black-forest-labs/flux-video-edit") == "video"
      assert ServiceModels.classify("openrouter", "black-forest-labs/flux-3-video") == "video"
    end

    test "un modelo de chat con salida de audio NO es tts (es llm)" do
      assert ServiceModels.classify("openrouter", "openai/gpt-audio") == nil
      assert ServiceModels.type_of("openrouter", "openai/gpt-audio") == "llm"
    end

    # `inkling` contiene `kling` (un generador de vídeo): sin límite por la
    # izquierda, cinco modelos de CHAT de OpenRouter aparecían en la lista de
    # vídeo del paso 3.
    test "`kling` casa como familia, no como subcadena de otro id" do
      assert ServiceModels.classify("openrouter", "kling/kling-v3") == "video"
      assert ServiceModels.classify("openrouter", "thinkingmachines/inkling") == nil
      assert ServiceModels.type_of("openrouter", "thinkingmachines/inkling") == "llm"
      assert ServiceModels.type_of("openrouter", "thinkingmachines/inkling-small:free") == "llm"
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

  describe "superficies compartidas" do
    test "alibaba-cn resuelve a la tabla de alibaba" do
      for key <- ~w(alibaba alibaba-cn) do
        assert ServiceModels.classify(key, "qwen3-rerank") == "rerank"
        assert ServiceModels.classify(key, "wan2.7-t2v") == "video"
        assert ServiceModels.known_ids(key, "stt") == ServiceModels.known_ids("alibaba", "stt")
      end
    end
  end

  describe "type_of/2" do
    test "el patrón del proveedor gana sobre el hint del id" do
      # "wan2.7-t2v" no lleva señal en el id — sólo la familia lo clasifica.
      assert ServiceModels.type_of("alibaba", "wan2.7-t2v") == "video"
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
      assert {"alibaba", "qwen3-rerank"} in ServiceModels.seed_models_of_type("rerank")

      assert {"fireworks-ai", "accounts/fireworks/models/qwen3-reranker-8b"} in ServiceModels.seed_models_of_type(
               "rerank"
             )

      assert {"openrouter", "google/lyria-3-pro-preview"} in ServiceModels.seed_models_of_type(
               "music"
             )
    end

    # Fun-Music NO se siembra para DashScope: su host es POR WORKSPACE
    # (`{WorkspaceId}.cn-beijing.maas.aliyuncs.com`), sólo región CN, y su body es
    # nativo — ninguna fila de la semilla puede apuntarlo hoy. CLASIFICAR sí se
    # clasifica si alguien lo escribe, que es una decisión distinta de ofrecerlo.
    test "fun-music no se ofrece en DashScope pero sí se clasifica" do
      for key <- ~w(alibaba alibaba-cn) do
        assert ServiceModels.known_ids(key, "music") == []
        assert ServiceModels.classify(key, "fun-music-v1") == "music"
      end
    end

    # Invariante que ata la semilla con el paso 1 del wizard: cada fila tiene que
    # estar en un proveedor que DECLARE ese tipo. Si no, es INALCANZABLE — el paso
    # 1 filtra por capability, así que el proveedor no aparece para ese tipo y el
    # id sembrado jamás se ofrece. Este invariante cazó dos filas muertas:
    # `cohere/rerank-v3.5` (openrouter no declaraba `rerank`) y `fun-music-v1`.
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
      assert ServiceModels.known_ids("alibaba", "music") == []
      assert ServiceModels.known_ids("openai", "stt") == []
      assert ServiceModels.known_ids(nil, "stt") == []
    end

    test "provider_keys/0 lista los proveedores con semilla" do
      keys = ServiceModels.provider_keys()
      assert "alibaba" in keys
      assert "fireworks-ai" in keys
      assert "openrouter" in keys
      refute "alibaba-cn" in keys
    end
  end

  describe "descubrimiento por servicio (@discovery)" do
    test "OpenRouter publica catálogo por servicio para todo menos music" do
      assert ServiceModels.discovery("openrouter", "stt") ==
               "/models?output_modalities=transcription"

      assert ServiceModels.discovery("openrouter", "tts") == "/models?output_modalities=speech"
      assert ServiceModels.discovery("openrouter", "rerank") == "/models?output_modalities=rerank"
      assert ServiceModels.discovery("openrouter", "image") == "/models?output_modalities=image"
      assert ServiceModels.discovery("openrouter", "video") == "/models?output_modalities=video"

      assert ServiceModels.discovery("openrouter", "embedding") ==
               "/models?output_modalities=embeddings"

      # `music` no tiene valor propio: `output_modalities=audio` mezcla los Lyria
      # con `gpt-audio`, que es un chat con salida de audio. Va sólo por semilla.
      assert ServiceModels.discovery("openrouter", "music") == nil
    end

    test "un proveedor sin catálogo por servicio no tiene discovery" do
      assert ServiceModels.discovery("alibaba", "image") == nil
      assert ServiceModels.discovery("fireworks-ai", "rerank") == nil
      assert ServiceModels.discovery(nil, "image") == nil
    end

    test "discoverable_provider_keys/0" do
      assert ServiceModels.discoverable_provider_keys() == ["openrouter"]
    end
  end
end
