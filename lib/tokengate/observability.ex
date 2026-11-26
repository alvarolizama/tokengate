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
  alias Tokengate.Observability.WebhookWorker

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

  @doc """
  Returns only active (`enabled == true`) destinations, derived from the cached
  `list_all_destinations/0` list so paused webhooks receive no new jobs without
  adding a second cache key.
  """
  def list_enabled_destinations do
    Enum.filter(list_all_destinations(), & &1.enabled)
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

  @doc "Toggles a destination's enabled state."
  def toggle_destination(%Destination{} = destination) do
    update_destination(destination, %{enabled: not destination.enabled})
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

  @doc "Sends a synchronous test OTLP payload to a destination."
  def test_destination(%Destination{} = destination) do
    WebhookWorker.send_test(destination)
  end

  @doc """
  Recent Oban delivery stats (last 24h) grouped by `destination_id`.

  Returns `%{destination_id => %{completed: int, pending: int, failed: int, last_error: String.t() | nil}}`
  in a single query over `oban_jobs`.
  """
  def destination_delivery_stats(hours \\ 24) do
    cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
    worker = inspect(WebhookWorker)

    rows =
      from(j in Oban.Job,
        where: j.worker == ^worker and j.inserted_at >= ^cutoff,
        select: %{
          destination_id: fragment("?->>'destination_id'", j.args),
          state: j.state,
          errors: j.errors,
          inserted_at: j.inserted_at
        },
        order_by: [desc: j.inserted_at]
      )
      |> Repo.all()

    Enum.reduce(rows, %{}, fn row, acc ->
      dest_id = row.destination_id

      if is_binary(dest_id) and dest_id != "" do
        entry =
          Map.get(acc, dest_id, %{completed: 0, pending: 0, failed: 0, last_error: nil})

        entry =
          case row.state do
            "completed" ->
              %{entry | completed: entry.completed + 1}

            s when s in ["available", "executing", "scheduled", "retryable"] ->
              %{entry | pending: entry.pending + 1}

            s when s in ["discarded", "cancelled"] ->
              %{entry | failed: entry.failed + 1}

            _ ->
              entry
          end

        entry =
          if is_nil(entry.last_error) and row.state in ["discarded", "retryable"] do
            %{entry | last_error: extract_last_error(row.errors)}
          else
            entry
          end

        Map.put(acc, dest_id, entry)
      else
        acc
      end
    end)
  end

  defp extract_last_error(errors) when is_list(errors) and errors != [] do
    errors
    |> List.last()
    |> case do
      %{"error" => err} when is_binary(err) -> err
      %{error: err} when is_binary(err) -> err
      other -> inspect(other)
    end
  end

  defp extract_last_error(_), do: nil
end
