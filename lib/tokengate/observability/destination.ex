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
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(name type url headers enabled)a
  @required ~w(name type url)a

  @doc false
  def changeset(destination, attrs) do
    destination
    |> cast(attrs, @permitted)
    |> update_change(:url, &trim_or_nil/1)
    |> validate_required(@required)
    |> validate_inclusion(:type, @types)
    |> validate_http_url(:url)
  end

  @doc "List of valid destination types"
  def types, do: @types

  defp trim_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_or_nil(value), do: value

  defp validate_http_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case URI.parse(value) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [{field, "must be a valid http(s) URL"}]
      end
    end)
  end
end
