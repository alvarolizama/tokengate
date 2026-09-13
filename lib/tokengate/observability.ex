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

  @doc "Returns all observability destinations for the given group."
  def list_destinations(group_id) do
    Repo.all(from d in Destination, where: d.group_id == ^group_id)
  end

  @doc """
  Returns all observability destinations for the given groups in a single
  query, grouped by group_id (`%{group_id => [Destination]}`). Groups without
  destinations are absent from the map — callers should default to `[]`.
  """
  def list_destinations_for_groups(group_ids) when is_list(group_ids) do
    Repo.all(from d in Destination, where: d.group_id in ^group_ids)
    |> Enum.group_by(& &1.group_id)
  end

  @doc "Returns all destinations ordered by name."
  def list_all_destinations do
    Repo.all(from d in Destination, order_by: [asc: d.name], preload: [:group])
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
