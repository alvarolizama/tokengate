defmodule Mix.Tasks.Tokengate.Counters do
  @shortdoc "Backfill and reconcile the durable consumption counters"

  @moduledoc """
  Maintenance for `consumption_counters` / `topup_consumption_counters`, the
  durable per-subject-day and per-top-up totals the `request_logs` trigger keeps
  exact.

      mix tokengate.counters backfill    # (re)build from the retained logs
      mix tokengate.counters reconcile   # counter vs raw query, exact per bucket

  `backfill` re-aggregates every CLOSED day from `request_logs` and raises each
  bucket with `GREATEST` — it can never lower one, so a late-arriving log cannot
  be erased by a stale snapshot and re-running is always safe. Today's bucket is
  left alone: the trigger is adding to it right now. Run it once right after
  deploying a migration that introduces the counters (the trigger only counts
  logs committed after the migration's COMMIT).

  `reconcile` prints, in integer micro-USD, every subject-day whose counter
  differs from the same aggregate computed with a query, plus the two top-up
  checks (`topup_mismatches` for top-ups fully inside the retention window, and
  `topup_underreported` for any top-up whose money counter is below its surviving
  logs). Under normal operation it prints none.

  Both run through `Ecto.Migrator.with_repo/2` (the same pattern as the rollup
  backfill): the repo is started WITHOUT the application tree, so no
  `CatalogSync`, partition workers or Oban jobs run against the data being
  measured.
  """

  use Mix.Task

  alias Tokengate.Metrics.ConsumptionCounters
  alias Tokengate.Repo

  @impl true
  def run(["backfill"]) do
    with_repo(fn ->
      {:ok, counts} = ConsumptionCounters.backfill()

      Mix.shell().info(
        "counters backfilled: #{counts.user_rows} user-day bucket(s), " <>
          "#{counts.service_rows} service-day bucket(s), #{counts.topup_rows} top-up(s)"
      )
    end)
  end

  def run(["reconcile"]) do
    with_repo(fn ->
      {:ok, report} = ConsumptionCounters.reconcile()

      subjects = report.user ++ report.service
      topups = report.topups ++ report.topups_underreported

      if subjects == [] and topups == [] do
        Mix.shell().info("counters in parity: no bucket differs from the raw aggregate")
      else
        Mix.shell().info(
          "#{length(report.user)} user-day, #{length(report.service)} service-day and " <>
            "#{length(topups)} top-up counter(s) drifted:"
        )

        for row <- subjects do
          Mix.shell().info(
            "  #{row.day} #{row.kind}=#{row.subject_id} " <>
              "counter=#{inspect(row.counter_micro)} raw=#{inspect(row.raw_micro)} micro-USD " <>
              "(requests #{inspect(row.counter_requests)}/#{inspect(row.raw_requests)}, " <>
              "errors #{inspect(row.counter_errors)}/#{inspect(row.raw_errors)})"
          )
        end

        for row <- topups do
          Mix.shell().info(
            "  topup=#{row.topup_id} " <>
              "counter=#{inspect(row.counter_micro)} raw=#{inspect(row.raw_micro)} micro-USD " <>
              "(requests #{inspect(row.counter_requests)}/#{inspect(row.raw_requests)})"
          )
        end

        if report.topups_underreported != [] do
          Mix.shell().error(
            "a top-up counter is BELOW its surviving logs — that direction must never " <>
              "happen; run `mix tokengate.counters backfill`"
          )
        end

        Mix.shell().error(
          "run `mix tokengate.counters backfill` to repair the closed days " <>
            "(it only raises buckets; a counter that is too HIGH needs a manual UPDATE)"
        )
      end
    end)
  end

  def run(_) do
    Mix.shell().error("usage: mix tokengate.counters [backfill|reconcile]")
  end

  defp with_repo(fun) do
    {:ok, result, _apps} = Ecto.Migrator.with_repo(Repo, fn _repo -> fun.() end)
    result
  end
end
