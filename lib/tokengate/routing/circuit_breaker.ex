defmodule Tokengate.Routing.CircuitBreaker do
  @moduledoc """
  A `:gen_statem` circuit breaker with one instance per provider credential.

  States:

    * `:closed`    - requests pass. Each counting failure increments a
      consecutive-failure counter; a success resets it to 0. At `threshold`
      consecutive failures the breaker transitions to `:open`.
    * `:open`      - requests are rejected immediately. After `cooldown_ms`
      (state_timeout, or `rate_limit_cooldown_ms` / `Retry-After`) the breaker
      transitions to `:half_open`. Late failures arriving while already `:open`
      **never** reset the cooldown timer, so concurrent in-flight bursts cannot
      trap the breaker in `:open` forever.
    * `:half_open` - a single probe may run at a time (`probe_in_flight?: true`).
      The probe lease monitors the caller pid (`Process.monitor/1`) and sets a
      `probe_timeout_ms` guard: if the caller crashes, aborts before sending the
      upstream call (`release_probe/2`), or times out, the slot releases
      automatically (no permanent `:half_open` deadlock).
      On probe success -> `:closed`; on counting failure -> back to `:open` with
      exponential backoff + jitter. Non-counting failures (`:bad_request`,
      `:client_error`, `:auth_error`, `:model_not_available`, `:billing_error`,
      `:gateway_timeout`) release the probe slot without reopening the circuit.

  Read-only routing checks (`usable?/1`) read the published ETS state without
  acquiring a probe; probe acquisition (`claim_probe/2`) happens only right
  before the upstream HTTP call.

  Failure reasons:

    * `:server_error` - counts normally.
    * `:timeout`      - counts normally.
    * `:rate_limited` - counts AND selects the short cooldown (or `Retry-After`).
    * `:client_error`, `:bad_request`, `:auth_error`, `:model_not_available`,
      `:billing_error`, `:gateway_timeout` - **never count** in any state.
  """

  @behaviour :gen_statem

  @short_cooldown_reasons [:rate_limited]
  @counting_reasons [:server_error, :timeout, :rate_limited]

  require Logger

  @pubsub Tokengate.PubSub
  @alerts_topic "alerts"
  @ets_table :tokengate_breaker_states

  @default_cooldown_ms 60_000
  @default_threshold 5
  @default_rate_limit_cooldown_ms 10_000
  @default_max_cooldown_ms 300_000
  @default_probe_timeout_ms 60_000

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

  @doc false
  def ets_table, do: @ets_table

  @doc """
  Starts a circuit breaker for the given `:credential_id`.
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
      max_cooldown_ms:
        Keyword.get(opts, :max_cooldown_ms, config(:max_cooldown_ms, @default_max_cooldown_ms)),
      probe_timeout_ms:
        Keyword.get(opts, :probe_timeout_ms, config(:probe_timeout_ms, @default_probe_timeout_ms)),
      failures: 0,
      open_streak: 0,
      epoch: 0,
      last_reason: nil,
      last_error_message: nil,
      probe_in_flight?: false,
      probe_ref: nil,
      probe_owner: nil,
      opened_at: nil,
      next_probe_at: nil
    }

    :gen_statem.start_link(__MODULE__, data, name: name)
  end

  @doc """
  Pure read-only availability check. Does NOT acquire a `:half_open` probe slot.
  """
  @spec usable?(breaker :: GenServer.server()) :: boolean()
  def usable?(breaker) do
    :gen_statem.call(breaker, :usable?)
  end

  @doc """
  Returns `true` when a request is allowed through, `false` otherwise.

  In `:half_open`, claims the single probe slot with a process monitor +
  `probe_timeout_ms` guard on the calling pid. Prefer `usable?/1` during
  routing and `claim_probe/2` right before executing the upstream call.
  """
  @spec allow?(breaker :: GenServer.server()) :: boolean()
  def allow?(breaker) do
    :gen_statem.call(breaker, {:allow?, self()})
  end

  @doc """
  Claims execution right before an upstream HTTP call:

    * `:closed` -> `{:ok, epoch}`
    * `:open` -> `{:error, :breaker_open}`
    * `:half_open` -> `{:ok, epoch}` (monitoring `caller_pid` with probe timeout)
      or `{:error, :probe_in_flight}` if another probe is already running.
  """
  @spec claim_probe(breaker :: GenServer.server(), caller_pid :: pid()) ::
          {:ok, non_neg_integer()} | {:error, :breaker_open | :probe_in_flight}
  def claim_probe(breaker, caller_pid \\ self()) when is_pid(caller_pid) do
    :gen_statem.call(breaker, {:claim_probe, caller_pid})
  end

  @doc """
  Releases an active `:half_open` probe slot without recording success/failure
  (e.g. local cache hit, budget rejection, or pre-flight validation error).
  """
  @spec release_probe(breaker :: GenServer.server(), caller_pid :: pid()) :: :ok
  def release_probe(breaker, caller_pid \\ self()) when is_pid(caller_pid) do
    :gen_statem.call(breaker, {:release_probe, caller_pid})
  end

  @doc "Records a successful request and resets the failure counter."
  @spec record_success(breaker :: GenServer.server(), opts :: keyword()) :: :ok
  def record_success(breaker, opts \\ []) do
    :gen_statem.call(breaker, {:record_success, opts})
  end

  @doc """
  Records a failed request.

  Only `@counting_reasons` (`:server_error`, `:timeout`, `:rate_limited`) count
  in any state. Accepts optional `error_message` and `opts` (`:epoch`,
  `:retry_after_ms`).
  """
  @spec record_failure(
          breaker :: GenServer.server(),
          reason :: atom(),
          error_message :: String.t() | nil,
          opts :: keyword()
        ) :: :ok
  def record_failure(breaker, reason, error_message \\ nil, opts \\ []) when is_atom(reason) do
    :gen_statem.call(breaker, {:record_failure, reason, error_message, opts})
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
  Returns a details map with the full breaker state.
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
    case Registry.register(Tokengate.Routing.CircuitBreakerRegistry, data.credential_id, nil) do
      {:ok, _} ->
        sync_ets(:closed, data)
        {:ok, :closed, data}

      {:error, {:already_registered, _pid}} ->
        :ignore
    end
  end

  @impl true
  def terminate(_reason, _state, data) do
    delete_ets(data.credential_id)
    :ok
  end

  # -- :closed ----------------------------------------------------------------

  def closed({:call, from}, :usable?, data) do
    {:keep_state, data, {:reply, from, true}}
  end

  def closed({:call, from}, {:allow?, _caller_pid}, data) do
    {:keep_state, data, {:reply, from, true}}
  end

  def closed({:call, from}, :allow?, data) do
    {:keep_state, data, {:reply, from, true}}
  end

  def closed({:call, from}, {:claim_probe, _caller_pid}, data) do
    {:keep_state, data, {:reply, from, {:ok, data.epoch}}}
  end

  def closed({:call, from}, :status, data) do
    {:keep_state, data, {:reply, from, :closed}}
  end

  def closed({:call, from}, :details, data) do
    {:keep_state, data, {:reply, from, build_details(:closed, data)}}
  end

  def closed({:call, from}, :reset, data) do
    new_data = reset_data(data)
    sync_ets(:closed, new_data)
    {:keep_state, new_data, {:reply, from, :ok}}
  end

  def closed({:call, from}, {:release_probe, _caller_pid}, data),
    do: {:keep_state, data, {:reply, from, :ok}}

  def closed({:call, from}, {:record_success, _opts}, data) do
    new_data = %{data | failures: 0, open_streak: 0}
    {:keep_state, new_data, {:reply, from, :ok}}
  end

  def closed({:call, from}, {:record_failure, reason, error_message, opts}, data) do
    case handle_closed_failure(reason, error_message, opts, data) do
      {:keep_state, new_data} ->
        {:keep_state, new_data, {:reply, from, :ok}}

      {:next_state, :open, new_data, actions} ->
        {:next_state, :open, new_data, [{:reply, from, :ok} | List.wrap(actions)]}
    end
  end

  def closed(:cast, {:release_probe, _caller_pid}, data), do: {:keep_state, data}

  def closed(:cast, :record_success, data), do: closed(:cast, {:record_success, []}, data)

  def closed(:cast, {:record_success, _opts}, data) do
    new_data = %{data | failures: 0, open_streak: 0}
    {:keep_state, new_data}
  end

  def closed(:cast, {:record_failure, reason, error_message}, data) do
    closed(:cast, {:record_failure, reason, error_message, []}, data)
  end

  def closed(:cast, {:record_failure, reason, error_message, opts}, data) do
    handle_closed_failure(reason, error_message, opts, data)
  end

  def closed(:info, {:DOWN, _ref, :process, _pid, _reason}, data), do: {:keep_state, data}

  # -- :open ------------------------------------------------------------------

  def open({:call, from}, :usable?, data) do
    {:keep_state, data, {:reply, from, false}}
  end

  def open({:call, from}, {:allow?, _caller_pid}, data) do
    {:keep_state, data, {:reply, from, false}}
  end

  def open({:call, from}, :allow?, data) do
    {:keep_state, data, {:reply, from, false}}
  end

  def open({:call, from}, {:claim_probe, _caller_pid}, data) do
    {:keep_state, data, {:reply, from, {:error, :breaker_open}}}
  end

  def open({:call, from}, :status, data) do
    {:keep_state, data, {:reply, from, :open}}
  end

  def open({:call, from}, :details, data) do
    {:keep_state, data, {:reply, from, build_details(:open, data)}}
  end

  def open({:call, from}, :reset, data) do
    new_data = reset_data(data)
    sync_ets(:closed, new_data)
    {:next_state, :closed, new_data, {:reply, from, :ok}}
  end

  def open({:call, from}, {:release_probe, _caller_pid}, data),
    do: {:keep_state, data, {:reply, from, :ok}}

  def open({:call, from}, {:record_success, opts}, data) do
    case open(:cast, {:record_success, opts}, data) do
      {:keep_state, new_data} -> {:keep_state, new_data, {:reply, from, :ok}}
      {:next_state, :closed, new_data} -> {:next_state, :closed, new_data, {:reply, from, :ok}}
    end
  end

  def open({:call, from}, {:record_failure, reason, error_message, opts}, data) do
    {:keep_state, new_data} = open(:cast, {:record_failure, reason, error_message, opts}, data)
    {:keep_state, new_data, {:reply, from, :ok}}
  end

  def open(:cast, {:release_probe, _caller_pid}, data), do: {:keep_state, data}

  def open(:cast, :record_success, data), do: open(:cast, {:record_success, []}, data)

  def open(:cast, {:record_success, opts}, data) do
    if Keyword.get(opts, :source) == :health_check do
      new_data = reset_data(data)
      sync_ets(:closed, new_data)
      broadcast_closed(data.credential_id)
      {:next_state, :closed, new_data}
    else
      # Late success from an in-flight request; cooldown drives :half_open.
      {:keep_state, data}
    end
  end

  def open(:cast, {:record_failure, reason, error_message}, data) do
    open(:cast, {:record_failure, reason, error_message, []}, data)
  end

  def open(:cast, {:record_failure, reason, error_message, _opts}, data) do
    # NEVER restart {:state_timeout, _, :probe} on late in-flight failures, and
    # ignore non-counting reasons (400/404/403/402/524) completely. Only refresh
    # last_error_message when a counting failure arrives so observability sees
    # the freshest upstream reason while the cooldown advances monotonically.
    if reason in @counting_reasons and is_binary(error_message) and error_message != "" do
      {:keep_state, %{data | last_error_message: error_message}}
    else
      {:keep_state, data}
    end
  end

  def open(:state_timeout, :probe, data) do
    new_data = %{
      data
      | probe_in_flight?: false,
        probe_ref: nil,
        probe_owner: nil,
        next_probe_at: nil
    }

    sync_ets(:half_open, new_data)
    broadcast_half_open(data.credential_id)
    {:next_state, :half_open, new_data}
  end

  def open(:info, {:DOWN, _ref, :process, _pid, _reason}, data), do: {:keep_state, data}

  # -- :half_open ------------------------------------------------------------

  def half_open({:call, from}, :usable?, data) do
    {:keep_state, data, {:reply, from, not data.probe_in_flight?}}
  end

  def half_open({:call, {caller_pid, _tag} = from}, {:allow?, _pid}, data) do
    half_open({:call, from}, {:claim_probe_bool, caller_pid}, data)
  end

  def half_open({:call, {caller_pid, _tag} = from}, :allow?, data) do
    half_open({:call, from}, {:claim_probe_bool, caller_pid}, data)
  end

  def half_open({:call, from}, {:claim_probe_bool, caller_pid}, data) do
    if data.probe_in_flight? do
      {:keep_state, data, {:reply, from, false}}
    else
      new_data = acquire_probe_lease(data, caller_pid)
      sync_ets(:half_open, new_data)

      {:keep_state, new_data,
       [{:reply, from, true}, {:state_timeout, data.probe_timeout_ms, :probe_timeout}]}
    end
  end

  def half_open({:call, from}, {:claim_probe, caller_pid}, data) do
    if data.probe_in_flight? do
      {:keep_state, data, {:reply, from, {:error, :probe_in_flight}}}
    else
      new_data = acquire_probe_lease(data, caller_pid)
      sync_ets(:half_open, new_data)

      {:keep_state, new_data,
       [
         {:reply, from, {:ok, new_data.epoch}},
         {:state_timeout, data.probe_timeout_ms, :probe_timeout}
       ]}
    end
  end

  def half_open({:call, from}, :status, data) do
    {:keep_state, data, {:reply, from, :half_open}}
  end

  def half_open({:call, from}, :details, data) do
    {:keep_state, data, {:reply, from, build_details(:half_open, data)}}
  end

  def half_open({:call, from}, :reset, data) do
    new_data =
      data
      |> demonitor_probe()
      |> reset_data()

    sync_ets(:closed, new_data)
    {:next_state, :closed, new_data, {:reply, from, :ok}}
  end

  def half_open({:call, from}, {:release_probe, caller_pid}, data) do
    case half_open(:cast, {:release_probe, caller_pid}, data) do
      {:keep_state, new_data, action} ->
        {:keep_state, new_data, [{:reply, from, :ok} | List.wrap(action)]}

      {:keep_state, new_data} ->
        {:keep_state, new_data, {:reply, from, :ok}}
    end
  end

  def half_open({:call, from}, {:record_success, opts}, data) do
    case half_open(:cast, {:record_success, opts}, data) do
      {:keep_state, new_data} -> {:keep_state, new_data, {:reply, from, :ok}}
      {:next_state, :closed, new_data} -> {:next_state, :closed, new_data, {:reply, from, :ok}}
    end
  end

  def half_open({:call, from}, {:record_failure, reason, error_message, opts}, data) do
    case half_open(:cast, {:record_failure, reason, error_message, opts}, data) do
      {:keep_state, new_data} ->
        {:keep_state, new_data, {:reply, from, :ok}}

      {:keep_state, new_data, action} ->
        {:keep_state, new_data, [{:reply, from, :ok} | List.wrap(action)]}

      {:next_state, :open, new_data, actions} ->
        {:next_state, :open, new_data, [{:reply, from, :ok} | List.wrap(actions)]}
    end
  end

  def half_open(:cast, {:release_probe, caller_pid}, data) do
    if data.probe_in_flight? and (data.probe_owner == caller_pid or data.probe_owner == nil) do
      new_data = demonitor_probe(data)
      sync_ets(:half_open, new_data)
      {:keep_state, new_data, {:state_timeout, :cancel}}
    else
      {:keep_state, data}
    end
  end

  def half_open(:cast, :record_success, data), do: half_open(:cast, {:record_success, []}, data)

  def half_open(:cast, {:record_success, opts}, data) do
    if stale_epoch?(opts, data) do
      {:keep_state, data}
    else
      new_data =
        data
        |> demonitor_probe()
        |> reset_data()

      sync_ets(:closed, new_data)
      broadcast_closed(data.credential_id)
      {:next_state, :closed, new_data}
    end
  end

  def half_open(:cast, {:record_failure, reason, error_message}, data) do
    half_open(:cast, {:record_failure, reason, error_message, []}, data)
  end

  def half_open(:cast, {:record_failure, reason, error_message, opts}, data) do
    cond do
      stale_epoch?(opts, data) ->
        {:keep_state, data}

      reason not in @counting_reasons ->
        # Non-counting failure (400, 404, 402, 403, 524): do NOT reopen the
        # breaker — just release the probe slot so the next real request can
        # test upstream health.
        new_data = demonitor_probe(data)
        sync_ets(:half_open, new_data)
        {:keep_state, new_data, {:state_timeout, :cancel}}

      true ->
        reopen_from_half_open(reason, error_message, opts, data)
    end
  end

  def half_open(:info, {:DOWN, ref, :process, _pid, _reason}, %{probe_ref: ref} = data) do
    # The request process holding the probe slot crashed/exited without
    # calling record_success or record_failure. Free the slot automatically so
    # the breaker never deadlocks in :half_open.
    new_data = %{data | probe_in_flight?: false, probe_ref: nil, probe_owner: nil}
    sync_ets(:half_open, new_data)
    {:keep_state, new_data, {:state_timeout, :cancel}}
  end

  def half_open(:info, {:DOWN, _ref, :process, _pid, _reason}, data), do: {:keep_state, data}

  def half_open(:state_timeout, :probe_timeout, data) do
    # The probe stalled beyond probe_timeout_ms without completing or releasing.
    # Reopen with backoff so the breaker does not stay wedged.
    reopen_from_half_open(:timeout, "probe timed out", [], data)
  end

  ## Internal helpers ########################################################

  defp handle_closed_failure(reason, error_message, opts, data) do
    if reason in @counting_reasons do
      failures = data.failures + 1

      if failures >= data.threshold do
        streak = 1
        epoch = data.epoch + 1
        cooldown = backoff_cooldown_ms(reason, streak, opts[:retry_after_ms], data)
        now = DateTime.utc_now()
        next_probe_at = DateTime.add(now, cooldown, :millisecond)

        Phoenix.PubSub.broadcast(
          @pubsub,
          @alerts_topic,
          {:breaker_opened, data.credential_id, reason}
        )

        notify_breaker_opened(data.credential_id, reason)

        new_data = %{
          data
          | failures: failures,
            open_streak: streak,
            epoch: epoch,
            last_reason: reason,
            last_error_message: error_message,
            probe_in_flight?: false,
            probe_ref: nil,
            probe_owner: nil,
            opened_at: now,
            next_probe_at: next_probe_at
        }

        sync_ets(:open, new_data)
        {:next_state, :open, new_data, {:state_timeout, cooldown, :probe}}
      else
        {:keep_state,
         %{data | failures: failures, last_reason: reason, last_error_message: error_message}}
      end
    else
      {:keep_state, data}
    end
  end

  defp reopen_from_half_open(reason, error_message, opts, data) do
    clean_data = demonitor_probe(data)
    streak = clean_data.open_streak + 1
    epoch = clean_data.epoch + 1
    cooldown = backoff_cooldown_ms(reason, streak, opts[:retry_after_ms], clean_data)
    now = DateTime.utc_now()
    next_probe_at = DateTime.add(now, cooldown, :millisecond)

    new_data = %{
      clean_data
      | failures: clean_data.failures + 1,
        open_streak: streak,
        epoch: epoch,
        last_reason: reason,
        last_error_message: error_message || clean_data.last_error_message,
        opened_at: clean_data.opened_at || now,
        next_probe_at: next_probe_at
    }

    sync_ets(:open, new_data)
    {:next_state, :open, new_data, {:state_timeout, cooldown, :probe}}
  end

  defp acquire_probe_lease(data, caller_pid) do
    ref = Process.monitor(caller_pid)
    %{data | probe_in_flight?: true, probe_ref: ref, probe_owner: caller_pid}
  end

  defp demonitor_probe(%{probe_ref: nil} = data) do
    %{data | probe_in_flight?: false, probe_owner: nil}
  end

  defp demonitor_probe(%{probe_ref: ref} = data) do
    Process.demonitor(ref, [:flush])
    %{data | probe_in_flight?: false, probe_ref: nil, probe_owner: nil}
  end

  defp reset_data(data) do
    %{
      data
      | failures: 0,
        open_streak: 0,
        last_reason: nil,
        last_error_message: nil,
        probe_in_flight?: false,
        probe_ref: nil,
        probe_owner: nil,
        opened_at: nil,
        next_probe_at: nil
    }
  end

  defp stale_epoch?(opts, data) do
    case Keyword.get(opts, :epoch) do
      epoch when is_integer(epoch) -> epoch < data.epoch
      _ -> false
    end
  end

  defp build_details(state, data) do
    %{
      state: state,
      failures: data.failures,
      open_streak: data.open_streak,
      probe_in_flight?: data.probe_in_flight?,
      last_reason: data.last_reason,
      last_error_message: data.last_error_message,
      opened_at: if(state == :closed, do: nil, else: data.opened_at),
      next_probe_at: if(state == :open, do: data.next_probe_at, else: nil)
    }
  end

  defp broadcast_half_open(credential_id) do
    Phoenix.PubSub.broadcast(@pubsub, @alerts_topic, {:breaker_half_open, credential_id})
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp broadcast_closed(credential_id) do
    Phoenix.PubSub.broadcast(@pubsub, @alerts_topic, {:breaker_closed, credential_id})
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp notify_breaker_opened(credential_id, reason) do
    Tokengate.Notifications.emit(:breaker_opened, %{
      entity_type: "credential",
      entity_id: credential_id,
      reason: to_string(reason)
    })
  rescue
    error ->
      Logger.warning("circuit breaker: breaker_opened notification failed: #{inspect(error)}")
  catch
    :exit, exit_reason ->
      Logger.warning(
        "circuit breaker: breaker_opened notification exited: #{inspect(exit_reason)}"
      )
  end

  defp cooldown_for(reason, data) do
    if reason in @short_cooldown_reasons do
      data.rate_limit_cooldown_ms
    else
      data.cooldown_ms
    end
  end

  defp backoff_cooldown_ms(reason, streak, retry_after_ms, data) do
    base = cooldown_for(reason, data)
    cap = max(data.max_cooldown_ms, base)

    raw =
      case retry_after_ms do
        ms when is_integer(ms) and ms > 0 ->
          min(ms, cap)

        _ ->
          shift = min(max(streak - 1, 0), 4)
          min(base * Bitwise.bsl(1, shift), cap)
      end

    apply_jitter(raw)
  end

  # Apply +-15% jitter only for real-world cooldowns (>= 500ms) so fast unit
  # tests with 20ms/50ms deterministic windows stay flake-free.
  defp apply_jitter(ms) when ms < 500, do: ms

  defp apply_jitter(ms) do
    spread = max(div(ms * 15, 100), 1)
    delta = :rand.uniform(spread * 2 + 1) - spread - 1
    max(ms + delta, 500)
  end

  defp sync_ets(state, data) do
    :ets.insert(
      @ets_table,
      {data.credential_id, state, data.probe_in_flight?, data.epoch}
    )

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp delete_ets(credential_id) do
    :ets.delete(@ets_table, credential_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp config(key, default) do
    :tokengate
    |> Application.get_env(:circuit_breaker, [])
    |> Keyword.get(key, default)
  end
end
