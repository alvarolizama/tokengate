defmodule Tokengate.Routing.RecoveryProber do
  @moduledoc """
  Background recovery prober for half-open circuit breakers.

  Why this exists:
  When a primary provider opens its circuit breaker, active traffic sticks to
  the fallback provider (`StickyTracker`, 3–15 min TTL). Even after the
  primary's cooldown expires and its breaker enters `:half_open`, no live
  request may touch it until a sticky TTL expires — leaving the primary idle
  in `:half_open` while traffic stays on expensive or degraded fallbacks.

  This worker listens for `{:breaker_half_open, credential_id}` on PubSub
  `"alerts"` (plus a 60s sweep for any idle `:half_open` breaker) and executes a
  lightweight `health_check/2` in a supervised Task:

    * `:ok` -> closes the breaker (`:half_open -> :closed`) so new requests and
      un-stuck keys immediately return to the primary provider.
    * `:server_error | :timeout | :rate_limited` -> re-opens with exponential
      backoff without exposing any live user request to a failed probe.
    * Any other error (e.g. `404` when an upstream has no `/models` route) ->
      releases the probe slot so live traffic can still probe normally.

  Disabled by default in `config/test.exs` (`:circuit_breaker_auto_probe, false`)
  so unrelated tests with fake base URLs never make outbound HTTP requests.
  """

  use GenServer

  require Logger

  alias Tokengate.Providers.Credential
  alias Tokengate.Proxy.ProviderAdapter
  alias Tokengate.Repo
  alias Tokengate.Routing.CircuitBreakerManager

  @pubsub Tokengate.PubSub
  @alerts_topic "alerts"
  @sweep_interval_ms 60_000
  @task_sup Tokengate.Routing.RecoveryTaskSupervisor

  ## Public API ##############################################################

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Triggers a background probe for `credential_id` immediately (used by tests
  and manual recovery triggers). Returns `:ok`.
  """
  @spec probe_async(binary(), keyword()) :: :ok
  def probe_async(credential_id, opts \\ []) when is_binary(credential_id) do
    run_probe_task(credential_id, opts)
    :ok
  end

  ## GenServer callbacks ###################################################

  @impl true
  def init(opts) do
    subscribe_alerts()
    schedule_sweep(Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms))
    {:ok, %{sweep_interval_ms: Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)}}
  end

  @impl true
  def handle_info({:breaker_half_open, credential_id}, state) when is_binary(credential_id) do
    if auto_probe_enabled?() do
      run_probe_task(credential_id, [])
    end

    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    if auto_probe_enabled?() do
      CircuitBreakerManager.status_all()
      |> Enum.each(fn
        {cred_id, :half_open} ->
          if CircuitBreakerManager.usable?(cred_id) do
            run_probe_task(cred_id, [])
          end

        _ ->
          :ok
      end)
    end

    schedule_sweep(state.sweep_interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Internal ################################################################

  defp run_probe_task(credential_id, opts) do
    fun = fn -> probe_credential(credential_id, opts) end

    case Process.whereis(@task_sup) do
      nil -> Task.start(fun)
      _pid -> Task.Supervisor.start_child(@task_sup, fun)
    end
  end

  defp probe_credential(credential_id, opts) do
    case CircuitBreakerManager.claim_execution(credential_id, self()) do
      {:ok, epoch} ->
        execute_probe(credential_id, epoch, opts)

      {:error, _reason} ->
        :ok
    end
  end

  defp execute_probe(credential_id, epoch, opts) do
    health_check_fun =
      Keyword.get(opts, :health_check_fun) ||
        Application.get_env(:tokengate, :recovery_health_check_fun) ||
        (&default_health_check/2)

    case load_active_credential(credential_id) do
      {:ok, credential} ->
        case health_check_fun.(credential.provider, credential) do
          :ok ->
            CircuitBreakerManager.record_success(credential_id,
              source: :health_check,
              epoch: epoch
            )

          {:error, reason} when reason in [:server_error, :timeout, :rate_limited] ->
            CircuitBreakerManager.record_failure(
              credential_id,
              reason,
              "background health_check failed (#{reason})",
              epoch: epoch
            )

          {:error, _non_counting} ->
            # E.g. provider returns 404/405 on GET /models — do not punish and do
            # not falsely close; release so live traffic can still probe.
            CircuitBreakerManager.release_probe(credential_id, self())
        end

      :skip ->
        CircuitBreakerManager.release_probe(credential_id, self())
    end
  rescue
    e ->
      Logger.debug("recovery prober error for #{credential_id}: #{inspect(e)}")
      CircuitBreakerManager.release_probe(credential_id, self())
  catch
    :exit, _ ->
      CircuitBreakerManager.release_probe(credential_id, self())
  end

  defp load_active_credential(credential_id) do
    case Ecto.UUID.cast(credential_id) do
      {:ok, uuid} ->
        case Repo.get(Credential, uuid) |> Repo.preload(:provider) do
          %Credential{status: "active", provider: %{} = _provider} = cred -> {:ok, cred}
          _ -> :skip
        end

      :error ->
        :skip
    end
  end

  defp default_health_check(provider, credential) do
    ProviderAdapter.dispatch(provider).health_check(provider, credential)
  end

  defp subscribe_alerts do
    Phoenix.PubSub.subscribe(@pubsub, @alerts_topic)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp schedule_sweep(ms) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :sweep, ms)
  end

  defp auto_probe_enabled? do
    Application.get_env(:tokengate, :circuit_breaker_auto_probe, true)
  end
end
