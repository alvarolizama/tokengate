defmodule Tokengate.Budgets.GlobalSyncWorker do
  @moduledoc """
  Oban worker that drift-corrects the **global daily** ETS counter
  (`{:global, :daily}`) against the durable truth in `request_logs`.

  ## Why this exists

  The global counter is the layer-2 daily kill-switch. It moves through the
  reserve → settle cycle: every in-flight request holds a per-request cost
  ceiling (`:proxy, :max_request_cost_usd`) and settles down to the real cost
  afterwards. Three ways the counter drifts above reality:

    * a request dies between hold and settle (deploy, crash, timeout) — its
      ceiling stays counted for the rest of the UTC day;
    * the counter lives in ETS, so it is lost on a node restart while the
      session is behind a load balancer;
    * the settle is corrected by a real cost the upstream never reported.

  `Budgets.SyncWorker` does this for the per-subject monthly counter but the
  global one had no reconciler at all: `Manager.set_global_from_db/1` existed
  with zero callers in `lib/`, so the kill-switch could reject every request
  of the day on phantom spend (`402 Global daily spending cap reached`) while
  the real spend was near zero.

  ## What it does

  Recomputes today's total real spend from `request_logs`
  (`Budgets.Manager.load_from_db/2`-equivalent over the UTC day) and resets
  the ETS counter via `Manager.set_global_from_db/1`.

  ## Scheduling

  Two paths, both wired:

    * **crontab** — every 5 minutes, as a safety net that also fixes drift
      accumulated while the node was down;
    * **on settle** — `Manager.settle_credits/2` / `settle/3` enqueue it
      (debounced to at most one pending job, same pattern as the monthly
      sync) so a burst of traffic converges quickly instead of waiting for
      the next tick.

  ## Dedup

  The job carries no argument, so dedup is on the worker itself via Oban's
  `unique` on a constant key, bounding the enqueue rate.
  """

  use Oban.Worker,
    queue: :budgets,
    max_attempts: 3,
    unique: [period: 30, keys: []]

  @impl true
  def perform(_job) do
    # Clear the debounce mark BEFORE recomputing: any spend settled after this
    # point re-enqueues a fresh job. Clearing after the write could swallow a
    # concurrent settle's mark and leave the counter drifting until the cron.
    Tokengate.Budgets.Manager.clear_global_sync_pending()

    Tokengate.Budgets.Manager.set_global_from_db(compute_today_spend())

    :ok
  end

  @doc """
  Today's real spend (UTC day) in integer micro-USD, straight from
  `request_logs`. Exposed so callers (and the reconciler itself) share one
  definition of the window.
  """
  @spec compute_today_spend() :: non_neg_integer()
  def compute_today_spend do
    Tokengate.Budgets.Manager.load_global_from_db(Tokengate.Budgets.Manager.utc_day_start())
  end
end
