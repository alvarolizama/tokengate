defmodule Tokengate.Routing.CircuitBreakerManager do
  @moduledoc """
  `DynamicSupervisor` that owns one `Tokengate.Routing.CircuitBreaker` process per
  provider credential.

  The breakers are registered via `{:via, Registry, {Tokengate.Routing.CircuitBreakerRegistry, credential_id}}`,
  so the parent application must start a unique-key registry named
  `Tokengate.Routing.CircuitBreakerRegistry` alongside this supervisor.
  """

  use DynamicSupervisor

  @registry Tokengate.Routing.CircuitBreakerRegistry

  ## Public API ##############################################################

  @doc """
  Starts the manager under the name `__MODULE__`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensures a circuit breaker exists for `credential_id`.

  Idempotent: safe to call concurrently. Returns `:ok` once a breaker is running
  and registered (whether it was just started or already existed).
  """
  @spec ensure_started(credential_id :: term()) :: :ok
  def ensure_started(credential_id) do
    case lookup(credential_id) do
      {:ok, _pid} ->
        :ok

      :error ->
        child_spec = {Tokengate.Routing.CircuitBreaker, credential_id: credential_id}

        case DynamicSupervisor.start_child(__MODULE__, child_spec) do
          {:ok, _pid} ->
            # The child registers itself in init; wait until the entry is visible
            # so a subsequent lookup cannot race the registration.
            wait_until_registered(credential_id)
            :ok

          {:ok, _pid, _info} ->
            wait_until_registered(credential_id)
            :ok

          :ignore ->
            # A concurrent starter won the race; the existing process is now
            # (or imminently) registered. Wait for it to appear.
            wait_until_registered(credential_id)
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, {:already_started, _pid, _info}} ->
            :ok
        end
    end
  end

  @doc """
  Returns `true` when a request is allowed through for `credential_id`.

  Unknown credentials are lazily started (in `:closed`) and allowed.
  """
  @spec allow?(credential_id :: term()) :: boolean()
  def allow?(credential_id) do
    ensure_started(credential_id)
    lookup!(credential_id) |> Tokengate.Routing.CircuitBreaker.allow?()
  end

  @doc """
  Records a successful request for `credential_id`.

  Ensures a breaker exists first so successes are always tracked.
  """
  @spec record_success(credential_id :: term()) :: :ok
  def record_success(credential_id) do
    ensure_started(credential_id)
    lookup!(credential_id) |> Tokengate.Routing.CircuitBreaker.record_success()
  end

  @doc """
  Records a failed request for `credential_id`.

  Ensures a breaker exists first so failures for a new credential are tracked.
  An optional `error_message` (the upstream provider's error body) is stored in
  the breaker state for observability — surfaced in `details/1` and the admin UI.
  """
  @spec record_failure(
          credential_id :: term(),
          reason :: atom(),
          error_message :: String.t() | nil
        ) ::
          :ok
  def record_failure(credential_id, reason, error_message \\ nil) do
    ensure_started(credential_id)

    lookup!(credential_id)
    |> Tokengate.Routing.CircuitBreaker.record_failure(reason, error_message)
  end

  @doc """
  Returns the current state of the breaker for `credential_id`.

  Returns `:closed` for an unknown credential without starting a process.
  """
  @spec status(credential_id :: term()) :: :closed | :open | :half_open
  def status(credential_id) do
    case lookup(credential_id) do
      {:ok, pid} -> Tokengate.Routing.CircuitBreaker.status(pid)
      :error -> :closed
    end
  end

  @doc """
  Returns a details map for `credential_id`'s breaker:

    * `:state` — `:closed`, `:open`, or `:half_open`
    * `:failures` — consecutive failure count
    * `:last_reason` — reason of the last failure
    * `:last_error_message` — upstream error message of the last failure, or `nil`
    * `:opened_at` — `DateTime` when the breaker opened, or `nil`

  Returns a default closed-state map for unknown credentials.
  """
  @spec details(credential_id :: term()) :: map()
  def details(credential_id) do
    case lookup(credential_id) do
      {:ok, pid} ->
        Tokengate.Routing.CircuitBreaker.details(pid)

      :error ->
        %{state: :closed, failures: 0, last_reason: nil, last_error_message: nil, opened_at: nil}
    end
  end

  @doc """
  Count of circuit breakers currently `:open` (failing credentials cut off
  from routing). Iterates the registered breakers — cheap for the handful
  of credentials a gateway manages.
  """
  @spec count_open() :: non_neg_integer()
  def count_open do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.count(fn {_id, pid} -> Tokengate.Routing.CircuitBreaker.status(pid) == :open end)
  end

  @doc """
  Returns `%{credential_id => state}` for every registered breaker in one
  Registry sweep, instead of one lookup + GenServer call per credential
  (dashboard pages that render a status badge per credential).
  """
  @spec status_all() :: %{term() => :closed | :open | :half_open}
  def status_all do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Map.new(fn {id, pid} -> {id, Tokengate.Routing.CircuitBreaker.status(pid)} end)
  end

  @doc """
  Returns `%{credential_id => details_map}` only for breakers NOT in
  `:closed` state. One Registry sweep — avoids loading every credential
  from the DB just to filter them in memory (AlertsLive).
  """
  @spec open_breakers() :: %{term() => map()}
  def open_breakers do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Map.new(fn {id, pid} -> {id, Tokengate.Routing.CircuitBreaker.details(pid)} end)
    |> Enum.filter(fn {_id, details} -> details.state != :closed end)
    |> Map.new()
  end

  @doc """
  Forces the breaker for `credential_id` back to `:closed` (admin use).
  Safe to call when no breaker exists.
  """
  @spec reset(credential_id :: term()) :: :ok
  def reset(credential_id) do
    case lookup(credential_id) do
      {:ok, pid} -> Tokengate.Routing.CircuitBreaker.reset(pid)
      :error -> :ok
    end
  end

  ## DynamicSupervisor callback ##############################################

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  ## Internal helpers ########################################################

  defp lookup(credential_id) do
    case Registry.lookup(@registry, credential_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  # The child process registers itself during init; there's a brief window
  # between DynamicSupervisor.start_child returning :ok and the Registry entry
  # being visible. Poll until it appears so callers never see a phantom miss.
  defp wait_until_registered(credential_id), do: wait_until_registered(credential_id, 0)

  defp wait_until_registered(_credential_id, 200) do
    :ok
  end

  defp wait_until_registered(credential_id, attempts) do
    case lookup(credential_id) do
      {:ok, _pid} -> :ok
      :error -> wait_until_registered(credential_id, attempts + 1)
    end
  end

  defp lookup!(credential_id) do
    case lookup(credential_id) do
      {:ok, pid} -> pid
      :error -> raise "no circuit breaker registered for #{inspect(credential_id)}"
    end
  end
end
