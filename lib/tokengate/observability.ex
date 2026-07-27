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

  @doc "Returns all observability destinations for the given team."
  def list_destinations(team_id) do
    Repo.all(from d in Destination, where: d.team_id == ^team_id)
  end

  @doc """
  Returns all observability destinations for the given teams in a single
  query, grouped by team_id (`%{team_id => [Destination]}`). Teams without
  destinations are absent from the map — callers should default to `[]`.
  """
  def list_destinations_for_teams(team_ids) when is_list(team_ids) do
    Repo.all(from d in Destination, where: d.team_id in ^team_ids)
    |> Enum.group_by(& &1.team_id)
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
