defmodule Tokengate.Providers.Lab do
  @moduledoc """
  A LAB in the catalog: who built the model, as opposed to who serves it.

  models.dev has no lab payload — a lab is the PREFIX of a canonical model id
  (`anthropic/claude-opus-4.7` → `anthropic`) — so the remote half of this
  table is DERIVED (`LabCatalog.derive/2`) and refreshed by
  `CatalogRefreshWorker`. Two owners share the table, split by `source`:

    * `"builtin"` — stamped from models.dev. `name`, `logo_url`, `model_count`,
      `last_released` and `last_updated` are catalog-owned (`changeset/2`
      strips them, exactly like `Provider` locks a builtin's identity); the
      refresh writes them through `remote_changeset/2`.
    * `"custom"` — operator-created (a lab models.dev does not publish). The
      operator owns `name`, `logo_url` and `icon`; the refresh never sees it
      (`source = 'builtin'` filters every write it makes).

  `icon` and `logo_url` are the two faces of the same thing: the mark to show
  next to a model. `logo_url` is a remote SVG/PNG; `icon` is a hero icon name
  (`"hero-beaker"`, the `LabCatalog.default_icon/0`) used when there is no
  logo — a custom lab can carry either, or both (the logo wins in the UI).

  `status` mirrors the provider side: `"stale"` means models.dev no longer
  publishes that lab. It is marked, never deleted — a model may already be
  attributed to it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tokengate.Providers.LabCatalog

  @primary_key {:key, :string, autogenerate: false}
  @sources ~w(builtin custom)
  @statuses ~w(active stale)

  # models.dev lab ids are lowercase slugs (`anthropic`, `arcee-ai`,
  # `swiss-ai`). Pinned in the changeset so a typo becomes an error instead of
  # a lab nothing can ever join to.
  @key_format ~r/^[a-z0-9][a-z0-9._-]*$/

  # Hero icon names, e.g. "hero-beaker". The UI resolves them through the
  # `.icon` component, which renders the class as-is.
  @icon_format ~r/^hero-[a-z0-9-]+$/

  # Fields the catalog owns on a builtin row (see the moduledoc).
  @identity_fields [:name, :logo_url, :model_count, :last_released, :last_updated]

  schema "labs" do
    field :name, :string
    # Mark: the models.dev logo (`/logos/labs/{key}.svg`) for builtin labs;
    # custom labs may point it anywhere (a hosted PNG, an in-app asset). When
    # both `logo_url` and `icon` are set the logo wins.
    field :logo_url, :string
    # Fallback hero icon (`hero-beaker`) when there is no logo. Optional.
    field :icon, :string
    field :source, :string, default: "builtin"
    field :status, :string, default: "active"
    field :model_count, :integer, default: 0
    # Upstream dates, verbatim: models.dev publishes day precision
    # ("2026-09-12") and month precision ("2026-09") in the same field.
    field :last_released, :string
    field :last_updated, :string
    field :fingerprint, :string
    field :fetched_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Valid sources (`builtin` | `custom`)."
  def sources, do: @sources

  @doc "Valid statuses (`active` | `stale`)."
  def statuses, do: @statuses

  @doc """
  The mark to render for a lab: the remote `logo_url` when there is one, else a
  hero icon.

  This is the whole point of `icon`: a custom lab may have no logo at all, and
  the UI still needs something to show.

      iex> Tokengate.Providers.Lab.mark(%Tokengate.Providers.Lab{logo_url: "https://x/l.svg", icon: "hero-beaker"})
      {:logo, "https://x/l.svg"}

      iex> Tokengate.Providers.Lab.mark(%Tokengate.Providers.Lab{icon: "hero-flask"})
      {:icon, "hero-flask"}

      iex> Tokengate.Providers.Lab.mark(%Tokengate.Providers.Lab{})
      {:icon, "hero-beaker"}
  """
  @spec mark(%__MODULE__{}) :: {:logo, String.t()} | {:icon, String.t()}
  def mark(%__MODULE__{logo_url: logo_url}) when is_binary(logo_url) and logo_url != "" do
    {:logo, logo_url}
  end

  def mark(%__MODULE__{icon: icon}) when is_binary(icon) and icon != "", do: {:icon, icon}

  def mark(%__MODULE__{}), do: {:icon, LabCatalog.default_icon()}

  @doc """
  Digest of the upstream-visible fields of a lab entry.

  Two refreshes that see the same lab produce the same fingerprint, so an
  unchanged row is a single comparison and no write. `icon` and `source` are
  deliberately outside it: they are operator-owned, not remote facts.
  """
  @spec fingerprint(map()) :: String.t()
  def fingerprint(entry) when is_map(entry) do
    payload =
      Enum.map([:name, :logo_url, :model_count, :last_released, :last_updated], fn field ->
        {field, Map.get(entry, field)}
      end)

    :crypto.hash(:sha256, :erlang.term_to_binary(payload))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  Operator changeset.

  Casts the operator-owned fields (plus `key`, needed on insert) and locks the
  catalog-owned ones on a builtin row: a builtin's name and logo come from
  models.dev, not from the form.
  """
  def changeset(lab, attrs) do
    lab
    |> cast(attrs, [:key, :name, :logo_url, :icon, :source, :status])
    |> validate_required([:key, :name])
    |> normalize_key()
    |> validate_format(:key, @key_format,
      message: "lowercase, digits, dot, dash and underscore only"
    )
    |> validate_length(:key, max: 60)
    |> validate_format(:icon, @icon_format, message: "must be a hero icon name, e.g. hero-beaker")
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:status, @statuses)
    |> normalize_url()
    |> normalize_icon()
    |> lock_builtin_identity()
    |> unique_constraint(:key, name: :labs_pkey)
  end

  @doc """
  Catalog changeset: the remote fields the refresh owns, and only those.

  Used by `CatalogRefreshWorker` and the seed, which write rows the operator
  cannot edit anyway. `source` and `key` are set by the caller (insert) and
  never changed here, so a refresh can neither promote a custom row to builtin
  nor re-key one.
  """
  def remote_changeset(lab, attrs) do
    lab
    |> cast(attrs, [
      :name,
      :logo_url,
      :model_count,
      :last_released,
      :last_updated,
      :status,
      :fingerprint,
      :fetched_at
    ])
    |> validate_required([:name])
    |> validate_inclusion(:status, @statuses)
  end

  # The refresh is guarded by `source = 'builtin'` in its queries, so reaching
  # this clause with a builtin row means catalog data being written through the
  # operator path: strip exactly what the catalog owns.
  defp lock_builtin_identity(changeset) do
    if get_field(changeset, :source) == "builtin" do
      Enum.reduce(@identity_fields, changeset, fn field, acc ->
        if Map.has_key?(acc.changes, field), do: delete_change(acc, field), else: acc
      end)
    else
      changeset
    end
  end

  # Case is folded so "OpenAI" y "openai" can never both exist; the format
  # check then still rejects anything beyond [a-z0-9._-].
  defp normalize_key(changeset) do
    case get_change(changeset, :key) do
      nil -> changeset
      key -> put_change(changeset, :key, key |> String.trim() |> String.downcase())
    end
  end

  defp normalize_url(changeset) do
    case get_change(changeset, :logo_url) do
      nil -> changeset
      "" -> put_change(changeset, :logo_url, nil)
      url -> put_change(changeset, :logo_url, String.trim_trailing(url, "/"))
    end
  end

  # An empty icon means "no fallback chosen": store nil, so "unset" has exactly
  # one representation and the UI can fall back to the default.
  defp normalize_icon(changeset) do
    case get_change(changeset, :icon) do
      nil -> changeset
      "" -> put_change(changeset, :icon, nil)
      icon -> put_change(changeset, :icon, String.trim(icon))
    end
  end
end
