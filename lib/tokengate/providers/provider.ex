defmodule Tokengate.Providers.Provider do
  @moduledoc """
  A provider is an upstream LLM API that TokenGate routes requests to.

  Providers come in two flavours:

    * `builtin` — materialized from `Tokengate.Providers.Catalog` (the
      compile-time catalog) and kept in sync at boot by
      `Tokengate.Providers.CatalogSync`. Identity fields (`key`,
      `base_url`, `dialect`, `capabilities`) are catalog-owned and
      read-only for operators.
    * `custom` — operator-created rows with the same contract. Everything
      except `key` (nil for customs) is editable.

  The single `base_url` is the root for every endpoint; the adapter for
  the provider's `dialect` derives `/chat/completions`, `/models` and
  `/embeddings` from it. No per-endpoint URL overrides.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tokengate.Providers.Catalog

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active disabled)

  schema "providers" do
    field :name, :string
    # Base URL root for every endpoint; the dialect adapter derives
    # /chat/completions, /models and /embeddings from it.
    field :base_url, :string
    # Per-service full-URL overrides for custom providers (nil = derive
    # from base_url). Builtins never set them.
    field :chat_url, :string
    field :models_url, :string
    field :embeddings_url, :string
    # Catalog identity: set for builtins, nil for customs.
    field :key, :string
    field :source, :string, default: "custom"
    field :dialect, :string, default: "openai"
    field :capabilities, {:array, :string}, default: ["llm"]
    field :status, :string, default: "active"

    has_many :credentials, Tokengate.Providers.Credential

    timestamps(type: :utc_datetime)
  end

  @identity_fields [:name, :base_url, :dialect, :capabilities]

  @doc false
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :name,
      :base_url,
      :chat_url,
      :models_url,
      :embeddings_url,
      :key,
      :source,
      :dialect,
      :capabilities,
      :status
    ])
    |> validate_required([:name, :base_url])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, Catalog.sources())
    |> validate_inclusion(:dialect, Catalog.dialects())
    |> validate_subset(:capabilities, Catalog.capabilities())
    |> put_default_source()
    |> normalize_urls()
    |> unique_constraint(:name)
    |> unique_constraint(:key, name: :providers_builtin_key_unique_index)
    |> lock_builtin_identity()
  end

  @doc "List of valid status values"
  def statuses, do: @statuses

  # Fresh custom rows default to source custom / dialect openai / llm-only
  # when the attrs don't say otherwise.
  defp put_default_source(changeset) do
    changeset
    |> put_default(:source, "custom")
    |> put_default(:dialect, "openai")
  end

  defp put_default(changeset, field, default) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, default)
      _ -> changeset
    end
  end

  # Builtin identity is catalog-owned: once a row is builtin, operators
  # can only flip its status (enable/disable) — name, base_url, dialect
  # and capabilities come from the catalog sync alone.
  defp lock_builtin_identity(changeset) do
    if get_field(changeset, :source) == "builtin" do
      Enum.reduce(@identity_fields, changeset, fn field, acc ->
        if changing?(acc, field), do: delete_change(acc, field), else: acc
      end)
    else
      changeset
    end
  end

  defp changing?(changeset, field), do: Map.has_key?(changeset.changes, field)

  # Trim trailing slashes and normalize empty strings to nil on every URL
  # field, so the adapter falls back to the base_url-derived path.
  defp normalize_urls(changeset) do
    Enum.reduce([:base_url, :chat_url, :models_url, :embeddings_url], changeset, fn field, acc ->
      case get_change(acc, field) do
        nil -> acc
        "" -> put_change(acc, field, nil)
        url -> put_change(acc, field, String.trim_trailing(url, "/"))
      end
    end)
  end
end
