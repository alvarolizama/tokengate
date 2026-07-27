defmodule Tokengate.Routing.Supervisor do
  @moduledoc """
  Supervisor for routing-related processes.

  Supervises:

    * `Tokengate.Routing.StickyTracker` – ETS-backed sticky-route GenServer
      (`{api_key_hash, model_alias_id} -> model_provider_id`).
    * `Registry` (`Tokengate.Routing.CircuitBreakerRegistry`) – name registry
      for per-credential circuit breakers.
    * `Tokengate.Routing.CircuitBreakerManager` – DynamicSupervisor that
      lazily starts one `Tokengate.Routing.CircuitBreaker` per credential.
  """

  use Supervisor

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    children = [
      {Tokengate.Routing.StickyTracker, name: Tokengate.Routing.StickyTracker},
      {Registry, keys: :unique, name: Tokengate.Routing.CircuitBreakerRegistry},
      Tokengate.Routing.CircuitBreakerManager
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
