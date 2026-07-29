defmodule Tokengate.Accounts.ServiceApiKey do
  @moduledoc """
  API key for a service (not tied to a user).
  One active key per service at a time.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "service_api_keys" do
    belongs_to :service, Tokengate.Accounts.Service
    field :key_hash, :string
    field :key_prefix, :string
    field :status, :string, default: "active"

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(service_id key_hash key_prefix status)a
  @required ~w(service_id key_hash key_prefix)a

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_inclusion(:status, ["active", "revoked"])
    |> unique_constraint(:service_id)
    |> unique_constraint(:key_hash)
    |> assoc_constraint(:service)
  end
end
