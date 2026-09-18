defmodule Tokengate.Providers.ProviderPaths do
  @moduledoc """
  Effective upstream path for one service of one provider.

  A provider declares a single `base_url`; every service it exposes lives at
  `base_url` + a path. That path resolves in three tiers, highest first:

    1. **the provider's own override** — `providers.path_overrides`, set from
       the Capacidades modal in the providers screen. What the operator typed
       wins: it is the only tier that describes the endpoint actually in front
       of them.
    2. **the catalog code override** — `Catalog.@customizations` (`:paths`), a
       builtin whose service does not live where the generic surface says (an
       exotic segment, or another host entirely). Travels with the release.
    3. **the generic default** — the OpenAI-compatible surface (`@services`),
       which is what OpenRouter, Fireworks and every `openai`/`openrouter`
       dialect provider speak.

  A path is a suffix (`/chat/completions`). **An absolute URL is allowed in
  any tier** (`https://other-host/v1/rerank`): the adapter returns it as-is
  instead of prefixing the base URL, which is how a service living on another
  host is declared.

  The service vocabulary is closed and lives here; `providers.path_overrides`
  stores it with string keys, the catalog code uses the matching atom.
  """

  alias Tokengate.Providers.Catalog

  use Gettext, backend: TokengateWeb.Gettext

  # The service vocabulary. `key` is what `providers.path_overrides` stores and
  # what the Capacidades modal renders; `path_key` is the atom the code tier
  # (`Catalog.@customizations` `:paths`) uses; `default` is the generic
  # OpenAI-compatible suffix. Order is the order the modal displays them in.
  @services [
    %{key: "chat", path_key: :chat, label: "Chat / completions", default: "/chat/completions"},
    %{key: "models", path_key: :models, label: "Models catalog", default: "/models"},
    %{key: "embeddings", path_key: :embeddings, label: "Embeddings", default: "/embeddings"},
    %{key: "rerank", path_key: :rerank, label: "Rerank", default: "/rerank"},
    %{
      key: "stt",
      path_key: :stt,
      label: "Transcription (audio → text)",
      default: "/audio/transcriptions"
    },
    %{key: "tts", path_key: :tts, label: "Speech (text → audio)", default: "/audio/speech"},
    %{key: "image", path_key: :image, label: "Images", default: "/images/generations"},
    %{key: "video", path_key: :video, label: "Videos", default: "/videos"},
    %{key: "music", path_key: :music, label: "Music", default: "/music/generations"}
  ]

  @keys Enum.map(@services, & &1.key)

  @doc """
  The service vocabulary in display order: `%{key:, label:, default:}`.

  Used to render the Capacidades modal and to validate `path_overrides`.
  """
  @spec services() :: [%{key: String.t(), label: String.t(), default: String.t()}]
  # Las etiquetas de `@services` son msgid en inglés (data estática: `gettext/1`,
  # que es un macro, no puede evaluarse en un atributo de módulo): se traducen
  # aquí, al construir la lista que consume el selector.
  def services do
    Enum.map(@services, fn entry ->
      entry
      |> Map.take([:key, :label, :default])
      |> Map.update!(:label, &TokengateWeb.Gettext.translate/1)
    end)
  end

  @doc "Valid `path_overrides` keys."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc """
  The operator's overrides for a provider (empty when it has none).

  Reads `path_overrides` off a `Provider` struct or off any provider map (the
  routing cache hands plain maps to the adapters).
  """
  @spec overrides(map() | nil) :: map()
  def overrides(provider) do
    case field(provider, :path_overrides) do
      %{} = overrides -> overrides
      _ -> %{}
    end
  end

  @doc """
  The path resolved for one service of one provider (see the moduledoc tiers).

  `service` is either the vocabulary key (`"chat"`) or its code atom (`:chat`).
  Returns `nil` for a service outside the vocabulary, so a caller always keeps
  its own last-resort default.
  """
  @spec resolve(map() | nil, String.t() | atom()) :: String.t() | nil
  def resolve(provider, service) do
    case find(service) do
      nil -> nil
      entry -> resolve_entry(provider, entry)
    end
  end

  @doc """
  Everything the Capacidades modal needs about one service: the vocabulary
  entry, what the operator set, what the catalog hardcodes, which one wins and
  where the winner came from (`:provider`, `:catalog` or `:default`).
  """
  @spec describe(map() | nil, String.t() | atom()) :: map() | nil
  def describe(provider, service) do
    case find(service) do
      nil -> nil
      entry -> entry |> describe_entry(provider) |> with_source()
    end
  end

  @doc "`describe/2` for every service, in display order."
  @spec describe_all(map() | nil) :: [map()]
  def describe_all(provider) do
    Enum.map(@services, &(&1 |> describe_entry(provider) |> with_source()))
  end

  @doc """
  Normalizes an operator-supplied override map into what the column stores.

    * keys must be known services (the vocabulary is closed);
    * values are trimmed, and blank means "inherit" — the key is dropped;
    * a non-blank value must be a `/`-rooted path or an absolute http(s) URL,
      and its trailing slash is trimmed (`/` itself stays `/`).

  Returns `{:ok, overrides}` or `{:error, message}`, the message being a
  Spanish, UI-ready sentence.
  """
  @spec normalize(map() | nil) :: {:ok, map()} | {:error, String.t()}
  def normalize(nil), do: {:ok, %{}}

  def normalize(params) when is_map(params) do
    Enum.reduce_while(params, {:ok, %{}}, fn {service, value}, {:ok, acc} ->
      key = to_string(service)

      case find(key) do
        nil ->
          {:halt, {:error, "Capacidad desconocida: #{key}."}}

        entry ->
          case normalize_value(value) do
            {:ok, nil} ->
              {:cont, {:ok, acc}}

            {:ok, path} ->
              {:cont, {:ok, Map.put(acc, key, path)}}

            :error ->
              {:halt,
               {:error,
                gettext(
                  "The path of “%{label}” must start with / or be an absolute http(s) URL, or be empty to inherit the default.",
                  label: entry.label
                )}}
          end
      end
    end)
  end

  ## Internals #################################################################

  defp resolve_entry(provider, entry) do
    override(provider, entry) || catalog_path(provider, entry) || entry.default
  end

  defp describe_entry(entry, provider) do
    override = override(provider, entry)
    catalog = catalog_path(provider, entry)

    %{
      key: entry.key,
      label: entry.label,
      default: entry.default,
      override: override,
      catalog: catalog,
      effective: override || catalog || entry.default
    }
  end

  defp with_source(%{override: override, catalog: catalog} = description) do
    source =
      cond do
        override -> :provider
        catalog -> :catalog
        true -> :default
      end

    Map.put(description, :source, source)
  end

  # Tier 1: what the operator set for this provider.
  defp override(provider, entry) do
    case Map.get(overrides(provider), entry.key) do
      value when is_binary(value) -> present(value)
      _ -> nil
    end
  end

  # Tier 2: what the catalog hardcodes for this provider (code, not data).
  defp catalog_path(provider, entry) do
    key = Map.get(provider || %{}, :key) || Map.get(provider || %{}, "key")

    if is_binary(key) do
      key
      |> Catalog.path_suffix(service: entry.path_key, default: nil)
      |> present()
    end
  end

  defp find(service) when is_binary(service), do: Enum.find(@services, &(&1.key == service))
  defp find(service) when is_atom(service), do: Enum.find(@services, &(&1.path_key == service))
  defp find(_service), do: nil

  defp field(provider, key) when is_map(provider) do
    Map.get(provider, key) || Map.get(provider, to_string(key))
  end

  defp field(_provider, _key), do: nil

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp normalize_value(value) when is_binary(value) do
    case present(value) do
      nil -> {:ok, nil}
      path -> if path?(path), do: {:ok, trim_path(path)}, else: :error
    end
  end

  # A null value means the same as a blank one: inherit.
  defp normalize_value(nil), do: {:ok, nil}

  defp normalize_value(_value), do: :error

  defp path?(path) do
    String.starts_with?(path, "/") or String.starts_with?(path, "http://") or
      String.starts_with?(path, "https://")
  end

  # "/" is the root of the base URL, not a blank: keep it.
  defp trim_path(path) do
    case String.trim_trailing(path, "/") do
      "" -> "/"
      trimmed -> trimmed
    end
  end
end
