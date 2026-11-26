defmodule Tokengate.Routing.Supervisor do
  @moduledoc """
  Supervisor for routing-related processes.

  Supervises:

    * `Tokengate.Routing.StickyTracker` – ETS-backed sticky-route GenServer
      (`{api_key_hash, model_id} -> model_provider_id`).
    * `Tokengate.Routing.CredentialHealth` – ETS-backed soft health tracker
      per credential (slow-credential degradation).
    * `Tokengate.Routing.PoolCounters` – ETS + `:atomics` counters, one per
      pool lane, for per-request rotation inside a credential pool.
    * `Registry` (`Tokengate.Routing.CircuitBreakerRegistry`) – name registry
      for per-credential circuit breakers.
    * `Tokengate.Routing.CircuitBreakerManager` – DynamicSupervisor that
      lazily starts one `Tokengate.Routing.CircuitBreaker` per credential.
    * `Tokengate.SmartRouter.SessionPin` – ETS pin
      `{subject_id, session_key} -> destination` (Layer 0).
    * `Tokengate.SmartRouter.DecisionCache` – short-lived ETS cache of
      classifier answers.
    * `Tokengate.Routing.DecisionTaskSupervisor` – isolated, timeout-bounded
      `Task.Supervisor` for the on-demand classifier call.
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
      {Tokengate.Routing.CredentialHealth, name: Tokengate.Routing.CredentialHealth},
      {Tokengate.Routing.PoolCounters, name: Tokengate.Routing.PoolCounters},
      {Registry, keys: :unique, name: Tokengate.Routing.CircuitBreakerRegistry},
      Tokengate.Routing.CircuitBreakerManager,
      {Tokengate.SmartRouter.SessionPin, name: Tokengate.SmartRouter.SessionPin},
      {Tokengate.SmartRouter.DecisionCache, name: Tokengate.SmartRouter.DecisionCache},
      {Task.Supervisor, name: Tokengate.Routing.DecisionTaskSupervisor},
      {Task.Supervisor, name: Tokengate.Routing.RecoveryTaskSupervisor},
      Tokengate.Routing.RecoveryProber
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
