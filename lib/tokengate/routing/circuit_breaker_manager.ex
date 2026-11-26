defmodule Tokengate.Routing.CircuitBreakerManager do
  @moduledoc """
  `DynamicSupervisor` that owns one `Tokengate.Routing.CircuitBreaker` process per
  provider credential, plus the public ETS fast-path table `:tokengate_breaker_states`.
  """

  use DynamicSupervisor

  alias Tokengate.Routing.CircuitBreaker

  @registry Tokengate.Routing.CircuitBreakerRegistry
  @ets_table CircuitBreaker.ets_table()

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

  Idempotent: safe to call concurrently.
  """
  @spec ensure_started(credential_id :: term()) :: :ok
  def ensure_started(credential_id) do
    case lookup(credential_id) do
      {:ok, _pid} ->
        :ok

      :error ->
        child_spec = {CircuitBreaker, credential_id: credential_id}

        case DynamicSupervisor.start_child(__MODULE__, child_spec) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          :ignore -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, {:already_started, _pid, _info}} -> :ok
        end
    end
  end

  @doc """
  Pure read-only availability check for routing selection (lock-free via ETS).

  Does NOT start a process for unknown credentials and does NOT consume a
  `:half_open` probe slot.
  """
  @spec usable?(credential_id :: term()) :: boolean()
  def usable?(credential_id) do
    case read_ets(credential_id) do
      {:ok, :closed, _probe_in_flight?, _epoch} ->
        true

      {:ok, :open, _probe_in_flight?, _epoch} ->
        false

      {:ok, :half_open, probe_in_flight?, _epoch} ->
        not probe_in_flight?

      :miss ->
        case lookup(credential_id) do
          {:ok, pid} -> CircuitBreaker.usable?(pid)
          :error -> true
        end
    end
  end

  @doc """
  Claims execution right before an upstream HTTP call:

    * `:closed` -> `{:ok, epoch}` (lock-free via ETS fast-path)
    * `:open` -> `{:error, :breaker_open}`
    * `:half_open` -> acquires the single probe slot with monitor + timeout, or
      returns `{:error, :probe_in_flight}` if another probe is active.
  """
  @spec claim_execution(credential_id :: term(), caller_pid :: pid()) ::
          {:ok, non_neg_integer()} | {:error, :breaker_open | :probe_in_flight}
  def claim_execution(credential_id, caller_pid \\ self()) when is_pid(caller_pid) do
    case read_ets(credential_id) do
      {:ok, :closed, false, epoch} ->
        {:ok, epoch}

      {:ok, :open, _probe_in_flight?, _epoch} ->
        {:error, :breaker_open}

      {:ok, :half_open, true, _epoch} ->
        {:error, :probe_in_flight}

      _ ->
        ensure_started(credential_id)

        case lookup(credential_id) do
          {:ok, pid} -> CircuitBreaker.claim_probe(pid, caller_pid)
          :error -> {:ok, 0}
        end
    end
  end

  @doc """
  Releases a `:half_open` probe slot without recording success/failure when a
  request aborts locally before reaching the upstream provider.
  """
  @spec release_probe(credential_id :: term(), caller_pid :: pid()) :: :ok
  def release_probe(credential_id, caller_pid \\ self()) when is_pid(caller_pid) do
    case read_ets(credential_id) do
      {:ok, :closed, _, _} ->
        :ok

      {:ok, :open, _, _} ->
        :ok

      _ ->
        case lookup(credential_id) do
          {:ok, pid} -> CircuitBreaker.release_probe(pid, caller_pid)
          :error -> :ok
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
    allow_registered(credential_id)
  end

  @doc """
  Records a successful request for `credential_id`.
  """
  @spec record_success(credential_id :: term(), opts :: keyword()) :: :ok
  def record_success(credential_id, opts \\ []) do
    ensure_started(credential_id)

    case lookup(credential_id) do
      {:ok, pid} -> CircuitBreaker.record_success(pid, opts)
      :error -> :ok
    end
  end

  @doc """
  Records a failed request for `credential_id`.
  """
  @spec record_failure(
          credential_id :: term(),
          reason :: atom(),
          error_message :: String.t() | nil,
          opts :: keyword()
        ) :: :ok
  def record_failure(credential_id, reason, error_message \\ nil, opts \\ []) do
    ensure_started(credential_id)

    case lookup(credential_id) do
      {:ok, pid} -> CircuitBreaker.record_failure(pid, reason, error_message, opts)
      :error -> :ok
    end
  end

  @doc """
  Returns the current state of the breaker for `credential_id`.
  """
  @spec status(credential_id :: term()) :: :closed | :open | :half_open
  def status(credential_id) do
    case read_ets(credential_id) do
      {:ok, state, _probe_in_flight?, _epoch} ->
        state

      :miss ->
        case lookup(credential_id) do
          {:ok, pid} -> CircuitBreaker.status(pid)
          :error -> :closed
        end
    end
  end

  @doc """
  Returns a details map for `credential_id`'s breaker.
  """
  @spec details(credential_id :: term()) :: map()
  def details(credential_id) do
    case lookup(credential_id) do
      {:ok, pid} ->
        CircuitBreaker.details(pid)

      :error ->
        %{
          state: :closed,
          failures: 0,
          open_streak: 0,
          probe_in_flight?: false,
          last_reason: nil,
          last_error_message: nil,
          opened_at: nil,
          next_probe_at: nil
        }
    end
  end

  @doc """
  Count of circuit breakers currently `:open` or `:half_open` (non-closed
  credentials needing recovery or attention).
  """
  @spec count_open() :: non_neg_integer()
  def count_open do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.count(fn {id, pid} ->
      case read_ets(id) do
        {:ok, state, _, _} -> state in [:open, :half_open]
        :miss -> CircuitBreaker.status(pid) in [:open, :half_open]
      end
    end)
  end

  @doc """
  Returns `%{credential_id => state}` for every registered breaker in one
  Registry sweep.
  """
  @spec status_all() :: %{term() => :closed | :open | :half_open}
  def status_all do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Map.new(fn {id, pid} ->
      state =
        case read_ets(id) do
          {:ok, s, _, _} -> s
          :miss -> CircuitBreaker.status(pid)
        end

      {id, state}
    end)
  end

  @doc """
  Returns `%{credential_id => details_map}` only for breakers NOT in `:closed` state.
  """
  @spec open_breakers() :: %{term() => map()}
  def open_breakers do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Map.new(fn {id, pid} -> {id, CircuitBreaker.details(pid)} end)
    |> Enum.filter(fn {_id, details} -> details.state != :closed end)
    |> Map.new()
  end

  @doc """
  Forces the breaker for `credential_id` back to `:closed` (admin use).
  """
  @spec reset(credential_id :: term()) :: :ok
  def reset(credential_id) do
    case lookup(credential_id) do
      {:ok, pid} -> CircuitBreaker.reset(pid)
      :error -> :ok
    end
  end

  ## DynamicSupervisor callback ##############################################

  @impl true
  def init(_opts) do
    ensure_ets_table()
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  ## Internal helpers ########################################################

  defp ensure_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  defp read_ets(credential_id) do
    case :ets.lookup(@ets_table, credential_id) do
      [{^credential_id, state, probe_in_flight?, epoch}] ->
        {:ok, state, probe_in_flight?, epoch}

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp lookup(credential_id) do
    case Registry.lookup(@registry, credential_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp allow_registered(credential_id) do
    case lookup(credential_id) do
      {:ok, pid} -> CircuitBreaker.allow?(pid)
      :error -> true
    end
  end
end
