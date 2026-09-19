defmodule Tokengate.Providers.ModelCatalog do
  @moduledoc """
  models.dev models: the metadata that fills a model in the admin, and who serves it.

  ## Two upstream sources, one catalog

  models.dev publishes two payloads and neither is enough on its own — the same
  split `LabCatalog` deals with:

    * `/models.json` — the CANONICAL models (403 of them): name, description,
      limits, modalities, release dates, license, and a market cost. An entry
      here says what a model IS, not who serves it.
    * `/api.json` — per provider, a `models` map. Across the 181 providers the
      gateway can serve (`Catalog.supported?/1`) that is 6101 entries over 2953
      distinct ids: ~2750 ids that the canonical list never mentions
      (`@cf/…`, `accounts/fireworks/routers/…`, `glm-5.2`). An entry here says
      who serves a model, at which `provider_model` id, and at which price.

  So `derive/3` always takes BOTH payloads and emits the two halves the mirror
  needs: `:models` (the model dimension, canonical metadata winning when the id
  is in both) and `:offers` (provider × model, with the provider's price). The
  model's own `cost_*` is then the CHEAPEST offer serving it: `/models.json`
  publishes no price at all (0 of its entries carry a `cost`), so the offer table
  is the only place a reference price can come from.

  ## Snapshot vs live

  `snapshot/0` is the vendored `priv/models_dev/models_catalog.json` — seed for a
  fresh database and offline fallback, regenerable with
  `mix tokengate.models.snapshot`, and read at RUNTIME on purpose: it is ~1 MB,
  so embedding it in the beam at compile time would be pure cost. The live
  catalog is the two mirror tables, refreshed by `CatalogRefreshWorker`.
  `derive/3` is the single derivation both paths use, so the snapshot and a
  refresh cannot disagree by construction.

  ## Hints, not facts

  Upstream does not say whether a model is an embedding or a chat model — both
  report `modalities: %{input: ["text"], output: ["text"]}` — so the type is a
  HINT from the id (`model_type_hint/1`) that the operator confirms in the form,
  and `features/0` is the closed vocabulary of what an entry may declare.
  """

  alias Tokengate.Providers.{Catalog, CatalogModel, CatalogModelOffer}

  @base_url "https://models.dev"

  # Descriptions are shown in the picker, not stored for their own sake: a
  # handful of upstream blobs are paragraphs long.
  @description_limit 400

  # models.dev does not distinguish an embedding from a chat model. The id is
  # the only signal upstream publishes, and this gateway only ever needs a HINT:
  # it prefills `model_type` in the form and the operator confirms it.
  @embedding_hint ~r/(^|[-_\/])embed/i

  # What a lab id looks like (models.dev lab ids are lowercase slugs, and the
  # `labs` table pins the same shape). A first segment that fails this is an
  # account or a namespace, not a lab.
  @lab_id_format ~r/^[a-z0-9][a-z0-9._-]*$/

  # `priv` as mix/releases install it. The path is resolved at RUNTIME (see
  # `snapshot/0`); the compile-time expand below only feeds `@external_resource`.
  @snapshot_rel "priv/models_dev/models_catalog.json.gz"
  @compiled_snapshot_path Path.expand("../../../#{@snapshot_rel}", __DIR__)
  @external_resource @compiled_snapshot_path

  @type derived :: %{models: [map()], offers: [map()]}

  @doc "The models.dev origin this catalog is derived from."
  @spec base_url() :: String.t()
  def base_url, do: @base_url

  @doc "Feature vocabulary the catalog may record (keys of a model entry that are true)."
  @spec features() :: [String.t()]
  def features, do: CatalogModel.features()

  @doc """
  The vendored snapshot, in the same shape `derive/3` returns.

  Read at runtime (the file is ~2.7 MB of JSON, ~280 KB gzipped, so it never
  enters the beam) and tolerant of a missing or unreadable file: an instance
  without the snapshot still runs, it just seeds nothing and waits for the first
  refresh.

  The path is resolved at RUNTIME through `Application.app_dir/2`, which follows
  the app wherever it was installed: `_build/<env>/lib/tokengate/priv` in dev
  (mix symlinks `priv` into the build) and `lib/tokengate-<vsn>/priv` inside a
  release. Resolving it at COMPILE time (`__DIR__`) instead bakes the path of the
  machine that compiled the beam — in the Docker image that is `/app/priv/...`,
  which the runtime stage does NOT contain (it copies only the release, whose
  root has no `priv/`), so the read failed and the model seed silently inserted
  nothing: an empty model catalog in production while the provider and lab halves
  — embedded in the beam at compile time — loaded fine.
  """
  @spec snapshot() :: derived()
  def snapshot, do: snapshot_from(snapshot_path())

  @doc """
  Where the vendored snapshot is read from — release-safe by construction.

  Public so the release layout is assertable in tests: a revert to a
  compile-time path resolves somewhere else and fails them.
  """
  @spec snapshot_path() :: Path.t()
  def snapshot_path do
    Application.app_dir(:tokengate, @snapshot_rel)
  rescue
    # `Application.app_dir/2` raises when the app is not loaded; the compile-time
    # path is then the only candidate left.
    _ -> @compiled_snapshot_path
  end

  @doc """
  Reads a snapshot file (gzipped or plain JSON) into `derive/3`'s shape.

  Public so the snapshot task can compare a fresh derivation with what is on
  disk without caring which of the two encodings the file uses.
  """
  @spec snapshot_from(Path.t()) :: derived()
  def snapshot_from(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- gunzip(body),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(json) do
      decode_snapshot(decoded)
    else
      _ -> %{models: [], offers: []}
    end
  rescue
    # A truncated or not-really-gzip file is a missing snapshot, never a crash on
    # the boot path.
    _ -> %{models: [], offers: []}
  end

  # The snapshot is written gzipped (a 10x saving on generated data no one reads
  # by hand); plain JSON is accepted too so `--out` is free to point anywhere.
  defp gunzip(<<0x1F, 0x8B, _::binary>> = body), do: {:ok, :zlib.gunzip(body)}
  defp gunzip(body), do: {:ok, body}

  @doc "Number of models in the vendored snapshot."
  @spec snapshot_model_count() :: non_neg_integer()
  def snapshot_model_count, do: length(snapshot().models)

  @doc """
  Derives the model mirror from the two models.dev payloads.

    * `entries` — the NORMALIZED provider entries (`CatalogRefreshWorker` /
      `Catalog.normalize_providers/1`), which is how the gateway decides whether
      it can serve a provider at all (`Catalog.supported?/1`). A provider it
      cannot serve contributes no offer: it is not routable, so listing its
      models in the picker would only produce dead ends.
    * `providers_payload` — raw `/api.json`, for the per-provider `models` maps.
    * `models_payload` — raw `/models.json`, the canonical entries.

  Returns `%{models: attrs, offers: attrs}` sorted by key, ready to upsert.
  """
  @spec derive([map()], map() | nil, map() | nil) :: derived()
  def derive(entries, providers_payload, models_payload) when is_list(entries) do
    supported =
      entries |> Enum.filter(&Catalog.supported?/1) |> Enum.map(& &1.key) |> MapSet.new()

    {offers, from_providers} = derive_offers(providers_payload, supported)
    best = cheapest_by_model(offers)

    models =
      models_payload
      |> canonical_entries()
      |> Enum.reduce(from_providers, fn {key, entry}, acc ->
        Map.update(acc, key, canonical_attrs(key, entry), &merge_canonical(&1, entry, key))
      end)
      |> Map.values()
      |> Enum.map(&with_market_prices(&1, Map.get(best, &1.key)))
      |> Enum.sort_by(& &1.key)

    %{models: models, offers: Enum.sort_by(offers, &{&1.provider_key, &1.model_key})}
  end

  def derive(_entries, _providers_payload, _models_payload), do: %{models: [], offers: []}

  # The reference price of a model is the cheapest lane that serves it: models.dev
  # publishes `cost` ONLY per provider (`/models.json` carries no price at all —
  # 0 of its entries do), so the offer table is the only source. The minimum is
  # the honest summary: "this model can be had from here".
  defp cheapest_by_model(offers) do
    Enum.reduce(offers, %{}, fn offer, acc ->
      current = Map.get(acc, offer.model_key)

      if current == nil or cheaper?(offer, current) do
        Map.put(acc, offer.model_key, offer)
      else
        acc
      end
    end)
  end

  # A missing price never wins over one that exists; among two that exist, the
  # lower input price decides (input dominates most workloads).
  defp cheaper?(offer, current) do
    case {offer.cost_input, current.cost_input} do
      {nil, nil} -> false
      {nil, _} -> false
      {_, nil} -> true
      {new, old} -> Decimal.compare(new, old) == :lt
    end
  end

  defp with_market_prices(model, nil), do: model

  defp with_market_prices(model, offer) do
    %{
      model
      | cost_input: model.cost_input || offer.cost_input,
        cost_output: model.cost_output || offer.cost_output,
        cost_cache_read: model.cost_cache_read || offer.cost_cache_read,
        cost_cache_write: model.cost_cache_write || offer.cost_cache_write
    }
  end

  @doc """
  Encodes a derivation into the snapshot wire format (string keys, no Decimals —
  prices travel as strings to keep a float round-trip out of the file).
  """
  @spec encode_snapshot(derived()) :: map()
  def encode_snapshot(%{models: models, offers: offers}) do
    %{
      "models" =>
        models
        |> Enum.sort_by(& &1.key)
        |> Map.new(fn model -> {model.key, encode_model(model)} end),
      "offers" =>
        offers
        |> Enum.sort_by(&{&1.provider_key, &1.model_key})
        |> Enum.map(&encode_offer/1)
    }
  end

  @doc "Decodes the snapshot wire format back into `derive/3`'s shape."
  @spec decode_snapshot(map()) :: derived()
  def decode_snapshot(%{"models" => models, "offers" => offers}) when is_map(models) do
    %{
      models:
        models
        |> Enum.filter(fn {key, entry} -> is_binary(key) and is_map(entry) end)
        |> Enum.map(fn {key, entry} -> decode_model(key, entry) end)
        |> Enum.sort_by(& &1.key),
      offers:
        offers
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Enum.map(&decode_offer/1)
        |> Enum.sort_by(&{&1.provider_key, &1.model_key})
    }
  end

  def decode_snapshot(_), do: %{models: [], offers: []}

  ## Naming and hints ---------------------------------------------------------

  @doc """
  Default operator-facing name for a catalog model.

  It strips the lab prefix of a canonical id (`lab/model`), and for an id only a
  provider publishes — a path of its own, like
  `accounts/fireworks/routers/kimi-latest` — it keeps the last segment, which is
  the part that names the model. The operator edits it in the form anyway: this
  is a default, not a decision.

      iex> Tokengate.Providers.ModelCatalog.short_name("openai/gpt-5-nano")
      "gpt-5-nano"

      iex> Tokengate.Providers.ModelCatalog.short_name("glm-5.2")
      "glm-5.2"

      iex> Tokengate.Providers.ModelCatalog.short_name("accounts/fireworks/routers/kimi-latest")
      "kimi-latest"
  """
  @spec short_name(String.t()) :: String.t()
  def short_name(id) when is_binary(id) do
    case String.split(id, "/") do
      [lab, model] -> if plausible_lab?(lab) and model != "", do: model, else: id
      [_ | _] = parts -> if length(parts) > 2, do: List.last(parts), else: id
      [] -> id
    end
  end

  def short_name(id), do: to_string(id)

  @doc """
  The lab a catalog id belongs to (nil when the id is not `lab/model`).

  A lab IS the prefix of a canonical id — that is how `labs` is derived — so the
  prefix only counts when the id is exactly `lab/model` and the prefix looks like
  a lab id. An id only a provider publishes can carry a path of its own
  (`accounts/fireworks/routers/kimi-latest`, `@cf/meta/llama-…`) whose first
  segment is an account or a namespace: attributing that model to a lab nobody
  publishes would be a lie, and there is no `labs` row to hang it on either.

      iex> Tokengate.Providers.ModelCatalog.lab_key("anthropic/claude-opus-4.7")
      "anthropic"

      iex> Tokengate.Providers.ModelCatalog.lab_key("accounts/fireworks/routers/kimi-latest")
      nil
  """
  @spec lab_key(String.t() | nil) :: String.t() | nil
  def lab_key(id) when is_binary(id) do
    case String.split(id, "/") do
      [lab, model] -> if model != "" and plausible_lab?(lab), do: lab
      _ -> nil
    end
  end

  def lab_key(_), do: nil

  defp plausible_lab?(lab), do: Regex.match?(@lab_id_format, lab)

  @doc """
  HINT for `models.model_type` based on the id: `"embedding"`, `"decision"`
  or `"llm"`.

  Upstream publishes no such field, so this is only what the form is prefilled
  with — the operator confirms it.

      iex> Tokengate.Providers.ModelCatalog.model_type_hint("google/gemini-embedding-001")
      "embedding"

      iex> Tokengate.Providers.ModelCatalog.model_type_hint("typesafe/jev")
      "decision"

      iex> Tokengate.Providers.ModelCatalog.model_type_hint("openai/gpt-5-nano")
      "llm"
  """
  @spec model_type_hint(String.t()) :: String.t()
  def model_type_hint(id) when is_binary(id) do
    cond do
      Regex.match?(@embedding_hint, id) -> "embedding"
      String.starts_with?(id, "typesafe/") -> "decision"
      true -> "llm"
    end
  end

  def model_type_hint(_), do: "llm"

  @doc """
  The enabled features of an entry, restricted to the vocabulary in
  `CatalogModel.features/0`.

  Accepts either a raw upstream entry (whose feature flags are booleans at the
  top level: `%{"reasoning" => true, …}`) or an already-extracted list (the shape
  the snapshot file holds), so the two paths share one vocabulary.
  """
  @spec enabled_features(map() | [String.t()] | any()) :: [String.t()]
  def enabled_features(entry) when is_map(entry) do
    Enum.filter(features(), fn feature -> Map.get(entry, feature) == true end)
  end

  def enabled_features(list) when is_list(list) do
    Enum.filter(list, &(is_binary(&1) and &1 in features()))
  end

  def enabled_features(_), do: []

  @doc """
  Prefill for the operator's model form, from a catalog row.

  Every field stays editable — this is what the modal fills in when a catalog
  model is picked, not a decision:

    * `:name` is `short_name/1` (the id without its lab prefix);
    * `:model_type` is `model_type_hint/1`, the operator confirms it;
    * `:context_window` comes from the canonical entry. A missing context window
      is left empty on purpose: the form requires it and a value invented here
      would be worse than one gap to fill.
  """
  @spec to_model_params(map()) :: map()
  def to_model_params(catalog_model) when is_map(catalog_model) do
    %{
      name: short_name(catalog_model.key),
      context_window: Map.get(catalog_model, :context_limit),
      model_type: model_type_hint(catalog_model.key),
      catalog_model_key: catalog_model.key,
      lab_key: Map.get(catalog_model, :lab_key)
    }
  end

  def to_model_params(_), do: %{}

  ## Derivation ---------------------------------------------------------------

  defp canonical_entries(payload) when is_map(payload) do
    payload
    |> Enum.filter(fn {key, entry} -> is_binary(key) and is_map(entry) end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical_entries(_), do: []

  # Offers come from `/api.json`: one row per (provider, model) of every provider
  # the gateway can serve. The model skeleton is taken from here too, so an id
  # only a provider publishes still gets a dimension row.
  defp derive_offers(payload, supported) when is_map(payload) do
    payload
    |> Enum.filter(fn {key, value} ->
      is_binary(key) and is_map(value) and MapSet.member?(supported, key)
    end)
    |> Enum.reduce({[], %{}}, fn {provider_key, provider}, {offers, models} ->
      provider
      |> Map.get("models", %{})
      |> Enum.filter(fn {key, entry} -> is_binary(key) and is_map(entry) end)
      |> Enum.reduce({offers, models}, fn {model_key, entry}, {offers, models} ->
        offer = offer_attrs(provider_key, model_key, entry)

        models =
          Map.put_new_lazy(models, model_key, fn -> provider_model_attrs(model_key, entry) end)

        {[offer | offers], models}
      end)
    end)
  end

  defp derive_offers(_payload, _supported), do: {[], %{}}

  defp offer_attrs(provider_key, model_key, entry) do
    cost = Map.get(entry, "cost") || %{}
    limit = Map.get(entry, "limit") || %{}

    %{
      provider_key: provider_key,
      model_key: model_key,
      provider_model: Map.get(entry, "id") || model_key,
      cost_input: decimal(cost["input"]),
      cost_output: decimal(cost["output"]),
      cost_cache_read: decimal(cost["cache_read"]),
      cost_cache_write: decimal(cost["cache_write"]),
      tiers: tiers(cost["tiers"]),
      limit_context: integer(limit["context"]),
      limit_output: integer(limit["output"]),
      lifecycle: lifecycle(entry),
      experimental: Map.get(entry, "experimental") == true
    }
  end

  # An id only a provider publishes: the model row exists so the picker can
  # offer it, with the metadata that provider gave. No cost/market price here —
  # the price belongs to the offer, and the canonical prices only exist for
  # canonical ids.
  defp provider_model_attrs(model_key, entry) do
    limit = Map.get(entry, "limit") || %{}

    %{
      key: model_key,
      name: name_of(model_key, entry),
      lab_key: lab_key(model_key),
      description: description(entry),
      canonical: false,
      context_limit: integer(limit["context"]),
      output_limit: integer(limit["output"]),
      cost_input: nil,
      cost_output: nil,
      cost_cache_read: nil,
      cost_cache_write: nil,
      modalities: modalities(entry),
      features: enabled_features(entry),
      release_date: string(entry["release_date"]),
      last_updated: string(entry["last_updated"]),
      license: string(entry["license"])
    }
  end

  # A canonical id: `/models.json` is the authority for what the model is, so its
  # non-empty values win over whatever a provider published. It publishes no price
  # (0 of its 403 entries carry a `cost`), so the market price of the row comes
  # from its cheapest offer instead — see `with_market_prices/2`.
  defp canonical_attrs(key, entry) do
    attrs = provider_model_attrs(key, entry)
    %{attrs | canonical: true}
  end

  defp merge_canonical(existing, entry, key) do
    canonical = canonical_attrs(key, entry)

    Enum.reduce(
      [
        :name,
        :description,
        :context_limit,
        :output_limit,
        :cost_input,
        :cost_output,
        :cost_cache_read,
        :cost_cache_write,
        :modalities,
        :features,
        :release_date,
        :last_updated,
        :license
      ],
      canonical,
      fn field, acc ->
        case {Map.get(canonical, field), Map.get(existing, field)} do
          {nil, value} -> Map.put(acc, field, value)
          {[], value} -> Map.put(acc, field, value)
          {%{} = empty, value} when map_size(empty) == 0 -> Map.put(acc, field, value)
          _ -> acc
        end
      end
    )
  end

  ## Values -------------------------------------------------------------------

  defp name_of(key, entry) do
    case Map.get(entry, "name") do
      name when is_binary(name) and name != "" -> name
      _ -> key
    end
  end

  defp description(entry) do
    case Map.get(entry, "description") do
      text when is_binary(text) and text != "" -> String.slice(text, 0, @description_limit)
      _ -> nil
    end
  end

  defp modalities(entry) do
    case Map.get(entry, "modalities") do
      %{} = modalities ->
        %{
          "input" => string_list(modalities["input"]),
          "output" => string_list(modalities["output"])
        }

      _ ->
        %{}
    end
  end

  defp string_list(value) do
    value |> List.wrap() |> Enum.filter(&is_binary/1)
  end

  defp lifecycle(entry) do
    case Map.get(entry, "status") do
      status when status in ["deprecated", "beta"] -> status
      _ -> "stable"
    end
  end

  # Upstream only ever publishes `type: "context"` tiers. The nesting is dropped
  # here so a consumer reads `%{"size" => ctx, "input" => …}` and no one has to
  # know about a one-value enum; `type` is kept for the day a second one appears.
  defp tiers(list) when is_list(list) do
    list
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(fn tier ->
      declared = Map.get(tier, "tier") || %{}

      with size when is_integer(size) <- Map.get(declared, "size"),
           type when is_binary(type) <- Map.get(declared, "type", "context") do
        [
          %{
            "type" => type,
            "size" => size,
            "input" => decimal_string(tier["input"]),
            "output" => decimal_string(tier["output"]),
            "cache_read" => decimal_string(tier["cache_read"]),
            "cache_write" => decimal_string(tier["cache_write"])
          }
          |> Map.reject(fn {_key, value} -> is_nil(value) end)
        ]
      else
        _ -> []
      end
    end)
  end

  defp tiers(_), do: []

  defp decimal_string(value) do
    case decimal(value) do
      nil -> nil
      %Decimal{} = decimal -> Decimal.to_string(decimal)
    end
  end

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: nil

  # Prices are floats upstream (0.65, 4.425) and strings in the snapshot (the file
  # keeps them as text so no float round-trip can creep in).
  # `Decimal.new(to_string/1)` keeps the shortest representation that round-trips,
  # so the column stores 0.650000 and never 0.6499999999999999.
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.new(to_string(value))

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp decimal(_), do: nil

  ## Snapshot wire format -----------------------------------------------------

  defp encode_model(model) do
    %{
      "name" => model.name,
      "lab_key" => model.lab_key,
      "description" => model.description,
      "canonical" => model.canonical,
      "limit" => [model.context_limit, model.output_limit],
      "cost" => cost_list(model),
      "modalities" => model.modalities,
      "features" => model.features,
      "release_date" => model.release_date,
      "last_updated" => model.last_updated,
      "license" => model.license
    }
  end

  defp encode_offer(offer) do
    %{
      "provider_key" => offer.provider_key,
      "model_key" => offer.model_key,
      "provider_model" => offer.provider_model,
      "cost" => cost_list(offer),
      "limit" => [offer.limit_context, offer.limit_output],
      "lifecycle" => offer.lifecycle,
      "experimental" => offer.experimental,
      "tiers" =>
        Enum.map(offer.tiers, fn tier ->
          %{
            "type" => tier["type"],
            "size" => tier["size"],
            "input" => tier["input"],
            "output" => tier["output"],
            "cache_read" => tier["cache_read"],
            "cache_write" => tier["cache_write"]
          }
        end)
    }
  end

  defp cost_list(entry) do
    [
      encode_decimal(Map.get(entry, :cost_input)),
      encode_decimal(Map.get(entry, :cost_output)),
      encode_decimal(Map.get(entry, :cost_cache_read)),
      encode_decimal(Map.get(entry, :cost_cache_write))
    ]
  end

  defp encode_decimal(nil), do: nil
  defp encode_decimal(%Decimal{} = value), do: Decimal.to_string(value)

  defp decode_model(key, entry) do
    [context, output] = pair(Map.get(entry, "limit"))

    %{
      key: key,
      name: Map.get(entry, "name") || key,
      lab_key: Map.get(entry, "lab_key"),
      description: Map.get(entry, "description"),
      canonical: Map.get(entry, "canonical") == true,
      context_limit: context,
      output_limit: output,
      cost_input: decode_cost(Map.get(entry, "cost"), 0),
      cost_output: decode_cost(Map.get(entry, "cost"), 1),
      cost_cache_read: decode_cost(Map.get(entry, "cost"), 2),
      cost_cache_write: decode_cost(Map.get(entry, "cost"), 3),
      modalities: Map.get(entry, "modalities") || %{},
      features: enabled_features(Map.get(entry, "features")),
      release_date: Map.get(entry, "release_date"),
      last_updated: Map.get(entry, "last_updated"),
      license: Map.get(entry, "license")
    }
  end

  defp decode_offer(entry) do
    [context, output] = pair(Map.get(entry, "limit"))

    %{
      provider_key: Map.get(entry, "provider_key"),
      model_key: Map.get(entry, "model_key"),
      provider_model: Map.get(entry, "provider_model"),
      cost_input: decode_cost(Map.get(entry, "cost"), 0),
      cost_output: decode_cost(Map.get(entry, "cost"), 1),
      cost_cache_read: decode_cost(Map.get(entry, "cost"), 2),
      cost_cache_write: decode_cost(Map.get(entry, "cost"), 3),
      tiers: Map.get(entry, "tiers") |> List.wrap() |> Enum.filter(&is_map/1),
      limit_context: context,
      limit_output: output,
      lifecycle: Map.get(entry, "lifecycle") || "stable",
      experimental: Map.get(entry, "experimental") == true
    }
  end

  defp decode_cost(list, index) when is_list(list), do: decimal(Enum.at(list, index))
  defp decode_cost(_list, _index), do: nil

  defp pair(list) when is_list(list) do
    [integer(Enum.at(list, 0)), integer(Enum.at(list, 1))]
  end

  defp pair(_), do: [nil, nil]

  ## Code-owned models #########################################################

  # Models whose ENTIRE row lives in code because models.dev does not publish
  # them. Same rationale as `Catalog.@code_providers`: the seed only fills an
  # empty table and the snapshot is baked into the release image, so a running
  # instance would never see a hand-added row. `ensure_code_models/0` upserts
  # them (called from `CatalogSync.sync/0`) and `mark_models_stale` /
  # `mark_offers_stale` skip these keys — models.dev never had them, so their
  # absence upstream is not "gone".
  #
  # Fields mirror `derive/3`'s model shape plus the one offer that makes the
  # model reachable in the picker (offers are what `catalog_picker_models`
  # counts; a model with no offer is a dead end).
  @code_models %{
    # Jev, el primer modelo System One de TypeSafe: decisiones tipadas con
    # probabilidades calibradas. Precio de lista: $42/Btok input ($0.042/Mtok),
    # output gratis. Contexto 64k. El alias jev-latest es el default de sus
    # SDKs; jev-1.13.0 es la versión pinnable.
    "typesafe/jev" => %{
      name: "Jev",
      lab_key: "typesafe",
      description:
        "TypeSafe's flagship System One model: typed decisions with calibrated probabilities.",
      context_limit: 64_000,
      cost_input: Decimal.new("0.042"),
      cost_output: Decimal.new("0"),
      features: [],
      modalities: %{input: ["text"], output: ["text"]},
      offers: [
        %{
          provider_key: "typesafe",
          provider_model: "jev-latest",
          cost_input: Decimal.new("0.042"),
          cost_output: Decimal.new("0")
        }
      ]
    }
  }

  @doc "Keys of the code-owned catalog models (never swept stale)."
  @spec code_model_keys() :: [String.t()]
  def code_model_keys, do: @code_models |> Map.keys() |> Enum.sort()

  @doc """
  Upserts the code-owned models and their offers into the mirror tables.

  Idempotent on the same rule as the refresh: a row whose fingerprint already
  matches is not written. Called from `CatalogSync.sync/0` on boot — never
  raises, the app must boot.
  """
  @spec ensure_code_models() :: :ok
  def ensure_code_models do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(@code_models, fn {key, model} ->
      attrs =
        %{
          key: key,
          name: model.name,
          lab_key: model.lab_key,
          description: model.description,
          canonical: true,
          context_limit: model.context_limit,
          cost_input: model.cost_input,
          cost_output: model.cost_output,
          features: model.features,
          modalities: model.modalities,
          status: "active",
          fingerprint: CatalogModel.fingerprint(%{key: key, name: model.name}),
          fetched_at: now
        }

      case Tokengate.Repo.get(CatalogModel, key) do
        nil ->
          %CatalogModel{}
          |> Ecto.Changeset.change(key: key)
          |> CatalogModel.changeset(attrs)
          |> Tokengate.Repo.insert()

        %CatalogModel{} = row ->
          row |> CatalogModel.changeset(attrs) |> Tokengate.Repo.update()
      end

      Enum.each(model.offers, fn offer ->
        offer_attrs = %{
          provider_key: offer.provider_key,
          model_key: key,
          provider_model: offer.provider_model,
          cost_input: offer.cost_input,
          cost_output: offer.cost_output,
          lifecycle: "stable",
          status: "active",
          fingerprint: CatalogModelOffer.fingerprint(offer),
          fetched_at: now
        }

        case Tokengate.Repo.get_by(CatalogModelOffer,
               provider_key: offer.provider_key,
               model_key: key
             ) do
          nil ->
            %CatalogModelOffer{}
            |> CatalogModelOffer.remote_changeset(offer_attrs)
            |> Tokengate.Repo.insert()

          %CatalogModelOffer{} = row ->
            row |> CatalogModelOffer.remote_changeset(offer_attrs) |> Tokengate.Repo.update()
        end
      end)
    end)

    :ok
  rescue
    e ->
      require Logger
      Logger.error("[catalog sync] code-owned models failed: #{Exception.message(e)}")
      :ok
  end
end
