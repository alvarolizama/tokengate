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
  every spend counter derived from the logs: monthly AND daily, per subject
  and global, plus the monthly limit counters (`{:limit, subject}`). Top-up
  pockets (`{:topup, id}`) are deliberately NOT cleared here — a top-up's
  consumption is not monthly. On the next `reserve/5` or `spend/1` call for
  each subject, the Manager lazy-loads from DB (which will be ~0 for the new
  month).
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
