defmodule Tokengate.Budgets.SyncWorker do
  @moduledoc """
  Oban worker that drift-corrects a member's ETS budget counters against
  the durable truth in `request_logs`.

  On each run, it recomputes the member's daily and monthly spend from
  `Tokengate.Logs.cost_summary/1` and resets the ETS counters via
  `Tokengate.Budgets.Manager.set_from_db/3`. This corrects drift caused by
  lost increments, process crashes, or manual ETS evictions.

  ## Scheduling

  A cron schedule enqueuing this worker every 5 minutes is intended (to be
  wired into `config/config.exs` Oban `:crontab` by the parent task). The
  worker is also enqueued inline by `Budgets.Manager.record_spend/2` after
  each spend recording.

  ## Dedup

  `unique: [period: 60, keys: [:member_id, :credential_id]]` prevents
  rapid-fire duplicate jobs for the same member or credential within a
  60-second window.

  ## Credential mode

  When enqueued with `credential_id` (by `Manager.record_credential_spend/2`),
  only the credential's **daily** counter is drift-corrected — credentials
  have no monthly counter.
  """

  use Oban.Worker,
    queue: :budgets,
    max_attempts: 3,
    unique: [period: 60, keys: [:member_id, :credential_id]]

  @impl true
  def perform(%Oban.Job{args: %{"credential_id" => credential_id}}) do
    Tokengate.Budgets.Manager.clear_sync_pending({:credential, credential_id})

    daily_micro =
      Tokengate.Budgets.Manager.load_credential_from_db(credential_id, period_start(:daily))

    Tokengate.Budgets.Manager.set_credential_from_db(credential_id, daily_micro)

    :ok
  end

  def perform(%Oban.Job{args: %{"member_id" => member_id}}) do
    member_id = normalize_member_id(member_id)

    # Clear the debounce mark BEFORE recomputing: any spend recorded after
    # this point will re-enqueue a fresh job. If we cleared it after
    # set_from_db, a concurrent record_spend could set the mark between our
    # clear and our write, then never fire a new job.
    Tokengate.Budgets.Manager.clear_sync_pending(member_id)

    daily_micro = compute_period_spend(member_id, :daily)
    monthly_micro = compute_period_spend(member_id, :monthly)

    Tokengate.Budgets.Manager.set_from_db(member_id, daily_micro, monthly_micro)

    :ok
  end

  # Helper to allow direct invocation in tests with atom-keyed args.
  def perform(%{credential_id: credential_id}) do
    perform(%Oban.Job{args: %{"credential_id" => credential_id}})
  end

  def perform(%{member_id: member_id}) do
    perform(%Oban.Job{args: %{"member_id" => member_id}})
  end

  defp compute_period_spend(member_id, :daily) do
    from = period_start(:daily)
    Tokengate.Budgets.Manager.load_from_db(member_id, from)
  end

  defp compute_period_spend(member_id, :monthly) do
    from = period_start(:monthly)
    Tokengate.Budgets.Manager.load_from_db(member_id, from)
  end

  defp period_start(:daily) do
    today = Date.utc_today()
    DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
  end

  defp period_start(:monthly) do
    today = Date.utc_today()
    first = Date.new!(today.year, today.month, 1)
    DateTime.new!(first, ~T[00:00:00], "Etc/UTC")
  end

  # Args arrive from Oban with string keys; member_id may be a binary UUID.
  # The Manager treats member_id as an opaque term, so no conversion is
  # needed beyond accepting whatever was serialized.
  defp normalize_member_id(member_id) when is_binary(member_id), do: member_id
  defp normalize_member_id(member_id), do: member_id
end
