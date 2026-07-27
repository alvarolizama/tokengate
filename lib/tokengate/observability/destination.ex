defmodule Tokengate.Observability.Destination do
  @moduledoc """
  An observability destination for exporting telemetry (OTLP webhooks, etc.).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(otlp_webhook)

  schema "observability_destinations" do
    field :name, :string
    field :type, :string, default: "otlp_webhook"
    field :url, :string
    field :headers, :map, default: %{}

    belongs_to :team, Tokengate.Accounts.Team

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(name type url headers team_id)a
  @required ~w(name type team_id)a

  @doc false
  def changeset(destination, attrs) do
    destination
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_inclusion(:type, @types)
  end

  @doc "List of valid destination types"
  def types, do: @types
end
