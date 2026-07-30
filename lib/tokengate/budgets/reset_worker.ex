defmodule Tokengate.Budgets.ResetWorker do
  @moduledoc """
  Oban worker that resets all monthly ETS budget counters to 0 on the 1st
  of each month at 00:00 UTC.

  This ensures that the `Budgets.Manager` monthly spend starts fresh for
  every member, independent of the daily counters.

  ## Scheduling

  Wired into `config/config.exs` Oban `:crontab`:

      {"0 0 1 * *", Tokengate.Budgets.ResetWorker}

  ## What it does

  Calls `Tokengate.Budgets.Manager.reset_monthly_counters/0`, which deletes
  every `{member_id, :monthly}` entry from the `:tokengate_budgets` ETS
  table. On the next `record_spend/2` or `spend/1` call for each member,
  the Manager lazy-loads from DB (which will be ~0 for the new month).
  """

  use Oban.Worker,
    queue: :budgets,
    max_attempts: 1

  @impl true
  def perform(_job) do
    Tokengate.Budgets.Manager.reset_monthly_counters()
    :ok
  end
end
