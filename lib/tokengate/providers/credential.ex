defmodule Tokengate.Providers.Credential do
  @moduledoc """
  API credentials for a provider. The `api_key_encrypted` field stores
  the key as-is for now; encryption-at-rest is a post-MVP concern.

  ## Status

    * `active`   – credential is eligible for routing.
    * `disabled` – manually disabled by an admin; excluded from routing.
    * `error`    – automatically disabled after a provider returned a
                   401/402/403 (auth or billing failure). Must be
                   reactivated manually from the dashboard.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active disabled error)

  schema "provider_credentials" do
    field :name, :string
    field :api_key_encrypted, :string
    field :max_rpm, :integer
    field :max_concurrent, :integer
    field :status, :string, default: "active"
    field :error_reason, :string
    field :error_at, :utc_datetime

    belongs_to :provider, Tokengate.Providers.Provider
    has_many :model_providers, Tokengate.Providers.ModelProvider

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :provider_id,
      :name,
      :api_key_encrypted,
      :max_rpm,
      :max_concurrent,
      :status,
      :error_reason,
      :error_at
    ])
    |> validate_required([:provider_id, :api_key_encrypted, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:provider_id)
  end

  @doc "List of valid status values"
  def statuses, do: @statuses
end
