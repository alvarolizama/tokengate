defmodule Tokengate.Metrics.RollupWorker do
  @moduledoc """
  Keeps `request_metrics_hourly` fresh.

  Every `@interval_ms` (default 60s), re-aggregates the last
  `@refresh_hours` hours (default 3) from `request_logs` via
  `Metrics.Rollup.HourlyAggregate.aggregate_hours/2`. Because each hour is
  fully re-aggregated (upsert), late-arriving logs and retried runs simply
  converge — no offset bookkeeping.

  The 3-hour window comfortably covers: logs written seconds ago, the
  WriteWorker's flush lag, clock skew between nodes, and a missed tick or
  two. Older hours are immutable in practice (`request_logs` is
  append-only; the only rewrites are the manual-pricing backfill and
  truncate, both followed by a manual `backfill/2`).

  Also prunes rollup rows older than `@retention_days` (90, same policy as
  the `request_logs` partition cleanup) once a day.

  Disabled in the test environment via the `:rollup_worker` app env
  (`config :tokengate, RollupWorker, enabled: false`) — tests populate the
  rollup explicitly through `HourlyAggregate`.
  """

  use GenServer

  require Logger
  import Ecto.Query

  alias Tokengate.Metrics.Rollup.HourlyAggregate
  alias Tokengate.Metrics.RequestMetricsHourly
  alias Tokengate.Repo

  @interval_ms 60_000
  @refresh_hours 3
  @retention_days 90
  # Prune at most once per day (checked against the last prune time).
  @prune_interval_ms 24 * 60 * 60 * 1000

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if Application.get_env(:tokengate, __MODULE__, [])[:enabled] != false do
      send(self(), :tick)
    end

    {:ok, %{last_prune_at: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    refresh()

    state = maybe_prune(state)
    schedule_tick()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Re-aggregates the last @refresh_hours of request_logs into the rollup.
  # aggregate_hours/2 raises on DB errors (caught by the rescue below) —
  # the next tick retries; a broken rollup degrades dashboards to their
  # request_logs fallback, it never takes the VM down.
  defp refresh do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    from = DateTime.add(now, -@refresh_hours * 3600, :second)

    case HourlyAggregate.aggregate_hours(from, now) do
      {:ok, 0} ->
        :ok

      {:ok, rows} ->
        Logger.info("RollupWorker: refreshed #{@refresh_hours}h of rollup (#{rows} buckets)")
        :ok
    end
  rescue
    e -> Logger.error("RollupWorker: refresh crashed: #{inspect(e)}")
  end

  # Daily prune of rollup rows past the request_logs retention window.
  defp maybe_prune(%{last_prune_at: nil} = state) do
    prune()
    %{state | last_prune_at: System.monotonic_time(:millisecond)}
  end

  defp maybe_prune(state) do
    if System.monotonic_time(:millisecond) - state.last_prune_at >= @prune_interval_ms do
      prune()
      %{state | last_prune_at: System.monotonic_time(:millisecond)}
    else
      state
    end
  end

  defp prune do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days * 86_400, :second)

    Repo.delete_all(from(m in RequestMetricsHourly, where: m.hour_utc < ^cutoff))

    :ok
  rescue
    e -> Logger.error("RollupWorker: prune crashed: #{inspect(e)}")
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @interval_ms)
end
