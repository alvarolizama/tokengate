defmodule Tokengate.Providers.Credential do
  @moduledoc """
  API credentials for a provider. The `api_key_encrypted` field stores
  the key as-is for now; encryption-at-rest is a post-MVP concern.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active disabled)

  schema "provider_credentials" do
    field :api_key_encrypted, :string
    field :max_rpm, :integer
    field :max_concurrent, :integer
    field :status, :string, default: "active"

    belongs_to :provider, Tokengate.Providers.Provider

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:provider_id, :api_key_encrypted, :max_rpm, :max_concurrent, :status])
    |> validate_required([:provider_id, :api_key_encrypted, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:provider_id)
  end

  @doc "List of valid status values"
  def statuses, do: @statuses
end
