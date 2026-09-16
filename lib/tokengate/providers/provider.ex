defmodule Tokengate.Providers.Provider do
  @moduledoc """
  A provider is an upstream LLM API that TokenGate routes requests to.

  Providers come in two flavours:

    * `builtin` — materialized from the models.dev catalog mirror
      (`catalog_providers` + the code customizations in
      `Tokengate.Providers.Catalog`) and kept in sync at boot by
      `Tokengate.Providers.CatalogSync`. Identity fields (`key`, `name`,
      `base_url`, `doc_url`, `logo_url`, `dialect`, `capabilities`) are
      catalog-owned and read-only for operators.
    * `custom` — operator-created rows with the same contract. Everything
      except `key` (nil for customs) is editable.

  The single `base_url` is the root for every endpoint; the adapter for
  the provider's `dialect` derives `/chat/completions`, `/models` and
  `/embeddings` from it, with the catalog code customizations and the
  operator's own overrides as the escape hatches (see
  `Tokengate.Providers.ProviderPaths`). Per-endpoint URLs are still not
  stored one by one: they are paths relative to the one base URL.

  Beyond its identity, a provider holds the operational limits
  (`max_rpm`, `max_concurrent`, `max_concurrent_per_user`,
  `receive_timeout_ms`) and its per-service `path_overrides` — both
  inherited by every one of its credentials, and both editable for builtins
  too. Identity is not.
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias Tokengate.Providers.{Catalog, ProviderPaths}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active disabled)

  schema "providers" do
    field :name, :string
    # Base URL root for every endpoint; the dialect adapter derives
    # /chat/completions, /models and /embeddings from it.
    field :base_url, :string
    # Catalog identity for display: the provider's docs and logo, stamped
    # from the models.dev mirror by CatalogSync (customs set them by hand).
    field :doc_url, :string
    field :logo_url, :string
    # Catalog identity: set for builtins, nil for customs.
    field :key, :string
    field :source, :string, default: "custom"
    field :dialect, :string, default: "openai"
    # Billing surface of the provider: "subscription" (flat-rate plan,
    # rate-limited) or "pay_per_token". Builtins get it from the catalog
    # (CatalogSync); customs pick it once at creation. This is the single
    # source of truth for routing tiers / cost / sticky defaults.
    field :billing_type, :string, default: "pay_per_token"
    field :capabilities, {:array, :string}, default: ["llm"]
    field :status, :string, default: "active"

    # Operational limits, provider-wide: every credential of this provider
    # (which is only an alias + secret) inherits them. `nil` means unlimited,
    # except `receive_timeout_ms`, where `nil` means "use the global config
    # default" (see `Tokengate.Providers.ProviderLimits`).
    #
    # These are NOT identity fields: a builtin's name/base_url/dialect stay
    # catalog-owned (see `lock_builtin_identity/1`) while its throttle stays
    # operator-editable.
    field :max_rpm, :integer
    field :max_concurrent, :integer
    field :max_concurrent_per_user, :integer
    field :receive_timeout_ms, :integer

    # Per-service path suffixes, keyed by the closed vocabulary in
    # `ProviderPaths.keys/0` (chat, models, embeddings, rerank, stt, tts,
    # image, video, music). An absent key inherits — the catalog code
    # override first, then the generic adapter default. Not identity: a
    # builtin keeps its catalog name/base_url/dialect while the operator
    # tunes where each service lives.
    field :path_overrides, :map, default: %{}

    has_many :credentials, Tokengate.Providers.Credential

    timestamps(type: :utc_datetime)
  end

  @identity_fields [:name, :base_url, :doc_url, :logo_url, :dialect, :capabilities]

  # Operational (non-identity) fields, editable for builtins too:
  # `lock_builtin_identity/1` only strips `@identity_fields`, so a catalog
  # provider keeps its identity while the operator still tunes its limits and
  # its per-service paths.
  @limit_fields [:max_rpm, :max_concurrent, :max_concurrent_per_user, :receive_timeout_ms]

  # Billing surface is not identity: customs choose it, builtins get it from
  # the catalog. Both stay editable through the shared cast list.
  @billing_types ~w(subscription pay_per_token)

  @doc false
  def changeset(provider, attrs) do
    provider
    |> cast(
      attrs,
      [
        :name,
        :base_url,
        :doc_url,
        :logo_url,
        :key,
        :source,
        :dialect,
        :billing_type,
        :capabilities,
        :status,
        :path_overrides
      ] ++ @limit_fields
    )
    |> validate_required([:name, :base_url])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, Catalog.sources())
    |> validate_inclusion(:dialect, Catalog.dialects())
    |> validate_inclusion(:billing_type, @billing_types)
    |> validate_subset(:capabilities, Catalog.capabilities())
    |> validate_path_overrides()
    |> validate_limits()
    |> put_default_source()
    |> normalize_urls()
    |> unique_constraint(:name)
    |> unique_constraint(:key, name: :providers_builtin_key_unique_index)
    |> lock_builtin_identity()
  end

  # Blank means "no limit" (nil), never 0: a 0 limit would rate-limit or
  # block every single request instead of lifting the gate.
  defp validate_limits(changeset) do
    Enum.reduce(@limit_fields, changeset, fn field, acc ->
      validate_number(acc, field, greater_than: 0, message: "debe ser mayor a 0")
    end)
  end

  # Path overrides are validated and normalized as one unit: the vocabulary is
  # closed (a typo becomes an error instead of a silently unused key) and a
  # blank value is dropped here, so the column only ever holds real overrides
  # and "empty" has exactly one representation.
  defp validate_path_overrides(changeset) do
    case get_change(changeset, :path_overrides) do
      %{} = overrides ->
        case ProviderPaths.normalize(overrides) do
          {:ok, normalized} -> put_change(changeset, :path_overrides, normalized)
          {:error, message} -> add_error(changeset, :path_overrides, message)
        end

      _ ->
        changeset
    end
  end

  @doc "List of valid status values"
  def statuses, do: @statuses

  @doc "List of valid billing surfaces"
  def billing_types, do: @billing_types

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
    Enum.reduce([:base_url, :doc_url, :logo_url], changeset, fn field, acc ->
      case get_change(acc, field) do
        nil -> acc
        "" -> put_change(acc, field, nil)
        url -> put_change(acc, field, String.trim_trailing(url, "/"))
      end
    end)
  end
end
