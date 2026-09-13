defmodule Tokengate.Budgets.SyncWorker do
  @moduledoc """
  Oban worker that drift-corrects a spending subject's monthly ETS budget
  counter against the durable truth in `request_logs`.

  On each run it recomputes the subject's monthly spend from
  `Tokengate.Logs.cost_summary/1` and resets the ETS counter via
  `Tokengate.Budgets.Manager.set_from_db/2`. This corrects drift caused by
  lost updates, process crashes, or manual ETS evictions.

  ## Scheduling

  Enqueued by `Budgets.Manager.settle/3` after each spend recording, debounced
  to at most one pending job per subject (see the manager's
  `maybe_enqueue_sync/1`). No cron schedule is wired for it.

  ## Dedup

  `unique: [period: 60, keys: [:subject_id]]` prevents rapid-fire duplicate
  jobs for the same subject within a 60-second window.
  """

  use Oban.Worker,
    queue: :budgets,
    max_attempts: 3,
    unique: [period: 60, keys: [:subject_id]]

  @impl true
  def perform(%Oban.Job{args: %{"subject_id" => subject_id}}) do
    # Clear the debounce mark BEFORE recomputing: any spend recorded after this
    # point will re-enqueue a fresh job. If we cleared it after set_from_db, a
    # concurrent settle could set the mark between our clear and our write, then
    # never fire a new job.
    Tokengate.Budgets.Manager.clear_sync_pending(subject_id)

    monthly_micro = compute_monthly_spend(subject_id)

    Tokengate.Budgets.Manager.set_from_db(subject_id, monthly_micro)

    :ok
  end

  # Helper to allow direct invocation in tests with atom-keyed args.
  def perform(%{subject_id: subject_id}) do
    perform(%Oban.Job{args: %{"subject_id" => subject_id}})
  end

  defp compute_monthly_spend(subject_id) do
    Tokengate.Budgets.Manager.load_from_db(subject_id, period_start(:monthly))
  end

  defp period_start(:monthly) do
    today = Date.utc_today()
    first = Date.new!(today.year, today.month, 1)
    DateTime.new!(first, ~T[00:00:00], "Etc/UTC")
  end
end
