defmodule Tokengate.Metrics.Supervisor do
  @moduledoc """
  Supervises the metrics subsystem.

  Children:

    * `Tokengate.Metrics.Collector` — ETS-backed real-time counters GenServer.

  The parent application (`Tokengate.Application`) wires this supervisor
  into its supervision tree. Tests start `Tokengate.Metrics.Collector`
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
      Tokengate.Metrics.Collector
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
