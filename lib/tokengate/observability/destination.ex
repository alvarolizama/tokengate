defmodule Tokengate.Observability.Destination do
  @moduledoc """
  An observability destination for exporting telemetry (OTLP webhooks, etc.).

  Un destino NO pertenece a ningún sujeto: la observabilidad es de toda la
  instalación, así que cada webhook recibe la telemetría de todos los
  miembros. (Antes colgaba de un perfil de límites y sólo recibía la suya.)
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

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(name type url headers)a
  @required ~w(name type)a

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
