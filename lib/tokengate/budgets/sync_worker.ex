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
  def perform(%Oban.Job{args: %{"subject_id" => subject_id} = args}) do
    # Clear the debounce mark BEFORE recomputing: any spend recorded after this
    # point will re-enqueue a fresh job. If we cleared it after set_from_db, a
    # concurrent settle could set the mark between our clear and our write, then
    # never fire a new job.
    Tokengate.Budgets.Manager.clear_sync_pending(subject_id)

    monthly_micro = compute_monthly_spend(subject_id)

    Tokengate.Budgets.Manager.set_from_db(subject_id, monthly_micro)

    # También reconcilia el contador del LÍMITE (tabla de créditos) cuando el
    # settle vino del plan de créditos (`credit_subject`): `set_from_db` solo
    # corrige la tabla legacy. Sin esto, un contador inflado por drift del
    # hold/settle seguía rechazando con 402 aunque la DB mostrara remanente
    # (la semilla de `ensure_limit_loaded` es una vez por ciclo mensual).
    case Map.fetch(args, "credit_subject") do
      {:ok, [type, id]} when type in ["user", "service"] ->
        Tokengate.Budgets.Manager.reseed_limit_counter({String.to_atom(type), id})

      _ ->
        :ok
    end

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
