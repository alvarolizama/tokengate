defmodule Tokengate.Providers.Provider do
  @moduledoc """
  A provider is an upstream LLM API (OpenAI, Anthropic, etc.) that
  TokenGate routes requests to.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active disabled)

  schema "providers" do
    field :name, :string
    field :base_url, :string
    field :status, :string, default: "active"

    has_many :credentials, Tokengate.Providers.Credential

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:name, :base_url, :status])
    |> validate_required([:name, :base_url])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:name)
  end

  @doc "List of valid status values"
  def statuses, do: @statuses
end
