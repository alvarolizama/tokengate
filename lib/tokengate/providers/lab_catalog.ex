defmodule Tokengate.Providers.LabCatalog do
  @moduledoc """
  models.dev labs: the knowledge that turns model ids into brands.

  ## There is no lab endpoint

  models.dev publishes providers (`/api.json`) and canonical models
  (`/models.json`) — no labs. A lab IS the prefix of a canonical model id:
  `anthropic/claude-opus-4.7` → lab `anthropic`. Everything this module knows
  is derived from those two payloads, the same way upstream's own site does it:

    * `key` — the prefix. Lowercase slug, unique, stable.
    * `name` — the provider of that id when models.dev has one (`anthropic` →
      `"Anthropic"`, `openai` → `"OpenAI"`), else the capitalized id
      (`arcee-ai` → `"Arcee Ai"`, `openbmb` → `"Openbmb"`). Two overrides
      (`@name_overrides`) exist because the provider of the same id carries a
      longer commercial name than the lab upstream displays.
    * `logo_url` — `https://models.dev/logos/labs/{key}.svg`, always. Like the
      provider logos, upstream answers with a generic mark for the labs it has
      no dedicated logo for; that is upstream's own behaviour and worth no
      special case here (`icon` covers "I want my own mark").
    * `model_count`, `last_released`, `last_updated` — exact counts/aggregates
      over the canonical model list, so they are data, not curation.

  Provider COUNT per lab is deliberately absent: upstream resolves it through
  per-provider `base_model` refs that live in their repo, not in the API. A
  number derived from the API alone would be wrong by an order of magnitude, so
  the catalog does not publish one.

  ## Snapshot vs live

  `snapshot/0` is the vendored `priv/models_dev/labs.json` (seed for an empty
  database and offline fallback, regenerable with
  `mix tokengate.labs.snapshot`); the live catalog is the `labs` table,
  refreshed by `CatalogRefreshWorker`. `derive/2` is the single derivation both
  paths use, so the snapshot and a refresh can never disagree by construction.
  """

  @base_url "https://models.dev"

  # The mark a lab without a logo falls back to. A lab is where models are
  # built, so the beaker is the generic "research lab" glyph.
  @default_icon "hero-beaker"

  # Labs whose display name upstream does NOT take from the provider of the
  # same id (upstream keeps these names in code, in its own LAB_NAME_OVERRIDES).
  # Only the two where the provider name differs, e.g. `minimax` is published
  # as "MiniMax (minimax.io)" but the lab is "MiniMax".
  @name_overrides %{
    "minimax" => "MiniMax",
    "stepfun" => "StepFun"
  }

  # Vendored snapshot of the derived catalog: seed for a fresh database and
  # offline fallback. The live catalog is the `labs` table.
  @snapshot_path Path.expand("../../../priv/models_dev/labs.json", __DIR__)
  @external_resource @snapshot_path
  @snapshot @snapshot_path |> File.read!() |> Jason.decode!()

  @doc "The models.dev origin this catalog is derived from."
  @spec base_url() :: String.t()
  def base_url, do: @base_url

  @doc "Hero icon used when a lab has no logo (builtins always carry one)."
  @spec default_icon() :: String.t()
  def default_icon, do: @default_icon

  @doc """
  The vendored snapshot as entries with atom keys, sorted by key.

  Seeds the `labs` table and doubles as a deterministic fixture.
  """
  @spec snapshot() :: [map()]
  def snapshot do
    @snapshot
    |> Enum.map(fn {key, entry} ->
      %{
        key: key,
        name: Map.get(entry, "name"),
        logo_url: Map.get(entry, "logo_url"),
        model_count: Map.get(entry, "model_count", 0),
        last_released: Map.get(entry, "last_released"),
        last_updated: Map.get(entry, "last_updated")
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  @doc "Number of labs in the vendored snapshot."
  @spec snapshot_size() :: non_neg_integer()
  def snapshot_size, do: map_size(@snapshot)

  @doc """
  Encodes entries for the vendored snapshot file (the wire format is the
  string-keyed map the file holds), sorted by key.
  """
  @spec encode_snapshot([map()]) :: map()
  def encode_snapshot(entries) do
    entries
    |> Enum.sort_by(& &1.key)
    |> Map.new(fn entry ->
      {entry.key,
       %{
         "name" => entry.name,
         "logo_url" => entry.logo_url,
         "model_count" => entry.model_count,
         "last_released" => entry.last_released,
         "last_updated" => entry.last_updated
       }}
    end)
  end

  @doc """
  Derives the lab catalog from the two models.dev payloads.

    * `models_payload` — `/models.json`: canonical models keyed by
      `lab/model` (the lab prefix is what makes a lab exist).
    * `provider_names` — `%{"anthropic" => "Anthropic", …}`, taken from the
      `/api.json` entries. Optional: without it every name is the capitalized
      id.

  Options:

    * `:logo_base_url` — origin the logo URLs point at (default: models.dev).
      Only the snapshot task sets it, to derive from a mirror.

  Returns entries sorted by key, each with `:key`, `:name`, `:logo_url`,
  `:model_count`, `:last_released` and `:last_updated`. Model ids without a
  `/` belong to no lab and are skipped (they cannot be attributed).
  """
  @spec derive(map(), map(), keyword()) :: [map()]
  def derive(models_payload, provider_names \\ %{}, opts \\ [])

  def derive(models_payload, provider_names, opts) when is_map(models_payload) do
    logo_base = Keyword.get(opts, :logo_base_url, @base_url)
    provider_names = if is_map(provider_names), do: provider_names, else: %{}

    models_payload
    |> Enum.reduce(%{}, fn
      {id, model}, acc when is_binary(id) ->
        case lab_id(id) do
          nil -> acc
          lab -> Map.update(acc, lab, accumulate(model), &merge_accumulator(&1, model))
        end

      _, acc ->
        acc
    end)
    |> Enum.map(fn {lab, acc} ->
      %{
        key: lab,
        name: lab_name(lab, provider_names),
        logo_url: logo_url(lab, logo_base),
        model_count: acc.model_count,
        last_released: acc.last_released,
        last_updated: acc.last_updated
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  def derive(_models_payload, _provider_names, _opts), do: []

  @doc """
  The lab a canonical model id belongs to (`"anthropic/claude-opus-4.7"` →
  `"anthropic"`), or nil when the id carries no lab prefix.

      iex> Tokengate.Providers.LabCatalog.lab_id("anthropic/claude-opus-4.7")
      "anthropic"

      iex> Tokengate.Providers.LabCatalog.lab_id("claude-opus-4.7")
      nil
  """
  @spec lab_id(String.t()) :: String.t() | nil
  def lab_id(model_id) when is_binary(model_id) do
    case String.split(model_id, "/", parts: 2) do
      [lab, model] when lab != "" and model != "" -> lab
      _ -> nil
    end
  end

  def lab_id(_), do: nil

  @doc """
  Display name for a lab id: the override, else the models.dev provider name of
  that id, else the capitalized id.

      iex> Tokengate.Providers.LabCatalog.lab_name("openai", %{"openai" => "OpenAI"})
      "OpenAI"

      iex> Tokengate.Providers.LabCatalog.lab_name("arcee-ai", %{})
      "Arcee Ai"

      iex> Tokengate.Providers.LabCatalog.lab_name("minimax", %{"minimax" => "MiniMax (minimax.io)"})
      "MiniMax"
  """
  @spec lab_name(String.t(), map()) :: String.t()
  def lab_name(lab_id, provider_names \\ %{}) when is_binary(lab_id) do
    Map.get(@name_overrides, lab_id) || provider_name(provider_names, lab_id) ||
      default_name(lab_id)
  end

  @doc """
  Upstream logo URL for a lab (a dedicated one, or upstream's generic mark when
  models.dev has no logo for that lab — the same deal as provider logos).
  """
  @spec logo_url(String.t(), String.t()) :: String.t()
  def logo_url(lab_id, base_url \\ @base_url) when is_binary(lab_id) do
    "#{String.trim_trailing(base_url, "/")}/logos/labs/#{lab_id}.svg"
  end

  ## Accumulation ------------------------------------------------------------

  defp accumulate(model) when is_map(model) do
    %{
      model_count: 1,
      last_released: iso_field(model, "release_date"),
      last_updated: iso_field(model, "last_updated")
    }
  end

  defp accumulate(_model), do: %{model_count: 1, last_released: nil, last_updated: nil}

  defp merge_accumulator(acc, model) do
    %{
      model_count: acc.model_count + 1,
      last_released: max_iso(acc.last_released, iso_field(model, "release_date")),
      last_updated: max_iso(acc.last_updated, iso_field(model, "last_updated"))
    }
  end

  defp iso_field(model, field) when is_map(model) do
    case Map.get(model, field) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp iso_field(_model, _field), do: nil

  # Upstream mixes day and month precision ("2026-09-12", "2026-09"): the
  # values are kept verbatim, and ISO-8601 orders correctly as strings, because
  # a prefix sorts before its longer forms.
  defp max_iso(nil, value), do: value
  defp max_iso(value, nil), do: value
  defp max_iso(a, b), do: if(a < b, do: b, else: a)

  ## Naming ------------------------------------------------------------------

  defp provider_name(names, lab_id) when is_map(names) do
    case Map.get(names, lab_id) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp provider_name(_names, _lab_id), do: nil

  # Upstream's fallback, kept identical on purpose: split on dashes, capitalize
  # each part ("arcee-ai" → "Arcee Ai").
  defp default_name(lab_id) do
    lab_id
    |> String.split("-")
    |> Enum.map_join(" ", fn part ->
      case String.next_grapheme(part) do
        {first, rest} -> String.upcase(first) <> rest
        nil -> ""
      end
    end)
  end
end
