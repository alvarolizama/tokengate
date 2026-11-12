defmodule Tokengate.Repo.Migrations.AddHourUtcIndexToRequestMetricsHourly do
  @moduledoc """
  Adds an `hour_utc`-leading covering index to `request_metrics_hourly`.

  `StatsQueries` slices the rollup by a bare time range — `WHERE hour_utc >=
  from AND hour_utc < tail_floor()` — with no `day` predicate (see the
  timeline/usage queries in `stats_queries.ex`), and `RollupWorker` prunes
  with `DELETE WHERE hour_utc < cutoff`. Every existing index leads with
  `day` (`request_metrics_hourly_hour_idx` is `(day, hour_utc)`), so none of
  them can serve those predicates as a range scan; the planner falls back to
  a sequential scan of the whole rollup.

  `INCLUDE (request_count)` turns the per-hour count query into an index-only
  scan and costs nothing at lookup time (INCLUDE columns are not part of the
  key). The table is small (a few hundred buckets per day), so a plain
  `CREATE INDEX` is enough — no `CONCURRENTLY` needed.
  """

  use Ecto.Migration

  @index :request_metrics_hourly_hour_utc_idx

  def up do
    execute """
    CREATE INDEX IF NOT EXISTS #{@index}
      ON request_metrics_hourly (hour_utc)
      INCLUDE (request_count)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS #{@index}"
  end
end
