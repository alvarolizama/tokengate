defmodule Tokengate.Limits.Supervisor do
  @moduledoc """
  Supervises the limits subsystem.

  Children:
  - `Tokengate.Limits.Manager` — ETS-backed RPM + concurrency gate.

  The parent application (`Tokengate.Application`) wires this supervisor
  into its supervision tree. Tests start `Tokengate.Limits.Manager`
  directly via `start_supervised!/1`.
  """

  use Supervisor

  @doc false
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Tokengate.Limits.Manager
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
