defmodule Tokengate.Observability do
  @moduledoc """
  The Observability context: manages telemetry export destinations.

  Los destinos son globales: la observabilidad es de toda la instalación, no
  de un perfil de límites. Cada webhook recibe la telemetría de todos los sujetos.
  """

  import Ecto.Query, warn: false
  alias Tokengate.Cache
  alias Tokengate.Repo
  alias Tokengate.Observability.Destination

  # Safety net only — every destination mutation invalidates the key.
  @destinations_ttl_ms :timer.seconds(20)
  @destinations_key {:observability_destinations, :all}

  # ---------------------------------------------------------------------------
  # Destinations
  # ---------------------------------------------------------------------------

  @doc """
  Returns all destinations, ordered by name. Every destination receives the
  telemetry of the whole installation — there is no per-group scoping.

  Read once per request log by `WebhookWorker.dispatch/1`, so the list is
  served from `Tokengate.Cache` (`{:observability_destinations, :all}`) with a
  short TTL; every mutation below invalidates it, making a new/edited/deleted
  destination visible immediately. With zero destinations the cached hit is an
  empty list — same cost as a hit with rows.
  """
  def list_all_destinations do
    Cache.fetch(@destinations_key, @destinations_ttl_ms, fn ->
      Repo.all(from d in Destination, order_by: [asc: d.name])
    end)
  end

  @doc "Gets a single destination. Raises if not found."
  def get_destination!(id), do: Repo.get!(Destination, id)

  @doc "Gets a single destination. Returns nil if not found."
  def get_destination(id), do: Repo.get(Destination, id)

  @doc "Creates a destination."
  def create_destination(attrs) do
    result =
      %Destination{}
      |> Destination.changeset(attrs)
      |> Repo.insert()

    if match?({:ok, _}, result), do: Cache.invalidate(@destinations_key)

    result
  end

  @doc "Updates a destination."
  def update_destination(%Destination{} = destination, attrs) do
    result =
      destination
      |> Destination.changeset(attrs)
      |> Repo.update()

    if match?({:ok, _}, result), do: Cache.invalidate(@destinations_key)

    result
  end

  @doc "Deletes a destination."
  def delete_destination(%Destination{} = destination) do
    result = Repo.delete(destination)

    if match?({:ok, _}, result), do: Cache.invalidate(@destinations_key)

    result
  end

  @doc "Returns a changeset for tracking destination changes."
  def change_destination(%Destination{} = destination, attrs \\ %{}) do
    Destination.changeset(destination, attrs)
  end
end
