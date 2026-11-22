defmodule Tokengate.Logs.Retention do
  @moduledoc """
  Retention of historical data: the nightly worker's policy, plus the manual
  purge the Maintenance page offers.

  Two definitions and one operation:

    * the **cutoff** is `today - retention_days`, and it lives in
      `Tokengate.Logs.PartitionWorker.cutoff_day/1` (runtime-configurable through
      `config :tokengate, :logs_retention_days`, default 90). The nightly cron and
      this module share it, so "purge now" and "what the cron does at 00:05" can
      never disagree about the boundary.
    * `preview/1` is READ-ONLY: it reports what a purge would delete (partitions
      with a row estimate, expired rows stranded in the default partition, rollup
      rows) so the operator confirms with numbers on screen instead of a promise.
    * `purge/1` does the deletion by REUSING the worker's own functions (DROP of
      expired partitions, bounded DELETE of the default partition) plus the rollup
      prune with the SAME cutoff.

  ## Why raw and rollup are purged together

  The hybrid reader reconciles `COUNT(request_logs)` against
  `SUM(request_metrics_hourly.request_count)` for each closed span and falls back
  to the whole window raw when they disagree. Deleting raw while keeping the
  rollup would make every window that crosses the cutoff disagree — and the
  fallback would then answer ZERO for days the rollup still had. Symmetry is not
  a nicety here: it is what keeps the numbers correct.

  ## What this does NOT touch

  Budget enforcement (the UTC month is ≤31 days, far inside the window), the
  durable consumption counters (`consumption_counters`,
  `topup_consumption_counters` — they are the record that SURVIVES the raw
  partitions, which is why a two-year-old top-up keeps its real consumption),
  the catalog, users, keys and audit logs (own worker, own monthly partitions).

  Idempotent and resumable: every DROP is `IF EXISTS`, the default-partition
  prune is batched, and re-running finishes whatever a crash interrupted.
  """

  require Logger

  alias Tokengate.Logs.PartitionWorker
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Metrics.Rollup.HourlyAggregate
  alias Tokengate.Repo

  @doc """
  What `purge/1` would delete, without deleting anything.

  Returns:

      %{
        retention_days: 90,
        cutoff_day: ~D[...],
        partitions: [%{name: String.t(), day: Date.t(), rows_estimate: integer}],
        partition_count: integer,
        rows_estimate: integer,
        default_expired_rows: integer,
        rollup_rows: integer,
        oldest_visible_day: Date.t() | nil
      }

  Row counts per partition come from `pg_class.reltuples` (an estimate the
  planner maintains), not from a `COUNT(*)` over millions of rows: the modal needs
  magnitude, not the last digit. `default_expired_rows` is an exact count of the
  rows stranded in the default partition below the cutoff, bounded by definition
  to the expired range.
  """
  def preview(opts \\ []) do
    days = retention_days(opts)
    cutoff = PartitionWorker.cutoff_day(days)

    partitions =
      PartitionWorker.expired_partitions(days)
      |> Enum.map(fn %{name: name, day: day} ->
        %{name: name, day: day, rows_estimate: estimate_rows(name)}
      end)

    %{
      retention_days: days,
      cutoff_day: cutoff,
      partitions: partitions,
      partition_count: length(partitions),
      rows_estimate: Enum.reduce(partitions, 0, &(&1.rows_estimate + &2)),
      default_expired_rows: default_expired_rows(cutoff),
      rollup_rows: rollup_rows(cutoff),
      oldest_visible_day: oldest_partition_day()
    }
  end

  @doc """
  Purges everything past the cutoff: expired daily partitions, the expired rows
  stranded in the default partition, and the rollup rows of those same days.

  Each step is independent and idempotent, so a partial failure leaves the
  database consistent and a re-run finishes the job. Not one big transaction on
  purpose: a global transaction would hold catalog locks on every partition at
  once, and there is nothing to roll back — the purge is monotone.
  """
  def purge(opts \\ []) do
    days = retention_days(opts)
    cutoff = PartitionWorker.cutoff_day(days)

    # Cada paso recalcula el corte con `Date.utc_today()`, así que una purga que
    # cruza la medianoche UTC purgaría el raw con un corte y el rollup con otro
    # (asimetría de un día → el guard de paridad cae a raw). Derivar los días
    # restantes del corte CONGELADO mantiene el mismo corte sin cambiar firmas.
    days_left = fn -> Date.diff(Date.utc_today(), cutoff) end

    {:ok, dropped} = PartitionWorker.cleanup_old_partitions(days_left.())
    {:ok, default} = PartitionWorker.prune_default_partition(retention_days: days_left.())
    {:ok, rollup} = HourlyAggregate.prune(retention_days: days_left.())

    # The guard verdicts and the spend maps live 5-60s in the cache: without this
    # the pages would keep serving pre-purge numbers (and a stale "rollup
    # trusted" verdict) until the TTL expires.
    DashboardCache.invalidate_all()

    Logger.info(
      "retention purge: cutoff #{Date.to_iso8601(cutoff)}, " <>
        "#{length(dropped)} partition(s) dropped, default #{inspect(default)}, rollup #{inspect(rollup)}"
    )

    {:ok,
     %{
       cutoff_day: cutoff,
       retention_days: days,
       partitions_dropped: dropped,
       default: default,
       rollup: rollup
     }}
  end

  defp retention_days(opts) do
    case Keyword.fetch(opts, :retention_days) do
      {:ok, days} when is_integer(days) and days >= 0 -> days
      _ -> PartitionWorker.retention_days()
    end
  end

  defp estimate_rows(partition_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT GREATEST(c.reltuples, 0)::bigint AS rows
        FROM pg_class c
        WHERE c.relname = $1
        """,
        [partition_name]
      )

    case rows do
      [[value]] -> to_int(value)
      _ -> 0
    end
  end

  defp default_expired_rows(cutoff) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*)::bigint FROM request_logs_default WHERE inserted_at < $1",
        [NaiveDateTime.new!(cutoff, ~T[00:00:00])]
      )

    to_int(count)
  end

  defp rollup_rows(cutoff) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*)::bigint FROM request_metrics_hourly WHERE day < $1", [cutoff])

    to_int(count)
  end

  defp oldest_partition_day do
    PartitionWorker.expired_partitions(0)
    |> Enum.map(& &1.day)
    |> Enum.min(Date, fn -> nil end)
  end

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_binary(value), do: String.to_integer(value)
  defp to_int(_value), do: 0
end
