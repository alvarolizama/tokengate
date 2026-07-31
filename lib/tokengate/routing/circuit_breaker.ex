defmodule Tokengate.Routing.CircuitBreaker do
  @moduledoc """
  A `:gen_statem` circuit breaker with one instance per provider credential.

  States:

    * `:closed`    - requests pass. Each failure increments a consecutive-failure
      counter; a success resets it to 0. At `threshold` consecutive failures the
      breaker transitions to `:open`.
    * `:open`      - requests are rejected immediately. After `cooldown_ms`
      (state_timeout) the breaker transitions to `:half_open`. If the last
      failure reason was `:rate_limited`, `rate_limit_cooldown_ms` is used
      instead (providers recover fast from 429s).
    * `:half_open` - the next request is allowed through as a probe. Only one
      probe may be in flight at a time; further `allow?/1` calls return `false`
      until the probe resolves. On probe success -> `:closed`; on failure ->
      back to `:open` with a fresh cooldown.

  Failure reasons:

    * `:server_error` - counts normally.
    * `:timeout`      - counts normally.
    * `:rate_limited`  - counts AND selects the short cooldown if the breaker trips.
    * `:client_error`  - **never counts** (4xx are the caller's fault); ignored entirely.
  """

  @behaviour :gen_statem

  # Reason used to pick the short cooldown when the breaker trips on :rate_limited.
  @short_cooldown_reasons [:rate_limited]
  # Reasons that count toward the failure threshold.
  # :auth_error is NOT here — it triggers permanent deactivation in the DB,
  # not a temporary breaker cooldown.
  @counting_reasons [:server_error, :timeout, :rate_limited]

  @default_cooldown_ms 60_000
  @default_threshold 5
  @default_rate_limit_cooldown_ms 10_000

  ## Child spec (for supervisors / start_supervised) ##########################

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  ## Public API ##############################################################

  @doc """
  Starts a circuit breaker for the given `:credential_id`.

  Options:

    * `:credential_id`        - (required) unique identifier for the provider credential.
    * `:cooldown_ms`          - time the breaker stays open before probing (default 60_000).
    * `:threshold`            - consecutive failures that trip the breaker (default 5).
    * `:rate_limit_cooldown_ms` - short cooldown used when the trip reason was `:rate_limited`
      (default 10_000).

  The process is registered via `{:via, Registry, {Tokengate.Routing.CircuitBreakerRegistry, credential_id}}`.
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) when is_list(opts) do
    credential_id = Keyword.fetch!(opts, :credential_id)
    name = {:via, Registry, {Tokengate.Routing.CircuitBreakerRegistry, credential_id}}

    data = %{
      credential_id: credential_id,
      cooldown_ms: Keyword.get(opts, :cooldown_ms, config(:cooldown_ms, @default_cooldown_ms)),
      threshold: Keyword.get(opts, :threshold, config(:threshold, @default_threshold)),
      rate_limit_cooldown_ms:
        Keyword.get(
          opts,
          :rate_limit_cooldown_ms,
          config(:rate_limit_cooldown_ms, @default_rate_limit_cooldown_ms)
        ),
      failures: 0,
      last_reason: nil,
      probe_in_flight?: false,
      opened_at: nil
    }

    :gen_statem.start_link(__MODULE__, data, name: name)
  end

  @doc "Returns `true` when a request is allowed through, `false` otherwise."
  @spec allow?(breaker :: GenServer.server()) :: boolean()
  def allow?(breaker) do
    :gen_statem.call(breaker, :allow?)
  end

  @doc "Records a successful request and resets the failure counter."
  @spec record_success(breaker :: GenServer.server()) :: :ok
  def record_success(breaker) do
    :gen_statem.cast(breaker, :record_success)
  end

  @doc """
  Records a failed request.

  `reason` is one of `:server_error`, `:timeout`, `:rate_limited`, `:client_error`.
  `:client_error` is ignored entirely and never counts toward the threshold.
  """
  @spec record_failure(breaker :: GenServer.server(), reason :: atom()) :: :ok
  def record_failure(breaker, reason) when is_atom(reason) do
    :gen_statem.cast(breaker, {:record_failure, reason})
  end

  @doc "Returns the current state (`:closed`, `:open`, or `:half_open`)."
  @spec status(breaker :: GenServer.server()) :: :closed | :open | :half_open
  def status(breaker) do
    :gen_statem.call(breaker, :status)
  end

  @doc "Forces the breaker back to `:closed` (admin use)."
  @spec reset(breaker :: GenServer.server()) :: :ok
  def reset(breaker) do
    :gen_statem.call(breaker, :reset)
  end

  @doc """
  Returns a details map with the full breaker state:

    * `:state` — `:closed`, `:open`, or `:half_open`
    * `:failures` — consecutive failure count
    * `:last_reason` — reason of the last failure that tripped or refreshed the breaker
    * `:opened_at` — `DateTime` when the breaker transitioned to `:open`, or `nil`
  """
  @spec details(breaker :: GenServer.server()) :: map()
  def details(breaker) do
    :gen_statem.call(breaker, :details)
  end

  ## :gen_statem callbacks ###################################################

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(data) do
    # :gen_statem does not reliably register via {:via, Registry, ...} on all
    # OTP versions, so we register the pid manually here. If a breaker for this
    # credential is already running, return :ignore so the caller sees the
    # existing process via the Registry (idempotent ensure_started).
    case Registry.register(Tokengate.Routing.CircuitBreakerRegistry, data.credential_id, nil) do
      {:ok, _} ->
        {:ok, :closed, data}

      {:error, {:already_registered, _pid}} ->
        :ignore
    end
  end

  # -- :closed ----------------------------------------------------------------

  def closed({:call, from}, :allow?, data) do
    {:keep_state, data, {:reply, from, true}}
  end

  def closed({:call, from}, :status, data) do
    {:keep_state, data, {:reply, from, :closed}}
  end

  def closed({:call, from}, :details, data) do
    {:keep_state, data,
     {:reply, from,
      %{state: :closed, failures: data.failures, last_reason: data.last_reason, opened_at: nil}}}
  end

  def closed({:call, from}, :reset, data) do
    {:keep_state,
     %{data | failures: 0, last_reason: nil, probe_in_flight?: false, opened_at: nil},
     {:reply, from, :ok}}
  end

  def closed(:cast, :record_success, data) do
    {:keep_state, %{data | failures: 0}}
  end

  def closed(:cast, {:record_failure, reason}, data) do
    handle_closed_failure(reason, data)
  end

  # -- :open ------------------------------------------------------------------

  def open({:call, from}, :allow?, data) do
    {:keep_state, data, {:reply, from, false}}
  end

  def open({:call, from}, :status, data) do
    {:keep_state, data, {:reply, from, :open}}
  end

  def open({:call, from}, :details, data) do
    {:keep_state, data,
     {:reply, from,
      %{
        state: :open,
        failures: data.failures,
        last_reason: data.last_reason,
        opened_at: data.opened_at
      }}}
  end

  def open({:call, from}, :reset, data) do
    {:next_state, :closed,
     %{data | failures: 0, last_reason: nil, probe_in_flight?: false, opened_at: nil},
     {:reply, from, :ok}}
  end

  def open(:cast, :record_success, data) do
    # A late success arriving while open is a no-op; the cooldown still drives the
    # transition to half_open.
    {:keep_state, data}
  end

  def open(:cast, {:record_failure, _reason}, data) do
    # Late failures while open refresh the cooldown so a sustained outage keeps
    # the breaker open.
    cooldown = cooldown_for(data.last_reason, data)
    {:keep_state, %{data | probe_in_flight?: false}, {:state_timeout, cooldown, :probe}}
  end

  def open(:state_timeout, :probe, data) do
    {:next_state, :half_open, %{data | probe_in_flight?: false}}
  end

  # -- :half_open -------------------------------------------------------------

  def half_open({:call, from}, :allow?, data) do
    if data.probe_in_flight? do
      {:keep_state, data, {:reply, from, false}}
    else
      {:keep_state, %{data | probe_in_flight?: true}, {:reply, from, true}}
    end
  end

  def half_open({:call, from}, :status, data) do
    {:keep_state, data, {:reply, from, :half_open}}
  end

  def half_open({:call, from}, :details, data) do
    {:keep_state, data,
     {:reply, from,
      %{
        state: :half_open,
        failures: data.failures,
        last_reason: data.last_reason,
        opened_at: data.opened_at
      }}}
  end

  def half_open({:call, from}, :reset, data) do
    {:next_state, :closed,
     %{data | failures: 0, last_reason: nil, probe_in_flight?: false, opened_at: nil},
     {:reply, from, :ok}}
  end

  def half_open(:cast, :record_success, data) do
    {:next_state, :closed,
     %{data | failures: 0, last_reason: nil, probe_in_flight?: false, opened_at: nil}}
  end

  def half_open(:cast, {:record_failure, reason}, data) do
    new_data = %{data | failures: data.failures + 1, last_reason: reason, probe_in_flight?: false}
    cooldown = cooldown_for(reason, data)

    {:next_state, :open, new_data, {:state_timeout, cooldown, :probe}}
  end

  ## Internal helpers ########################################################

  defp handle_closed_failure(reason, data) do
    if reason in @counting_reasons do
      failures = data.failures + 1

      if failures >= data.threshold do
        cooldown = cooldown_for(reason, data)
        now = DateTime.utc_now()

        {:next_state, :open,
         %{
           data
           | failures: failures,
             last_reason: reason,
             probe_in_flight?: false,
             opened_at: now
         }, {:state_timeout, cooldown, :probe}}
      else
        {:keep_state, %{data | failures: failures, last_reason: reason}}
      end
    else
      # :client_error or any non-counting reason: ignore entirely.
      {:keep_state, data}
    end
  end

  defp cooldown_for(reason, data) do
    if reason in @short_cooldown_reasons do
      data.rate_limit_cooldown_ms
    else
      data.cooldown_ms
    end
  end

  defp config(key, default) do
    :tokengate
    |> Application.get_env(:circuit_breaker, [])
    |> Keyword.get(key, default)
  end
end
