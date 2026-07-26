defmodule Tokengate.Observability.Destination do
  @moduledoc """
  An observability destination for exporting telemetry (OTLP webhooks, etc.).

  Organizations configure destinations to receive observability data. The
  `privacy_mode` controls what data is exported: `metadata_only` (no
  prompt/completion content) or `full`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(otlp_webhook)
  @privacy_modes ~w(metadata_only full)

  schema "observability_destinations" do
    field :name, :string
    field :type, :string, default: "otlp_webhook"
    field :url, :string
    field :headers, :map, default: %{}
    field :privacy_mode, :string, default: "metadata_only"

    belongs_to :organization, Tokengate.Accounts.Organization

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(organization_id name type url headers privacy_mode)a
  @required ~w(organization_id name type privacy_mode)a

  @doc false
  def changeset(destination, attrs) do
    destination
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:privacy_mode, @privacy_modes)
    |> foreign_key_constraint(:organization_id)
  end

  @doc "List of valid destination types"
  def types, do: @types

  @doc "List of valid privacy modes"
  def privacy_modes, do: @privacy_modes
end
