defmodule Tokengate.Providers.ServiceModels do
  @moduledoc """
  De qué TIPO es un modelo de un proveedor — en código, no en models.dev.

  ## Por qué existe

  `models.dev` sólo publica la mitad de la superficie del gateway: sus ids son
  de chat, embeddings o, en el caso de TypeSafe, decisiones. Los **seis
  servicios de media** (`rerank`, `stt`, `tts`, `image`, `video`, `music`) no
  existen ahí, así que el único marcado que había —`ModelIds.model_type_hint/1`,
  un regex sobre el id— no puede clasificarlos: un `wan2.7-t2v` o un
  `google/lyria-3-pro-preview` caen todos a `"llm"`.

  Este módulo es la mitad que falta. Es DATA code-owned, como
  `Catalog.@code_providers` o `ModelIds.@code_models`: viaja con el release,
  no es una fila que el operador edite.

  ## Por qué PATRONES y no una lista exhaustiva

  Una lista de ids envejece mal: los proveedores publican variantes con fecha
  (`wan2.7-t2v-2026-04-25`, `qwen3-tts-flash-2025-11-27`) y dejan fuera ids que
  sí existen. Una lista incompleta clasifica mal en silencio, que es peor que no
  clasificar.

  Lo que sí es estable es la **familia** del id, y las familias están
  verificadas contra la documentación de cada proveedor (ver `@patterns`). Por
  eso el marcado es un patrón ordenado por proveedor —mismo criterio que
  `ModelIds.model_type_hint/1`, que ya clasifica por regex— y el operador
  confirma el tipo en el formulario, igual que hace hoy con llm/embedding.

  ## Tres fuentes, en este orden

    1. `@patterns` — la familia del id (los seis servicios).
    2. `ModelIds.model_type_hint/1` — el hint de models.dev
       (`embedding`, `decision`, `llm`).
    3. `@discovery` — un proveedor que publica un catálogo POR SERVICIO
       (`{base}/images/models`) se lista en vivo desde ahí; es la fuente más
       fiable cuando existe.

  `@known_ids` es sólo la semilla verificada (los ids que la doc del proveedor
  confirma literalmente): sirve para poblar el selector cuando no hay catálogo
  en vivo, nunca como vocabulario cerrado.

  ## Superficies compartidas

  Varios `provider_key` hablan la MISMA superficie y sirven los MISMOS ids,
  cambiando sólo host y API keys: `alibaba` y `alibaba-cn` (DashScope intl/cn).
  Se declaran una vez bajo `alibaba` y se resuelven por alias
  (`@shared_surfaces`), en vez de duplicar la tabla.
  """

  alias Tokengate.Providers.ModelIds

  @media_types ~w(rerank stt tts image video music)

  @shared_surfaces %{
    "alibaba-cn" => "alibaba"
  }

  # Patrones ordenados por proveedor: el PRIMERO que casa gana. El orden importa
  # dentro de cada lista.
  #
  # Familia                  Fuente verificada
  # -----------------------  -----------------------------------------------
  # qwen3-rerank             help/en/model-studio/text-rerank-api
  # qwen3-asr-*, fun-asr*,   help/en/model-studio/asr-model
  #   qwen-audio-*-asr-*,
  #   paraformer-*
  # qwen3-tts-*, qwen-tts*,  help/en/model-studio/tts-model
  #   qwen-audio-*-tts-*,
  #   cosyvoice-*
  # qwen-image-*, wan*-t2i/  help/en/model-studio/image-model
  #   i2i, *-imageedit
  # wan*-t2v/i2v/kf2v/r2v/   help/en/model-studio/use-video-generation
  #   s2v, animate-anyone-*,
  #   liveportrait, videoretalk,
  #   emo-*, emoji-*
  # fun-music-*              help/en/model-studio/fun-music (sólo región CN)
  @patterns %{
    "alibaba" => [
      {~r/rerank/i, "rerank"},
      {~r/asr|paraformer/i, "stt"},
      {~r/tts|cosyvoice/i, "tts"},
      {~r/image|t2i|i2i/i, "image"},
      {~r/t2v|i2v|kf2v|r2v|s2v|vace|videoedit|animate-anyone|liveportrait|videoretalk|emo-|emoji/i,
       "video"},
      {~r/music/i, "music"}
    ],
    # Fireworks sirve rerank en su superficie OpenAI-compatible (`{base}/rerank`).
    "fireworks-ai" => [
      {~r/rerank/i, "rerank"}
    ],
    # OpenRouter expone cada servicio de media con su propia superficie:
    #   * image  → POST /api/v1/images/generations   (descubrible: /images/models)
    #   * video  → POST /api/v1/videos               (descubrible: /videos/models)
    #   * stt    → POST /api/v1/audio/transcriptions (SIN endpoint de listado)
    #   * tts    → POST /api/v1/audio/speech         (SIN endpoint de listado)
    #   * music  → por chat con output audio         (2 modelos: google/lyria-*)
    #   * rerank → POST /api/v1/rerank               (SIN endpoint de listado)
    # Verificado contra /api/v1/models (446 filas): NINGÚN modelo de chat lleva
    # "image" en el id fuera del set de generación, así que ese patrón es seguro;
    # y `gpt-audio` (chat con salida de audio) NO casa con `tts|speech|voice|
    # kokoro` a propósito — es un llm, no el endpoint de voz.
    #
    # ORDEN: video ANTES que image, porque `flux-video-edit`/`flux-3-video`
    # llevan "flux" y caerían en image si image fuera primero.
    "openrouter" => [
      {~r{^google/lyria}i, "music"},
      {~r/rerank/i, "rerank"},
      {~r/whisper|transcribe|deepgram\/nova|chirp/i, "stt"},
      {~r/kokoro|tts|speech|voice/i, "tts"},
      {~r{veo|sora|kling|seedance|hailuo|runway|aleph|grok-imagine-video|happyhorse|heygen|wan-|flux-.*video}i,
       "video"},
      {~r/image|flux|seedream|recraft|krea|mai-image|muse-image/i, "image"}
    ]
  }

  # Catálogos POR SERVICIO que el proveedor publica y el gateway puede listar en
  # vivo: `{base_url}{endpoint}` → `[model_id]`. Es la fuente autoritativa cuando
  # existe (mejor que cualquier semilla).
  #
  # OpenRouter expone cada servicio con SU propia consulta sobre `/models`
  # (`?output_modalities=`), verificado: transcription 21, speech 18, rerank 7,
  # image 54, video 29, embeddings 37. `music` es la excepción: no tiene valor
  # propio (`output_modalities=audio` mezcla los Lyria con `gpt-audio`, que es un
  # chat) y `/music/models` responde 404 — así que music va sólo por semilla.
  #
  # Un proveedor sin entrada aquí (Alibaba/DashScope, que no publica catálogo por
  # servicio) se apoya en la semilla + el texto libre del paso 2.
  @discovery %{
    "openrouter" => %{
      "stt" => "/models?output_modalities=transcription",
      "tts" => "/models?output_modalities=speech",
      "rerank" => "/models?output_modalities=rerank",
      "image" => "/models?output_modalities=image",
      "video" => "/models?output_modalities=video",
      "embedding" => "/models?output_modalities=embeddings"
    }
  }

  # Semilla verificada: ids que la documentación del proveedor (o su API) confirma
  # LITERALMENTE. No es el vocabulario — es lo que se ofrece cuando el proveedor
  # no publica catálogo en vivo.
  #
  # Fuentes, por bloque:
  #   * alibaba  → help/en/model-studio/{text-rerank-api, asr-model, tts-model,
  #                image-model, use-video-generation, fun-music}. Sólo las formas
  #                CANÓNICAS: las variantes con fecha (`…-2025-11-27`) se omiten
  #                a propósito, son ruido en un selector.
  #   * openrouter → docs/guides/overview/multimodal/{stt,tts} y la referencia de
  #                `/rerank`. Es un FALLBACK: stt/tts/image/video/rerank/embedding
  #                se descubren en vivo (`@discovery`); sólo `music` depende de
  #                la semilla.
  @known_ids %{
    "alibaba" => %{
      "rerank" => ~w(qwen3-rerank qwen3-vl-rerank),
      "stt" => ~w(qwen3-asr-flash qwen3-asr-flash-realtime qwen3-asr-flash-filetrans
           qwen-audio-3.0-asr-flash qwen-audio-3.0-asr-flash-filetrans
           qwen-audio-3.0-asr-flash-streaming
           paraformer-v2 paraformer-realtime-v2 paraformer-mtl-v1
           fun-asr fun-asr-mtl fun-asr-realtime fun-asr-mtl-realtime
           fun-asr-flash-8k-realtime),
      "tts" => ~w(qwen3-tts qwen3-tts-flash qwen3-tts-flash-realtime qwen3-tts-instruct-flash
           qwen3-tts-instruct-flash-realtime qwen3-tts-vc qwen3-tts-vd
           qwen-tts qwen-tts-realtime qwen-audio-3.0-tts-flash qwen-audio-3.0-tts-plus
           cosyvoice-v2 cosyvoice-v3-flash cosyvoice-v3-plus
           cosyvoice-v3.5-flash cosyvoice-v3.5-plus),
      "image" => ~w(qwen-image qwen-image-2.0 qwen-image-2.0-pro qwen-image-3.0 qwen-image-3.0-pro
           qwen-image-max qwen-image-plus qwen-image-edit qwen-image-edit-max
           qwen-image-edit-plus
           wan2.7-image wan2.7-image-pro wan2.6-image wan2.6-t2i
           wan2.5-t2i-preview wan2.5-i2i-preview wan2.2-t2i-plus wan2.2-t2i-flash
           wan2.1-t2i-plus wan2.1-t2i-turbo wanx2.1-imageedit z-image-turbo),
      "video" => ~w(wan2.7-t2v wan2.7-i2v wan2.7-r2v wan2.7-videoedit
           wan2.6-t2v wan2.6-i2v wan2.6-i2v-flash wan2.6-r2v wan2.6-r2v-flash
           wan2.5-t2v-preview wan2.5-i2v-preview
           wan2.2-t2v-plus wan2.2-i2v-plus wan2.2-i2v-flash wan2.2-kf2v-flash wan2.2-s2v
           wan2.1-t2v-plus wan2.1-t2v-turbo wan2.1-i2v-plus wan2.1-i2v-turbo
           wan2.1-kf2v-plus wan2.1-vace-plus
           wanx2.1-t2v-plus wanx2.1-t2v-turbo wanx2.1-i2v-plus wanx2.1-i2v-turbo
           wanx2.1-kf2v-plus wanx2.1-vace-plus
           animate-anyone-gen2 liveportrait videoretalk emo-v1 emoji-v1)
      # NO hay entrada de `music`: Fun-Music (`fun-music-v1`) existe en DashScope
      # pero NO es enrutable por este camino — vive en un host POR WORKSPACE
      # (`{WorkspaceId}.cn-beijing.maas.aliyuncs.com`), sólo región CN, y su body
      # es nativo (`{"model", "input": {"prompt"|"lyrics", "gender"}}`), no
      # OpenAI. Sembrarlo ofrecería un id que ningún proveedor declarado puede
      # servir. Para habilitarlo hacen falta las TRES piezas: la capability
      # `music` en `alibaba-cn`, el path del operador (su workspace) en
      # `path_overrides`, y la traducción request/response en el adapter.
    },
    "fireworks-ai" => %{
      "rerank" => ~w(accounts/fireworks/models/qwen3-reranker-8b)
    },
    "openrouter" => %{
      "music" => ~w(google/lyria-3-pro-preview google/lyria-3-clip-preview),
      "stt" => ~w(openai/whisper-1 openai/gpt-4o-transcribe),
      "tts" => ~w(openai/gpt-4o-mini-tts-2025-12-15 microsoft/mai-voice-2),
      "image" => ~w(openai/gpt-image-2 black-forest-labs/flux.2-pro),
      "video" => ~w(google/veo-3.1 openai/sora-2-pro),
      "rerank" => ~w(cohere/rerank-v3.5)
    }
  }

  @doc "Los seis tipos de servicio que models.dev no publica."
  @spec media_types() :: [String.t()]
  def media_types, do: @media_types

  @doc "True when `type` is one of the six media services."
  @spec media_type?(String.t() | nil) :: boolean()
  def media_type?(type), do: type in @media_types

  @doc """
  El tipo de un modelo de un proveedor.

  Patrón del proveedor primero (los seis servicios), luego el hint de models.dev
  (`embedding`, `decision`, `llm`).

      iex> Tokengate.Providers.ServiceModels.type_of("alibaba", "wan2.7-t2v")
      "video"

      iex> Tokengate.Providers.ServiceModels.type_of("openrouter", "google/lyria-3-pro-preview")
      "music"

      iex> Tokengate.Providers.ServiceModels.type_of("openai", "google/gemini-embedding-001")
      "embedding"

      iex> Tokengate.Providers.ServiceModels.type_of("openrouter", "anthropic/claude-opus-4.7")
      "llm"
  """
  @spec type_of(String.t() | nil, String.t() | nil) :: String.t()
  def type_of(provider_key, model_id) do
    case classify(provider_key, model_id) do
      nil -> ModelIds.model_type_hint(model_id)
      type -> type
    end
  end

  @doc """
  El tipo que la FAMILIA del id declara para ese proveedor, o `nil` cuando
  ningún patrón casa (el caller cae entonces al hint de models.dev).

      iex> Tokengate.Providers.ServiceModels.classify("alibaba", "qwen3-tts-flash-2025-11-27")
      "tts"

      iex> Tokengate.Providers.ServiceModels.classify("alibaba", "qwen3-max")
      nil
  """
  @spec classify(String.t() | nil, String.t() | nil) :: String.t() | nil
  def classify(provider_key, model_id) when is_binary(model_id) do
    provider_key
    |> patterns_for()
    |> List.wrap()
    |> Enum.find_value(fn {regex, type} ->
      if Regex.match?(regex, model_id), do: type
    end)
  end

  def classify(_provider_key, _model_id), do: nil

  @doc """
  The per-service model-listing endpoint of a provider, or `nil` when it does
  not publish one: `"/images/models"` for OpenRouter images.

  The caller prefixes the provider's `base_url`. A provider with an entry here
  can be listed LIVE for that type, which beats any curated seed.
  """
  @spec discovery(String.t() | nil, String.t()) :: String.t() | nil
  def discovery(provider_key, type) do
    case Map.get(@discovery, surface(provider_key)) do
      %{} = services -> Map.get(services, type)
      _ -> nil
    end
  end

  @doc """
  The verified seed ids of one type for one provider (empty when none).

  Seeds the picker when there is no live catalogue; never a closed vocabulary.
  Un `provider_key` de `@shared_surfaces` resuelve a la tabla que comparte:
  `alibaba-cn` lee la de `alibaba` (misma superficie DashScope, distinto host y
  claves).
  """
  @spec known_ids(String.t() | nil, String.t()) :: [String.t()]
  def known_ids(provider_key, type) when is_binary(type) do
    case Map.get(@known_ids, surface(provider_key)) do
      %{} = by_type -> Map.get(by_type, type, [])
      _ -> []
    end
  end

  def known_ids(_provider_key, _type), do: []

  @doc """
  Every verified seed id of one type across providers, as
  `[{provider_key, model_id}]`.
  """
  @spec seed_models_of_type(String.t()) :: [{String.t(), String.t()}]
  def seed_models_of_type(type) do
    @known_ids
    |> Enum.flat_map(fn {provider_key, by_type} ->
      by_type |> Map.get(type, []) |> Enum.map(&{provider_key, &1})
    end)
    |> Enum.sort()
  end

  @doc "Provider keys the curated seed knows, sorted."
  @spec provider_keys() :: [String.t()]
  def provider_keys, do: @known_ids |> Map.keys() |> Enum.sort()

  @doc "Provider keys that publish a per-service catalogue the gateway can list."
  @spec discoverable_provider_keys() :: [String.t()]
  def discoverable_provider_keys, do: @discovery |> Map.keys() |> Enum.sort()

  @doc "The alias map (extra provider keys that share another's surface)."
  @spec shared_surfaces() :: %{String.t() => String.t()}
  def shared_surfaces, do: @shared_surfaces

  # La clave de superficie: un alias resuelve a la tabla que comparte.
  defp surface(provider_key) when is_binary(provider_key) do
    Map.get(@shared_surfaces, provider_key, provider_key)
  end

  defp surface(_provider_key), do: nil

  defp patterns_for(provider_key), do: Map.get(@patterns, surface(provider_key))
end
