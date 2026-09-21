defmodule Mix.Tasks.Tokengate.Rollup.Backfill do
  @shortdoc "Rebuilds request_metrics_hourly (the hourly rollup) from request_logs"

  @moduledoc """
  Rebuilds the hourly metrics rollup over a window, from `request_logs` (the
  source of truth). The period KPIs of Resumen (`/stats/overview`) and the
  dashboard read it through `Tokengate.Metrics.StatsQueries`, so a rollup that
  disagrees with the raw numbers makes those two pages disagree with `/stats`
  (En vivo) and `/budget/global` — both of which read `request_logs` crudo.

      mix tokengate.rollup.backfill                              # últimos 90 días
      mix tokengate.rollup.backfill --days 7
      mix tokengate.rollup.backfill --from 2026-09-01 --to 2026-09-15

  The `RollupWorker` only re-aggregates the last 3 hours, so anything older
  that was written by a buggy version stays wrong until a backfill repairs it
  — this task (and `bin/rollup-backfill` in a release, which calls
  `Tokengate.Release.rollup_backfill/1`) is that repair path.

  Options:

    * `--days N`  — window start = 00:00 UTC of `hoy - N` (default: 90, the
      rollup retention, same as `ROLLUP_BACKFILL_DAYS`).
    * `--from ISO8601|YYYY-MM-DD` — explicit start (wins over `--days`).
    * `--to ISO8601|YYYY-MM-DD`   — explicit end (default: ahora).

  Idempotent and resumable: every UTC day is deleted and re-aggregated in its
  own transaction.
  """

  use Mix.Task

  alias Tokengate.Release

  @switches [days: :integer, from: :string, to: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, argv_rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise(
        "opciones inválidas: #{inspect(invalid)} (ver `mix help tokengate.rollup.backfill`)"
      )
    end

    if argv_rest != [] do
      Mix.raise("argumentos inesperados: #{inspect(argv_rest)}")
    end

    opts =
      opts
      |> maybe_put(:from, opts[:from])
      |> maybe_put(:to, opts[:to])

    %{days: days, rows: rows} = Release.rollup_backfill(opts)

    Mix.shell().info("rollup backfill: #{days} días re-agregados, #{rows} buckets escritos")
  end

  # `--from`/`--to` llegan como string y `Tokengate.Release` los parsea por el
  # mismo camino que las env vars (`ROLLUP_BACKFILL_FROM`/`_TO`), así que la
  # tarea y el `bin/rollup-backfill` no pueden divergir en formato aceptado.
  defp maybe_put(opts, _key, nil), do: opts

  defp maybe_put(opts, key, value) do
    Keyword.put(opts, key, Release.parse_datetime!(to_env_name(key), value))
  end

  defp to_env_name(:from), do: "--from"
  defp to_env_name(:to), do: "--to"
end
