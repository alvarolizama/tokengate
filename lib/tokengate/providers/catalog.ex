defmodule Tokengate.Providers.Catalog do
  @moduledoc """
  The provider catalog: remote identity from models.dev + code customizations.

  ## Two halves, on purpose

    * **Remote (data)** — every provider models.dev publishes: id, name, base
      URL, doc URL, logo URL, env var and npm package. Lives in the
      `catalog_providers` table (seeded from the vendored snapshot in
      `priv/models_dev/providers.json` at first boot, refreshed asynchronously
      by `CatalogRefreshWorker`). Nothing here is hand-maintained.
    * **Code (customizations)** — the properties models.dev does NOT publish
      and the gateway needs anyway: `capabilities`, `dialect`, per-service
      `paths`, and the per-upstream quirks (a strict body validator, an
      exotic path). They live in `@customizations`, keyed by models.dev id, and
      are applied at READ time.

  There is a third case, and it is not a half: a provider models.dev does not
  publish AT ALL (TypeSafe). It has no remote row to complete — the
  way Cerebras, which models.dev lists with `base_url: null`, does — so its
  WHOLE row lives in `@code_providers` and `CatalogSync.ensure_code_providers/0`
  upserts it into the mirror on every boot. `CatalogRefreshWorker` never sweeps
  those keys to `stale` (`code_provider_keys/0`): they are not data that
  disappeared upstream, they are data upstream never had.

  That split is what makes a refresh safe: the worker only writes remote rows,
  so a new provider or a moved base URL lands without a redeploy, while
  nothing it does can touch a customization.

  Unsupported providers never enter the add-provider picker (`providers_live`
  filters with `supported?/1` before listing) — `unsupported_reason/1` remains
  the shared definition of "cannot be served" (no base URL, templated URL,
  no OpenAI-compatible dialect) and is what keeps such rows out of the
  boot-time materialization too.

  ## Dialects

    * `"openai"` — OpenAI-compatible: chat at `{base}/chat/completions`,
      models at `{base}/models`, embeddings at `{base}/embeddings`.
    * `"openrouter"` — same surface, but embedding models are listed at
      `{base}/embeddings/models`.

  A provider is usable when it has a base URL and its npm package maps to a
  dialect. **models.dev's npm field is not a capability statement**: it says
  which client library reaches the provider, not which endpoints exist.

  ## Capabilities

  `#{inspect(~w(llm embedding stt tts image))}` — what a provider
  can serve, declared per provider IN CODE. models.dev has no field for it: an
  embedding model and a chat model both report
  `modalities: %{input: ["text"], output: ["text"]}` and only `family` or the
  model id hints at the difference. A provider with no entry here is treated
  as chat — add the capabilities the day a real case needs them.

  The vocabulary here is what a provider may DECLARE. What the proxy routes is
  `/v1/chat/completions`, `/v1/models`, `/v1/embeddings` and the three
  path-routed services (`stt`, `tts`, `image` — see `ProviderPaths`); a
  model's `model_type` IS the routing capability for those.

  ## Custom provider capabilities

  A custom has no models.dev entry to derive from, so its capabilities come
  from the form (the operator picks what that relay serves).

  ## Paths

  Every service lives at `base_url` + a path. The path resolves in three
  tiers, highest first: the provider's own `path_overrides` (set from the
  Capacidades modal), the `:paths` entry here (a builtin whose service does
  not live where the generic surface says), and the generic
  OpenAI-compatible default — see `Tokengate.Providers.ProviderPaths`.
  """

  @dialects ~w(openai openrouter dashscope typesafe)
  @sources ~w(builtin custom)

  # What a provider can serve. Declared in code, per provider (@customizations).
  @capabilities ~w(llm embedding decision stt tts image)

  # models.dev npm package -> dialect. Anything absent is unsupported until a
  # dialect (a thin adapter) exists for it.
  @dialect_by_npm %{
    "@ai-sdk/openai-compatible" => "openai",
    "@ai-sdk/openai" => "openai",
    "@ai-sdk/cerebras" => "openai",
    "@openrouter/ai-sdk-provider" => "openrouter"
  }

  # Hints attached to the body: NONE. The gateway used to attach
  # `prompt_cache_key` (OpenAI's prompt-cache routing convention) to every
  # chat body, but strict upstreams (Fireworks) answer 400 on undocumented
  # body fields, so the gateway attaches nothing now — cache affinity lives
  # in the `x-session-affinity` / `x-session-id` HEADERs only, and the
  # implicit upstream prefix cache is content-keyed anyway.

  # ---------------------------------------------------------------------------
  # Code customizations, by models.dev id.
  #
  # Recognised keys, all optional:
  #   * :capabilities         — what the provider serves (see @capabilities)
  #   * :dialect              — only when npm would resolve it wrong
  #   * :base_url             — only when models.dev's URL is wrong for us
  #   * :paths                — per-service path suffix overrides, e.g.
  #                             %{embeddings: "/embed"}; the atom keys are the
  #                             vocabulary in `ProviderPaths` and only apply
  #                             when the provider has no operator override
  #   * :decisions_shape      — the wire of the decisions surface:
  #                             :openai (passthrough, default) | :systemone
  #                             (the request translates) — see
  #                             `decisions_shape/1` and `Proxy.Decisions`
  #   * :omit_body_fields     — fields the gateway must STRIP from the body
  #   * :reasoning_dialect    — how the upstream wants its reasoning knobs on
  #                             the wire, one of @reasoning_dialects: the
  #                             pre-flight pipeline reshapes whatever form the
  #                             CLIENT sent into the dialect of the upstream
  #                             that serves the request (the client cannot
  #                             know which provider a request lands on)
  # ---------------------------------------------------------------------------
  # The reasoning wire dialects an upstream can speak. The pre-flight
  # pipeline reads the client's reasoning knobs (nested `reasoning` object,
  # scalar `reasoning_effort`, Moonshot-style `thinking` toggle — in any
  # combination) and reshapes them into the ONE form the serving upstream
  # documents. Mirrors the Hermes provider profiles (plugins/
  # model-providers/*), so the mapping is battle-tested against each vendor's
  # live API quirks:
  #
  #   * :scalar             — top-level `reasoning_effort` string only
  #                           (Fireworks, DeepInfra: rejects the nested form)
  #   * :toggle_xor_effort  — `thinking` toggle XOR `reasoning_effort`: both
  #                           at once is a 400 (Moonshot/Kimi)
  #   * :toggle_and_effort  — `thinking` toggle + `reasoning_effort`
  #                           coexisting (Z.AI/GLM 5.2)
  #   * :openrouter_nested  — nested `reasoning: {effort, enabled}` object
  #                           (OpenRouter; DeepSeek v4 native shares the
  #                           toggle habit but speaks the object form too)
  #   * :deepseek_native    — `thinking: {type}` toggle always emitted +
  #                           scalar effort (DeepSeek v4+: omitted toggle
  #                           defaults thinking ON and then demands
  #                           reasoning_content echoes)
  #   * :passthrough        — the upstream documents no reasoning knobs we
  #                           reshape (Qwen/Alibaba DashScope)
  @reasoning_dialects [
    :scalar,
    :toggle_xor_effort,
    :toggle_and_effort,
    :openrouter_nested,
    :deepseek_native,
    :passthrough
  ]

  @customizations %{
    # OpenRouter expone TODO en su superficie OpenAI-compatible bajo /api/v1:
    #   * chat/models/embeddings — defaults genéricos (embeddings models se
    #     listan en /embeddings/models, ver el adaptador).
    #   * stt `/audio/transcriptions` y tts `/audio/speech` — defaults exactos.
    #   * image en `/images` (NO /images/generations).
    #   * decisiones: su endpoint alpha NO vive bajo /api/v1 → URL absoluta.
    #     Habla el envelope System One (sirve Jev/Clef), así que la superficie
    #     pública /v1/decisions del gateway pasa por el traductor.
    "openrouter" => %{
      capabilities: ~w(llm embedding stt tts image decision),
      dialect: "openrouter",
      paths: %{image: "/images", decisions: "https://openrouter.ai/api/alpha/decisions"},
      decisions_shape: :systemone,
      reasoning_dialect: :openrouter_nested
    },
    # Fireworks: decisions en shape OpenAI nativo (`POST
    # /inference/v1/decisions`, y el mismo contenido en /systemone) — la
    # superficie pública pasa verbatim. Su modelo público `rune` sólo sirve
    # esta API: chat contra él responde 400.
    "fireworks-ai" => %{
      capabilities: ~w(llm embedding decision),
      decisions_shape: :openai,
      reasoning_dialect: :scalar
    },
    # DashScope (Model Studio) expone dos superficies:
    #   * compatible-mode/v1 — chat, models, embeddings y, desde qwen-image,
    #     /images/generations YA OpenAI-compatible (response con data[].url);
    #     todo calza con los defaults genéricos.
    #   * servicios NATIVOS (stt, tts) bajo /api/v1 — los traduce el adapter
    #     dashscope (ver DashScopeAdapter). intl y cn difieren en el host.
    "alibaba" => %{
      capabilities: ~w(llm embedding image stt tts),
      dialect: "dashscope"
    },
    "alibaba-cn" => %{
      capabilities: ~w(llm embedding image stt tts),
      dialect: "dashscope"
    },
    "alibaba-token-plan" => %{capabilities: ~w(llm)},
    "alibaba-token-plan-cn" => %{capabilities: ~w(llm)},
    "opencode" => %{capabilities: ~w(llm)},
    "opencode-go" => %{capabilities: ~w(llm)},
    # Moonshot/Kimi: `thinking` y `reasoning_effort` son MUTUAMENTE
    # EXCLUSIVOS en su wire (400 con ambos, ver profile kimi-coding de
    # Hermes): effort gana cuando viene, si no el toggle.
    "moonshotai" => %{capabilities: ~w(llm), reasoning_dialect: :toggle_xor_effort},
    # Kimi coding plan: models.dev partió la fila `kimi-for-coding` en dos
    # regiones (cn/global, misma base y mismo wire). Llega con npm
    # @ai-sdk/openai-compatible (dialecto openai ya resuelto); lo que la
    # customización aporta es el dialecto de reasoning: el toggle y el
    # escalar son MUTUAMENTE EXCLUSIVOS (400 con ambos, profile kimi-coding
    # de Hermes). La key retirada ya no se declara: el refresh la marca
    # stale y una instancia nueva no puede añadirla.
    "kimi-code-plan-cn" => %{capabilities: ~w(llm), reasoning_dialect: :toggle_xor_effort},
    "kimi-code-plan-global" => %{capabilities: ~w(llm), reasoning_dialect: :toggle_xor_effort},
    # OpenAI: models.dev no publica su base URL (como Cerebras, va en código).
    # Capabilities de la auditoría 2026-11-08: los tipos que models.dev publica
    # (embedding, image) más stt/tts — sus endpoints /audio/* SON los defaults
    # genéricos del gateway — y decisions (shape propio, GA con gpt-6-luna).
    "openai" => %{
      capabilities: ~w(llm embedding image stt tts decision),
      base_url: "https://api.openai.com/v1"
    },
    # Los demás grandes sin base_url en models.dev: igual que Cerebras, el
    # endpoint es OpenAI-compatible y ambos datos van en código. Mistral sirve
    # embeddings y transcripción (Voxtral); xAI imágenes (grok-image); el AI
    # Gateway de Vercel todo — incluido decisions en shape OpenAI.
    "mistral" => %{
      capabilities: ~w(llm embedding stt),
      dialect: "openai",
      base_url: "https://api.mistral.ai/v1"
    },
    "xai" => %{
      capabilities: ~w(llm image),
      dialect: "openai",
      base_url: "https://api.x.ai/v1"
    },
    "vercel" => %{
      capabilities: ~w(llm embedding image stt tts decision),
      dialect: "openai",
      base_url: "https://ai-gateway.vercel.sh/v1"
    },
    # Z.AI/GLM 5.2: el toggle `thinking` y el escalar `reasoning_effort`
    # COEXISTEN en su wire (profile zai de Hermes).
    "zai" => %{capabilities: ~w(llm), reasoning_dialect: :toggle_and_effort},
    "zai-coding-plan" => %{capabilities: ~w(llm), reasoning_dialect: :toggle_and_effort},
    # DeepSeek v4+ nativo: el toggle `thinking` debe ir SIEMPRE explícito —
    # omitido, el server prende thinking por default y después EXIGE el echo
    # de `reasoning_content` en los turnos de tool-call (profile deepseek de
    # Hermes). Entry solo de dialecto: el resto de la fila es de models.dev.
    "deepseek" => %{reasoning_dialect: :deepseek_native},
    # models.dev no publica base URL para Cerebras y resuelve su dialecto por
    # el SDK (`@ai-sdk/cerebras`), que no está en la tabla npm→dialecto. El
    # endpoint sí es OpenAI-compatible, así que ambos datos van en código.
    "cerebras" => %{
      capabilities: ~w(llm),
      dialect: "openai",
      base_url: "https://api.cerebras.ai/v1"
    },
    # Proveedores soportados cuyo espejo publica modelos tipados (auditoría
    # 2026-11-08 sobre models.dev: `type` por modelo → embedding/image/stt/
    # tts). El chat es el default de todo proveedor y va declarado siempre;
    # los quirks de path que tenga cada uno se resuelven desde el modal
    # Capacidades (override del operador), no aquí.
    "302ai" => %{capabilities: ~w(llm image)},
    "abacus" => %{capabilities: ~w(llm image)},
    "aimlapi" => %{capabilities: ~w(llm image)},
    "digitalocean" => %{capabilities: ~w(llm embedding image tts)},
    "edenai" => %{capabilities: ~w(llm image)},
    "evroc" => %{capabilities: ~w(llm embedding stt)},
    "fastrouter" => %{capabilities: ~w(llm image)},
    "greenpt" => %{capabilities: ~w(llm stt)},
    "huggingface" => %{capabilities: ~w(llm embedding)},
    "inference" => %{capabilities: ~w(llm embedding)},
    "inferx" => %{capabilities: ~w(llm embedding)},
    "infomaniak" => %{capabilities: ~w(llm embedding)},
    "kenari" => %{capabilities: ~w(llm image stt tts)},
    "kilo" => %{capabilities: ~w(llm image)},
    "llmgateway" => %{capabilities: ~w(llm stt)},
    "llmgateway-providers" => %{capabilities: ~w(llm stt)},
    "nan" => %{capabilities: ~w(llm image)},
    "nearai" => %{capabilities: ~w(llm embedding image stt)},
    "nebius" => %{capabilities: ~w(llm embedding)},
    "novita-ai" => %{capabilities: ~w(llm embedding)},
    "nvidia" => %{capabilities: ~w(llm embedding image stt tts)},
    "poe" => %{capabilities: ~w(llm image tts)},
    "privatemode-ai" => %{capabilities: ~w(llm embedding stt)},
    "qiniu-ai" => %{capabilities: ~w(llm image)},
    "regolo-ai" => %{capabilities: ~w(llm embedding image stt)},
    "requesty" => %{capabilities: ~w(llm image)},
    "scaleway" => %{capabilities: ~w(llm embedding stt)},
    "stackit" => %{capabilities: ~w(llm embedding)},
    "stepfun" => %{capabilities: ~w(llm stt tts)},
    "stepfun-ai" => %{capabilities: ~w(llm stt tts)},
    "tempr" => %{capabilities: ~w(llm embedding)},
    "xiaomi-token-plan-ams" => %{capabilities: ~w(llm tts)},
    "xiaomi-token-plan-cn" => %{capabilities: ~w(llm tts)},
    "xiaomi-token-plan-sgp" => %{capabilities: ~w(llm tts)},
    "zenmux" => %{capabilities: ~w(llm image stt tts)},
    # TypeSafe (typesafe.ai): Jev, el primer modelo System One — decisiones
    # tipadas con probabilidades calibradas en vez de texto generado. Su API
    # NO es OpenAI-compatible: `POST /v1/systemone` con {state, model,
    # questions} → {answers, usage}; la superficie pública /v1/decisions pasa
    # por el traductor (DecisionsTranslator) hacia este envelope. Cobro por
    # input token ($0.042/Mtok, output gratis); no reporta costo — el precio
    # manual del model_provider es el fallback. models.dev no lo publica.
    "typesafe" => %{
      capabilities: ~w(decision),
      dialect: "typesafe",
      paths: %{chat: "/systemone", decisions: "/systemone"},
      decisions_shape: :systemone
    }
  }

  # Proveedores cuya fila ENTERA vive en código porque models.dev no los
  # publica. `CatalogSync.ensure_code_providers/0` las upserta en
  # `catalog_providers` en cada arranque y `CatalogRefreshWorker` nunca las
  # marca `stale` (ver `code_provider_keys/0`).
  #
  # Por qué en código y no en el snapshot: `CatalogSeed.seed_if_empty/0` solo
  # siembra con la tabla VACÍA, así que meter la fila en
  # `priv/models_dev/providers.json` no haría nada en una instancia ya viva —y
  # ese archivo se lee en tiempo de COMPILACIÓN, o sea que queda horneado en la
  # imagen de release y una edición a mano se separa del código.
  #
  # Campos: los mismos que `normalize_providers/1` emite, en el shape que
  # `CatalogProvider` almacena. `env` y `npm` son informativos.
  #
  # Por qué Qwen Cloud NO está aquí: es la marca y el portal de la MISMA
  # infraestructura DashScope internacional que `alibaba` — los ejemplos del
  # propio Qwen usan `DASHSCOPE_API_KEY` contra el mismo host `dashscope-intl`, y
  # una key sacada de su consola es una key DashScope de ese host. Declararla
  # aparte duplicaba los siete servicios sin servir nada distinto, así que una
  # key de Qwen Cloud se agrega como credencial de `alibaba`. La fila que ya
  # existía en instancias vivas la retira la migración `RemoveQwenCloudProvider`.
  @code_providers %{
    # TypeSafe (typesafe.ai): docs.typesafe.ai. La superficie es
    # api.typesafe.ai/v1 con Bearer; el endpoint de evaluación es
    # /v1/systemone (path override del dialecto) y /v1/models lista aliases.
    #
    # `logo_url` es nil A PROPÓSITO (verificado 2026-09-18): el sitio es Framer y
    # no expone favicon ni marca usable — `typesafe.ai/favicon.ico`,
    # `www.typesafe.ai/favicon.ico`, `typesafe.ai/favicon.svg` y
    # `api.typesafe.ai/favicon.ico` responden los cuatro **404**. Un URL muerto
    # deja el hueco vacío (el icono genérico sólo entra con nil), así que aquí la
    # decisión correcta es NO declarar logo y dejar que se pinte
    # `hero-server-stack`.
    "typesafe" => %{
      name: "TypeSafe",
      base_url: "https://api.typesafe.ai/v1",
      doc_url: "https://docs.typesafe.ai",
      logo_url: nil,
      env: ["TYPESAFE_API_KEY"],
      npm: nil
    }
  }

  # Vendored snapshot of the provider-level payload: seed for a fresh database
  # and offline fallback. The live mirror is the `catalog_providers` table.
  @snapshot_path Path.expand("../../../priv/models_dev/providers.json", __DIR__)
  @external_resource @snapshot_path
  @snapshot @snapshot_path |> File.read!() |> Jason.decode!()

  @doc """
  The vendored snapshot as entries with atom keys, sorted by key.

  Used to seed `catalog_providers` and as a deterministic fixture; the running
  catalog is the mirror table, not this.
  """
  @spec snapshot() :: [map()]
  def snapshot do
    @snapshot
    |> Enum.map(fn {key, entry} ->
      %{
        key: key,
        name: Map.get(entry, "name"),
        base_url: Map.get(entry, "base_url"),
        doc_url: Map.get(entry, "doc_url"),
        logo_url: Map.get(entry, "logo_url"),
        env: Map.get(entry, "env") || [],
        npm: Map.get(entry, "npm")
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  @doc "Number of providers in the vendored snapshot."
  @spec snapshot_size() :: non_neg_integer()
  def snapshot_size, do: map_size(@snapshot)

  # Origin every models.dev asset (logos) and payload lives on. NOT the same as
  # `base_url/1`, which resolves a PROVIDER's endpoint.
  @upstream_origin "https://models.dev"

  @doc "The models.dev origin this catalog mirrors."
  @spec origin() :: String.t()
  def origin, do: @upstream_origin

  @doc """
  Normalizes the raw models.dev `/api.json` payload into PROVIDER-level entries.

  Provider-level fields only: the payload is ~4.5 MB and the bulk of it is
  per-model data, que el gateway ya NO espeja — el alta lista los modelos del
  proveedor en vivo. `api` is models.dev's base URL key; `base_url` is accepted
  too so a future schema rename does not blank the catalog.

  The provider LOGO is always built on the models.dev origin, whoever served the
  payload: it is an asset id, not a mirror-relative path.
  """
  @spec normalize_providers(map() | any()) :: [map()]
  def normalize_providers(body) when is_map(body) do
    body
    |> Enum.filter(fn {id, value} -> is_binary(id) and is_map(value) end)
    |> Enum.map(fn {id, value} ->
      %{
        key: id,
        name: normalize_name(id, value),
        base_url: normalize_url(value["api"] || value["base_url"]),
        doc_url: normalize_url(value["doc"]),
        logo_url: "#{@upstream_origin}/logos/#{id}.svg",
        env: value |> Map.get("env") |> List.wrap() |> Enum.filter(&is_binary/1),
        npm: value["npm"],
        status: "active"
      }
    end)
  end

  def normalize_providers(_), do: []

  defp normalize_name(id, value) do
    case value["name"] do
      name when is_binary(name) and name != "" -> name
      _ -> id
    end
  end

  defp normalize_url(nil), do: nil

  defp normalize_url(url) when is_binary(url) do
    case String.trim_trailing(url, "/") do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_url(_), do: nil

  @doc "The code customization for a models.dev id, or nil when there is none."
  @spec customization(String.t() | nil) :: map() | nil
  def customization(key) when is_binary(key), do: Map.get(@customizations, key)
  def customization(_), do: nil

  @doc """
  Providers models.dev does NOT publish, whose full row lives in code.

  Returned in the shape `CatalogProvider` stores (sorted by key), so
  `CatalogSync.ensure_code_providers/0` can upsert them through the same
  changeset and fingerprint the refresh uses.
  """
  @spec code_providers() :: [map()]
  def code_providers do
    @code_providers
    |> Enum.map(fn {key, entry} -> Map.merge(entry, %{key: key, status: "active"}) end)
    |> Enum.sort_by(& &1.key)
  end

  @doc """
  Keys of the code-owned providers.

  The refresh must never sweep these to `stale`: they are not data that
  disappeared upstream, they are data upstream never had. Marking them stale
  would freeze them out of the next materialization.
  """
  @spec code_provider_keys() :: [String.t()]
  def code_provider_keys, do: @code_providers |> Map.keys() |> Enum.sort()

  # Single accessor for every customization key, driven by a runtime key name
  # so the whole documented set works (:capabilities, :dialect, :base_url,
  # :paths, :omit_body_fields) instead of one clause per
  # key — the escape hatch must not need a new function when it is used.
  defp option(key, name, default) do
    case customization(key) do
      %{} = config -> Map.get(config, name, default)
      _ -> default
    end
  end

  @doc """
  Capabilities declared for a provider in code (possibly empty).

      iex> Tokengate.Providers.Catalog.capabilities("fireworks-ai")
      ["llm", "embedding", "decision"]

      iex> Tokengate.Providers.Catalog.capabilities("anthropic")
      []
  """
  @spec capabilities(String.t() | nil) :: [String.t()]
  def capabilities(key) do
    case option(key, :capabilities, []) do
      caps when is_list(caps) -> caps
      _ -> []
    end
  end

  @doc """
  True cuando un proveedor del catálogo declara la capability `type`.

  La regla de "sin dato" es la del propio catálogo: un proveedor sin entrada (o
  con la lista vacía) se trata como **chat**, así que sólo declara `"llm"`. Es
  la que aplica el modal de modelo al elegir proveedor por tipo, y la que evita
  que un tipo de servicio muestre como candidatos a proveedores que no pueden
  servirlo.

      iex> Tokengate.Providers.Catalog.declares?("openrouter", "image")
      true

      iex> Tokengate.Providers.Catalog.declares?("fireworks-ai", "image")
      false

      iex> Tokengate.Providers.Catalog.declares?("anthropic", "llm")
      true
  """
  @spec declares?(String.t() | nil, String.t()) :: boolean()
  def declares?(key, type) when is_binary(type) do
    case capabilities(key) do
      [] -> type == "llm"
      caps -> type in caps
    end
  end

  @doc """
  The wire shape a provider speaks on the decisions surface:

    * `:openai` — the OpenAI Decisions shape (`POST /v1/decisions`,
      `input` + ordered questions with `predicate`/`choice`/`score`):
      the gateway's `/v1/decisions` request passes through verbatim
      (OpenAI, Fireworks, oMLX…).
    * `:systemone` — the TypeSafe System One shape (`{model, state,
      questions}` map): the gateway translates through
      `Tokengate.Proxy.DecisionsTranslator` (TypeSafe, OpenRouter and
      every Jev reseller).

  Defaults to `:openai`: an operator-added provider with a decisions
  endpoint (an oMLX host, say) speaks the OpenAI shape by construction.
  """
  @spec decisions_shape(String.t() | nil) :: :openai | :systemone
  def decisions_shape(key) do
    case option(key, :decisions_shape, :openai) do
      :systemone -> :systemone
      _ -> :openai
    end
  end

  @doc "Valid dialects."
  def dialects, do: @dialects

  @doc "Valid sources."
  def sources, do: @sources

  @doc "Valid capabilities (the vocabulary, not per-provider)."
  def capabilities, do: @capabilities

  @doc """
  Resolves a provider's dialect: the code customization first, else the
  models.dev npm package.

  Returns `{:ok, dialect}` or `{:error, reason}`, the reason being a
  Spanish, UI-ready sentence.
  """
  @spec dialect(map() | String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def dialect(%{} = entry) do
    key = Map.get(entry, :key) || Map.get(entry, "key")

    case option(key, :dialect, nil) do
      dialect when is_binary(dialect) ->
        {:ok, dialect}

      _ ->
        dialect_from_npm(Map.get(entry, :npm) || Map.get(entry, "npm"))
    end
  end

  def dialect(key) when is_binary(key), do: dialect(%{key: key, npm: nil})
  def dialect(_), do: {:error, "no dialect"}

  defp dialect_from_npm(npm) do
    case Map.get(@dialect_by_npm, npm) do
      nil -> {:error, "dialecto no soportado (#{npm || "sin paquete npm"})"}
      dialect -> {:ok, dialect}
    end
  end

  @doc """
  Why a provider cannot be used yet (nil when it can) — the add-provider modal
  shows it on the disabled rows. Los textos son msgid en inglés y se traducen al
  pintar (`TokengateWeb.Gettext.translate/1` en `providers_live`).
  """
  @spec unsupported_reason(map() | nil) :: String.t() | nil
  def unsupported_reason(nil), do: "no data"

  def unsupported_reason(entry) when is_map(entry) do
    # The EFFECTIVE URL, not the raw row: a provider models.dev publishes
    # without a base URL (cerebras) can carry it in its code customization, and
    # this gate has to see the same URL the materializer stores — otherwise the
    # override would never make the provider usable.
    base = base_url(entry)

    cond do
      is_nil(base) ->
        "models.dev no publica su base URL"

      # models.dev publishes a few account-scoped URLs as templates
      # (${ACCOUNT_ID}, ${DATABRICKS_HOST}, …): without the operator's own
      # substitution they are not an endpoint, so the row stays unmaterialized
      # instead of pointing at a URL that cannot resolve.
      String.contains?(base, "${") ->
        "models.dev publishes its base URL as a template (needs your account or endpoint)"

      match?({:error, _}, dialect(entry)) ->
        {:error, reason} = dialect(entry)
        reason

      true ->
        nil
    end
  end

  @doc "True when the gateway can route to this provider (base URL + dialect)."
  @spec supported?(map() | nil) :: boolean()
  def supported?(entry), do: unsupported_reason(entry) == nil

  @doc """
  Base URL for a provider: the code override when set, else the remote one,
  trailing slash trimmed.
  """
  @spec base_url(map() | nil) :: String.t() | nil
  def base_url(nil), do: nil

  def base_url(entry) when is_map(entry) do
    key = Map.get(entry, :key) || Map.get(entry, "key")

    override = option(key, :base_url, nil)

    url =
      if is_binary(override) do
        override
      else
        Map.get(entry, :base_url) || Map.get(entry, "base_url")
      end

    if is_binary(url), do: String.trim_trailing(url, "/")
  end

  @doc """
  Path suffix for one service, overridable per provider in code.

      iex> Tokengate.Providers.Catalog.path_suffix("openrouter", service: :chat, default: "/chat/completions")
      "/chat/completions"
  """
  @spec path_suffix(String.t() | nil, keyword()) :: String.t()
  def path_suffix(key, opts) do
    service = Keyword.fetch!(opts, :service)
    default = Keyword.fetch!(opts, :default)

    case option(key, :paths, %{}) do
      %{} = paths -> Map.get(paths, service, default)
      _ -> default
    end
  end

  @doc """
  Body fields the gateway must strip for a strict provider, by catalog key.

  Empty for every provider today, and for unknown/custom keys: the one entry
  that existed declared `session_id` for Fireworks, and that field is no
  longer injected at all, so there was nothing left to strip. The seam stays
  for an upstream that rejects a field the gateway DOES send, or one a client
  sends and the operator wants removed.

      iex> Tokengate.Providers.Catalog.omit_body_fields("openrouter")
      []

      iex> Tokengate.Providers.Catalog.omit_body_fields(nil)
      []
  """
  @spec omit_body_fields(String.t() | nil) :: [String.t()]
  def omit_body_fields(key \\ nil) do
    case option(key, :omit_body_fields, []) do
      fields when is_list(fields) -> fields
      _ -> []
    end
  end

  @doc """
  How the provider's upstream wants its reasoning knobs on the wire, by
  catalog key — one of `@reasoning_dialects`, or `:passthrough` for every
  key that declares none (unknown/custom included).

  The pre-flight pipeline uses this to reshape whatever form the CLIENT
  sent (nested `reasoning`, scalar `reasoning_effort`, `thinking` toggle)
  into the one dialect the serving upstream documents, mirroring the
  Hermes provider profiles.

      iex> Tokengate.Providers.Catalog.reasoning_dialect("fireworks-ai")
      :scalar

      iex> Tokengate.Providers.Catalog.reasoning_dialect("moonshotai")
      :toggle_xor_effort

      iex> Tokengate.Providers.Catalog.reasoning_dialect("zai")
      :toggle_and_effort

      iex> Tokengate.Providers.Catalog.reasoning_dialect("openrouter")
      :openrouter_nested

      iex> Tokengate.Providers.Catalog.reasoning_dialect("deepseek")
      :deepseek_native

      iex> Tokengate.Providers.Catalog.reasoning_dialect("alibaba")
      :passthrough

      iex> Tokengate.Providers.Catalog.reasoning_dialect(nil)
      :passthrough
  """
  @spec reasoning_dialect(String.t() | nil) :: atom()
  def reasoning_dialect(key \\ nil) do
    case option(key, :reasoning_dialect, :passthrough) do
      dialect when dialect in @reasoning_dialects -> dialect
      _ -> :passthrough
    end
  end

  @doc """
  Normalizes a base URL for catalog matching: trailing slash trimmed, case
  downcased. `https://OpenRouter.ai/api/v1/` and
  `https://openrouter.ai/api/v1` match.
  """
  @spec normalize_base_url(nil | String.t()) :: nil | String.t()
  def normalize_base_url(nil), do: nil

  def normalize_base_url(url) when is_binary(url) do
    url |> String.trim_trailing("/") |> String.downcase()
  end
end
