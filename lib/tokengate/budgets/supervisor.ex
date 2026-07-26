defmodule Tokengate.Budgets.Supervisor do
  @moduledoc """
  Supervises the budgets subsystem.

  Children:
  - `Tokengate.Budgets.Manager` — ETS-backed micro-USD spend cache.

  The parent application (`Tokengate.Application`) wires this supervisor
  into its supervision tree. Tests start `Tokengate.Budgets.Manager`
  directly via `start_supervised!/1`.

  Note: `Tokengate.Budgets.SyncWorker` is an Oban worker and is not a
  supervised process — it runs on the `:budgets` Oban queue.
  """

  use Supervisor

  @doc false
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Tokengate.Budgets.Manager
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
