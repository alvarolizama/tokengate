defmodule Tokengate.Repo.Migrations.WidenRequestMetricsHourlyHourCovering do
  @moduledoc """
  Widens the rollup's `(day, hour_utc)` index so the overview cards answer
  index-only instead of heap-fetching every bucket row.

  The rollup-backed overview reads all bound the window on `(day, hour_utc)`
  and then read only measures plus one or two dimension columns:

    * `StatsQueries.usage_by_hour_of_day_by_provider/1` — `SUM(request_count)`,
      `SUM(cost_micro)` grouped by local hour + `provider_id`;
    * `StatsQueries.usage_by_model_provider_stacked/1` — the same sums grouped
      by `model_id` + `provider_id`;
    * `StatsQueries.busiest_hours/2` — `SUM(request_count)` per `hour_utc`.

  Without the INCLUDE list each of those turns the index scan into a BITMAP
  HEAP SCAN over the whole 30-day slice of the rollup (measured on a 446k-row
  rollup: 9,959 shared buffers, 78 ms). Carrying the measures and the two
  grouping dimensions in the index makes it an INDEX ONLY SCAN (1,213 buffers,
  54 ms for hour × provider; 15-17 ms for the stacked read, down from
  29-51 ms). The rollup is ~1 row per (hour, member, model, provider) — orders
  of magnitude smaller than `request_logs` — so the extra INCLUDE bytes are
  cheap.

  The index NAME and key columns are kept (no second index on the same keys),
  so no existing plan loses its access path. `down/0` restores the exact
  previous definition.
  """

  use Ecto.Migration

  @index :request_metrics_hourly_hour_idx

  def up do
    execute("DROP INDEX IF EXISTS #{@index}")

    execute("""
    CREATE INDEX #{@index}
    ON request_metrics_hourly (day, hour_utc)
    INCLUDE (request_count, cost_micro, provider_id, model_id)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@index}")

    execute("""
    CREATE INDEX #{@index}
    ON request_metrics_hourly (day, hour_utc)
    """)
  end
end
