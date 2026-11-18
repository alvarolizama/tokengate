defmodule Tokengate.Metrics.RollupWorker do
  @moduledoc """
  Keeps `request_metrics_hourly` fresh AND self-healing.

  ## What changed and why (F29 / F53 / F54)

  The previous version re-aggregated the last 3 hours on every tick (60s) and
  had no backfill at boot, so:

    * a deploy / OOM that left a hole bigger than 3h made
      `StatsQueries.rollup_trusted?/4` fail on EVERY hybrid read — permanently
      and silently, because nothing ever re-aggregated the hole (the manual
      `rollup-backfill` was the only fix);
    * rewriting 3-4h of buckets every minute was pure write amplification: the
      readers only serve the rollup for hours that closed at least
      `HourlyAggregate`'s raw tail (3h) ago, so the buckets in between are
      written and never read;
    * the next tick was scheduled AFTER the work (`work + 60s`), so the period
      drifted by the duration of each refresh, and a slow refresh pushed the
      whole schedule;
    * a failure only produced a log line and retried at the same cadence.

  ## Behaviour now

    * **Tail refresh** — rewrites only the buckets the readers do not serve
      raw: the last closed hour plus the open one (≤ 2 buckets per tick).
    * **Gap instrumentation + self-heal** — every tick compares the newest
      rollup bucket against the newest raw log hour
      (`HourlyAggregate.gap_hours/0`). A lag above `:heal_after_hours`
      (default 3, the readers' raw tail) triggers a day-chunked backfill of
      exactly the missing range, so a hole heals itself instead of degrading
      every read forever.
    * **Boot backfill** — the same gap check runs once at boot
      (`handle_continue/2`, so the supervision tree is not blocked). A rollup
      with no data at all is backfilled from the retention window, one day per
      transaction, logging the day counter (progress signal + resume point).
    * **Fixed-period tick** — the next deadline is derived from the previous
      DEADLINE, not from "now + interval", so the work duration does not
      accumulate drift. A tick that arrives late still lands on the grid and a
      suspended one catches up with a single tick.
    * **Failures with metric and backoff** — every cycle emits
      `[:tokengate, :rollup, :refresh]` with `%{duration_ms, rows}` and
      `%{result: :ok | :error, gap_hours, healed_days}`; consecutive failures
      back the next tick off exponentially (60s → 15min cap) and recover on
      the first success.

  Also prunes rollup rows past the retention window once a day, aligned with
  the `request_logs` partition DROP by CALENDAR DAY (see
  `HourlyAggregate.prune/1`).

  Disabled in the test environment via the `:rollup_worker` app env
  (`config :tokengate, RollupWorker, enabled: false`); tests that exercise the
  worker start it explicitly with `start_supervised!/1` and a unique `:name`
  (the app tree already owns the default name).
  """

  use GenServer

  require Logger
  alias Tokengate.Metrics.Rollup.HourlyAggregate

  @interval_ms 60_000
  # The readers serve the rollup only for hours that closed at least 3h ago
  # (`StatsQueries` raw tail); a bigger lag is a real gap.
  @heal_after_hours 3
  @max_backoff_ms 15 * 60 * 1000
  @telemetry_event [:tokengate, :rollup, :refresh]

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Current worker state: `enabled?`, scheduling and last-cycle bookkeeping.

  The `gap_hours` / `consecutive_failures` / `last_backfill` fields are what
  the self-healing test asserts on — no sleeping and no clock games.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  Runs one refresh cycle synchronously and returns its outcome. Used by
  operators (`iex`) and by tests; the periodic tick runs the same cycle.
  """
  @spec refresh_now(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def refresh_now(server \\ __MODULE__), do: GenServer.call(server, :refresh_now, 120_000)

  # ---------------------------------------------------------------------------
  # Fixed-period scheduling (pure, so the mechanic is testable)
  # ---------------------------------------------------------------------------

  @doc """
  Next tick deadline for a FIXED period.

  `deadline` is the instant the previous tick was due, `now` the monotonic
  clock when the work finished. While the work fits inside the period this
  returns `deadline + interval` — the period never absorbs the work duration
  (`now + interval` would drift by exactly that). A late tick skips to the
  next slot ON THE ORIGINAL GRID instead of shifting the whole schedule.
  """
  @spec next_deadline(integer(), integer(), pos_integer()) :: integer()
  def next_deadline(deadline, now, interval) when is_integer(interval) and interval > 0 do
    if deadline > now do
      deadline
    else
      deadline + (div(now - deadline, interval) + 1) * interval
    end
  end

  @doc """
  Delay before the next tick after `failures` consecutive failures:
  exponential from one period, capped at 15 minutes.
  """
  @spec backoff_ms(pos_integer(), pos_integer()) :: pos_integer()
  def backoff_ms(failures, interval \\ @interval_ms) when failures > 0 do
    min(interval * Integer.pow(2, min(failures - 1, 10)), @max_backoff_ms)
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Application.get_env(:tokengate, __MODULE__, []) |> Keyword.merge(opts)

    state = %{
      enabled?: Keyword.get(config, :enabled, true) != false,
      interval_ms: Keyword.get(config, :interval_ms, @interval_ms),
      heal_after_hours: Keyword.get(config, :heal_after_hours, @heal_after_hours),
      retention_days: Keyword.get(config, :retention_days),
      # Injectable for the failure-path test; defaults to the real aggregation.
      refresh_fun: Keyword.get(config, :refresh_fun, &HourlyAggregate.aggregate_hours/2),
      boot_backfill?: Keyword.get(config, :boot_backfill, true),
      next_tick_at: nil,
      last_tick_at: nil,
      last_success_at: nil,
      last_error: nil,
      last_rows: nil,
      last_backfill: nil,
      gap_hours: nil,
      consecutive_failures: 0,
      last_prune_day: nil
    }

    if state.enabled? do
      {:ok, state, {:continue, :boot}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:boot, state) do
    # Backfill the gap BEFORE the first tick: a deploy that left a hole heals
    # as soon as the node is up, without waiting for the next minute.
    state =
      if state.boot_backfill? do
        case safe_backfill(state, boot: true) do
          {:ok, state} -> state
          {:error, _reason, state} -> state
        end
      else
        state
      end

    {:noreply, schedule_tick(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    state = %{state | last_tick_at: DateTime.utc_now() |> DateTime.truncate(:second)}

    {result, state} = run_cycle(state)
    state = maybe_prune(state)

    state =
      case result do
        :ok -> schedule_tick(state)
        :error -> schedule_after_failure(state)
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state) do
    now = System.monotonic_time(:millisecond)

    {:reply,
     %{
       enabled?: state.enabled?,
       interval_ms: state.interval_ms,
       heal_after_hours: state.heal_after_hours,
       consecutive_failures: state.consecutive_failures,
       last_tick_at: state.last_tick_at,
       last_success_at: state.last_success_at,
       last_error: state.last_error,
       last_rows: state.last_rows,
       last_backfill: state.last_backfill,
       gap_hours: state.gap_hours,
       next_tick_in_ms: state.next_tick_at && max(state.next_tick_at - now, 0)
     }, state}
  end

  def handle_call(:refresh_now, _from, state) do
    {result, state} = run_cycle(state)

    reply =
      case result do
        :ok -> {:ok, %{rows: state.last_rows, gap_hours: state.gap_hours}}
        :error -> {:error, state.last_error}
      end

    {:reply, reply, state}
  end

  # ---------------------------------------------------------------------------
  # One cycle: heal the gap, rewrite the unserved tail, emit the metric
  # ---------------------------------------------------------------------------

  defp run_cycle(state) do
    started = System.monotonic_time(:millisecond)

    result =
      case safe_backfill(state, []) do
        {:ok, state} ->
          case safe_refresh_tail(state) do
            {:ok, rows} -> {:ok, %{state | last_rows: rows}}
            {:error, reason} -> {:error, reason, state}
          end

        {:error, reason, state} ->
          {:error, reason, state}
      end

    duration_ms = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, state} ->
        state = %{
          state
          | last_success_at: DateTime.utc_now() |> DateTime.truncate(:second),
            last_error: nil,
            consecutive_failures: 0
        }

        :telemetry.execute(
          @telemetry_event,
          %{duration_ms: duration_ms, rows: state.last_rows},
          %{
            result: :ok,
            gap_hours: state.gap_hours,
            healed_days: healed_days(state.last_backfill)
          }
        )

        {:ok, state}

      {:error, reason, state} ->
        failures = state.consecutive_failures + 1

        state = %{
          state
          | consecutive_failures: failures,
            last_error: inspect(reason)
        }

        :telemetry.execute(
          @telemetry_event,
          %{duration_ms: duration_ms, rows: 0},
          %{result: :error, gap_hours: state.gap_hours, failures: failures, reason: reason}
        )

        Logger.error(
          "RollupWorker: cycle failed (#{failures} in a row, backing off " <>
            "#{div(backoff_ms(failures, state.interval_ms), 1000)}s): #{inspect(reason)}"
        )

        {:error, state}
    end
  end

  # The readers ignore the rollup for anything newer than 3h, so the tail the
  # worker must keep TRUE for them is the last closed hour (plus the open one,
  # whose partial bucket makes the hour flip instantaneous). 3-4h every 60s
  # was write amplification nobody read.
  defp safe_refresh_tail(state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    from = now |> floor_hour() |> DateTime.add(-3600, :second)

    case state.refresh_fun.(from, now) do
      {:ok, rows} when is_integer(rows) -> {:ok, rows}
      other -> {:error, {:unexpected_refresh_result, other}}
    end
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_backfill(state, opts) do
    backfill_opts =
      [
        threshold_hours: state.heal_after_hours,
        on_progress: &log_progress/1
      ] ++
        if state.retention_days, do: [retention_days: state.retention_days], else: []

    case HourlyAggregate.backfill_gap(backfill_opts) do
      {:ok, %{status: :covered, gap_hours: gap}} ->
        {:ok, %{state | gap_hours: gap, last_backfill: nil}}

      {:ok, %{status: :backfilled} = result} ->
        # The gap instrumentation: say how big the hole was and what it took.
        Logger.warning(
          "RollupWorker: healed rollup gap (#{format_gap(result.gap_hours)}) " <>
            "across #{result.days} day(s) (#{result.rows} buckets)#{boot_tag(opts)}"
        )

        {:ok, %{state | gap_hours: result.gap_hours, last_backfill: result}}

      {:ok, %{status: :no_data, gap_hours: gap}} ->
        {:ok, %{state | gap_hours: gap, last_backfill: nil}}
    end
  rescue
    e -> {:error, e, %{state | last_error: inspect(e)}}
  catch
    kind, reason -> {:error, {kind, reason}, %{state | last_error: inspect({kind, reason})}}
  end

  defp boot_tag(opts), do: if(opts[:boot], do: " at boot", else: "")
  defp healed_days(nil), do: 0
  defp healed_days(%{days: days}), do: days
  defp format_gap(:empty), do: "rollup empty"
  defp format_gap(gap) when is_float(gap), do: "#{:erlang.float_to_binary(gap, decimals: 1)}h"

  defp log_progress(%{day: day, rows: rows, done: done, total: total}) do
    Logger.info("[rollup backfill] #{day} → #{rows} buckets (#{done}/#{total})")
  end

  # ---------------------------------------------------------------------------
  # Scheduling
  # ---------------------------------------------------------------------------

  defp schedule_tick(state) do
    now = System.monotonic_time(:millisecond)

    deadline =
      next_deadline(state.next_tick_at || now + state.interval_ms, now, state.interval_ms)

    Process.send_after(self(), :tick, max(deadline - now, 0))
    %{state | next_tick_at: deadline}
  end

  # After a failure the grid is broken on purpose: the next attempt waits the
  # backoff delay, and a success re-anchors the fixed period from that instant.
  defp schedule_after_failure(state) do
    now = System.monotonic_time(:millisecond)
    delay = backoff_ms(state.consecutive_failures, state.interval_ms)
    Process.send_after(self(), :tick, delay)
    %{state | next_tick_at: now + delay}
  end

  # ---------------------------------------------------------------------------
  # Prune
  # ---------------------------------------------------------------------------

  # Once per CALENDAR DAY, on the same boundary the partition DROP uses: the
  # rollup prune deletes `day < today - retention`, exactly the days whose
  # `request_logs` partition is being dropped. A monotonic interval would drift
  # across the boundary and could leave a day's rollup rows the raw side no
  # longer has (or vice versa).
  defp maybe_prune(state) do
    today = Date.utc_today()

    case state.last_prune_day do
      ^today ->
        state

      _ ->
        prune(state)
        %{state | last_prune_day: today}
    end
  end

  defp prune(state) do
    opts = if state.retention_days, do: [retention_days: state.retention_days], else: []

    case HourlyAggregate.prune(opts) do
      {:ok, %{deleted: 0}} ->
        :ok

      {:ok, %{deleted: deleted, cutoff_day: cutoff}} ->
        Logger.info("RollupWorker: pruned #{deleted} rollup rows before #{cutoff}")
    end
  rescue
    e -> Logger.error("RollupWorker: prune crashed: #{inspect(e)}")
  end

  defp floor_hour(%DateTime{} = dt), do: %{dt | minute: 0, second: 0, microsecond: {0, 0}}
end
