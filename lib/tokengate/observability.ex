defmodule Tokengate.Observability do
  @moduledoc """
  The Observability context: manages telemetry export destinations.

  Los destinos son globales: la observabilidad es de toda la instalación, no
  de un grupo. Cada webhook recibe la telemetría de todos los sujetos.
  """

  import Ecto.Query, warn: false
  alias Tokengate.Repo
  alias Tokengate.Observability.Destination

  # ---------------------------------------------------------------------------
  # Destinations
  # ---------------------------------------------------------------------------

  @doc """
  Returns all destinations, ordered by name. Every destination receives the
  telemetry of the whole installation — there is no per-group scoping.
  """
  def list_all_destinations do
    Repo.all(from d in Destination, order_by: [asc: d.name])
  end

  @doc "Gets a single destination. Raises if not found."
  def get_destination!(id), do: Repo.get!(Destination, id)

  @doc "Gets a single destination. Returns nil if not found."
  def get_destination(id), do: Repo.get(Destination, id)

  @doc "Creates a destination."
  def create_destination(attrs) do
    %Destination{}
    |> Destination.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates a destination."
  def update_destination(%Destination{} = destination, attrs) do
    destination
    |> Destination.changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes a destination."
  def delete_destination(%Destination{} = destination), do: Repo.delete(destination)

  @doc "Returns a changeset for tracking destination changes."
  def change_destination(%Destination{} = destination, attrs \\ %{}) do
    Destination.changeset(destination, attrs)
  end
end
