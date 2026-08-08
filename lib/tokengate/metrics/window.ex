defmodule Tokengate.Metrics.Window do
  @moduledoc """
  ETS-backed rolling time-window for per-model request counts.

  Keeps the last 60 one-minute buckets per `model_alias_id` in a public
  named ETS table so the Monitor LiveView can render a 60-minute sparkline
  without hitting Postgres on every refresh.

  ## Concurrency model

  Same pattern as `Tokengate.Metrics.Collector`: the GenServer only owns
  the table and runs the minute-rotation. `record_request/1` and
  `snapshot/0` run in the caller's process — no GenServer bottleneck on
  the hot path.

  ## Keys

  Each bucket key is `{model_alias_id, minute_index}` where
  `minute_index` is the integer minute offset from Unix epoch
  (`System.system_time(:minute)`). Rotation deletes keys whose minute
  index is older than `window_minutes` ago.

  On first `snapshot/0` (or GenServer boot) the window is backfilled
  from `request_logs` so the sparkline doesn't start empty after a
  restart.
  """

  use GenServer

  @table :tokengate_metrics_window
  @window_minutes 60
  @pubsub Tokengate.PubSub
  @topic "metrics:window"
  @sweep_interval_ms 60_000

  ## Public API (caller process) --------------------------------------------

  @doc "The PubSub topic for window rotation events."
  def topic, do: @topic

  @doc "Number of minutes kept in the rolling window."
  def window_minutes, do: @window_minutes

  @doc """
  Records a request into the current minute bucket for the given model.

  Runs in the caller's process via atomic ETS `update_counter`. No
  broadcast — the LiveView polls on its refresh cycle.
  """
  @spec record_request(map()) :: :ok
  def record_request(attrs) do
    model_alias_id = Map.get(attrs, :model_alias_id)

    unless is_nil(model_alias_id) do
      minute = System.system_time(:second) |> div(60)
      :ets.update_counter(@table, {model_alias_id, minute}, {2, 1}, {{model_alias_id, minute}, 0})
    end

    :ok
  end

  @doc """
  Returns the rolling window as a map of `model_alias_id => [counts]`.

  The list has exactly `window_minutes` entries ordered oldest → newest,
  zero-filled for minutes with no activity. The last entry is the
  current (live) minute.

  Example:

      %{\"abc-123\" => [0, 0, 2, 5, 3, 0, ...], \"def-456\" => [...]}
  """
  @spec snapshot() :: %{binary => [non_neg_integer()]}
  def snapshot do
    ensure_table()

    now_minute = System.system_time(:second) |> div(60)
    start_minute = now_minute - @window_minutes + 1

    # ETS keys: {{model_alias_id, minute}, count}
    all =
      @table
      |> :ets.tab2list()
      |> Enum.reject(fn {{_alias_id, minute}, _count} -> minute < start_minute end)

    models =
      all
      |> Enum.map(fn {{alias_id, _minute}, _count} -> alias_id end)
      |> Enum.uniq()

    Map.new(models, fn alias_id ->
      counts =
        for minute <- start_minute..now_minute do
          case :ets.lookup(@table, {alias_id, minute}) do
            [{_key, count}] -> count
            [] -> 0
          end
        end

      {alias_id, counts}
    end)
  end

  @doc """
  Backfills the window from Postgres `request_logs`.

  Fetches the last hour of logs grouped by model_alias_id + minute and
  inserts them into ETS. Called on GenServer boot so the sparkline is
  populated immediately after a restart. Safe to call multiple times —
  later calls for the same minute overwrite earlier ones (which is fine
  since backfill runs before any live `record_request` for that minute).
  """
  @spec backfill() :: :ok
  def backfill do
    ensure_table()

    from =
      DateTime.utc_now()
      |> DateTime.add(-@window_minutes * 60, :second)
      |> DateTime.truncate(:second)

    Tokengate.Metrics.Rollup.minute_series_by_model(from)
    |> Enum.each(fn {alias_id, minute_dt, count} ->
      minute = DateTime.to_unix(minute_dt, :second) |> div(60)
      :ets.insert(@table, {{alias_id, minute}, count})
    end)

    :ok
  end

  @doc """
  Resets the window table. For tests.
  """
  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  ## GenServer (table owner + rotator) -------------------------------------

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ensure_table()

    # Backfill from Postgres so the sparkline is populated on boot.
    # catch (not rescue) to also trap :noproc / EXIT from the sandbox
    # when the Repo isn't available yet (e.g. during test setup).
    try do
      backfill()
    catch
      _, _ -> :ok
    end

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    rotate()
    Phoenix.PubSub.broadcast(@pubsub, @topic, :window_rotated)
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals ---------------------------------------------------------------

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

      _tid ->
        @table
    end
  end

  defp rotate do
    ensure_table()

    cutoff = div(System.system_time(:second), 60) - @window_minutes

    @table
    |> :ets.select([{{{:"$1", :"$2"}, :_}, [{:<, :"$2", cutoff}], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn key -> :ets.delete(@table, key) end)

    :ok
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
