defmodule Tokengate.Observability do
  @moduledoc """
  The Observability context: manages telemetry export destinations.
  """

  import Ecto.Query, warn: false

  alias Tokengate.Repo
  alias Tokengate.Observability.Destination

  # ---------------------------------------------------------------------------
  # Destinations
  # ---------------------------------------------------------------------------

  @doc "Returns all observability destinations."
  def list_destinations, do: Repo.all(Destination)

  @doc "Returns all destinations for a given organization."
  def list_destinations_for_org(organization_id) do
    Repo.all(from d in Destination, where: d.organization_id == ^organization_id)
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
