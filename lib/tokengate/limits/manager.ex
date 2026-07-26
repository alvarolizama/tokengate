defmodule Tokengate.Limits.Manager do
  @moduledoc """
  ETS-backed sliding-window RPM limiter and in-flight concurrency gate.

  Keyed by `api_key_id` (or any opaque string). The caller resolves the
  concrete limits for a team member via `Tokengate.Accounts.effective_limits/1`
  and hands them here; this module is a pure rate/concurrency gate.

  ## Tables

  - `:tokengate_rpm_buckets` — `{api_key_id, minute_bucket}` => counter.
    Two-bucket weighted sliding window for RPM.
  - `:tokengate_inflight` — `api_key_id` => in-flight request count.

  ## Choices

  - When `acquire/2` checks rate first and then concurrency, a concurrency
    failure after a successful rate check is intentional: rate tokens are
    cheap (a single counter increment) and not worth rolling back. The
    caller will simply retry on the next request.
  """

  use GenServer

  @rpm_table :tokengate_rpm_buckets
  @inflight_table :tokengate_inflight
  @sweep_interval_ms 60_000
  @bucket_retention_minutes 2

  # --- Public API ---

  @doc """
  Check RPM limit for `api_key_id` against `rpm_limit`.

  Uses a weighted two-bucket sliding window: the current minute bucket and
  the previous minute bucket. The previous bucket's count is weighted by
  the fraction of that minute that still "bleeds" into the current window.

  Returns `:ok` if the request may proceed (and increments the current
  bucket), or `{:error, :rate_limited, retry_after_ms}` if the weighted
  count has already reached `rpm_limit`. `nil` limit means unlimited.
  """
  @spec check_rate(api_key_id :: String.t() | term(), rpm_limit :: pos_integer() | nil) ::
          :ok | {:error, :rate_limited, non_neg_integer()}
  def check_rate(api_key_id, rpm_limit)

  def check_rate(_api_key_id, nil), do: :ok

  def check_rate(api_key_id, rpm_limit) when is_integer(rpm_limit) do
    now = System.system_time(:second)
    current_bucket = div(now, 60)
    key = {api_key_id, current_bucket}

    prev_count = read_bucket(api_key_id, current_bucket - 1)
    cur_count = read_bucket(api_key_id, current_bucket)

    elapsed = rem(now, 60)
    weighted_prev = div(prev_count * (60 - elapsed), 60)
    weighted_count = weighted_prev + cur_count

    if weighted_count < rpm_limit do
      :ets.update_counter(@rpm_table, key, 1, {key, 0})
      :ok
    else
      {:error, :rate_limited, retry_after_ms(now)}
    end
  end

  @doc """
  Acquire a concurrency slot for `api_key_id`.

  Returns `:ok` if a slot was acquired, or `{:error, :concurrency_exceeded}`
  if the in-flight count is already at `limit`. `nil` limit means unlimited
  (the count is still tracked for observability).

  Race-free via optimistic increment-then-check: we increment first and, if
  the new value exceeds the limit, decrement back.
  """
  @spec acquire_concurrency(api_key_id :: String.t() | term(), limit :: pos_integer() | nil) ::
          :ok | {:error, :concurrency_exceeded}
  def acquire_concurrency(api_key_id, limit)

  def acquire_concurrency(api_key_id, nil) do
    key = api_key_id
    :ets.update_counter(@inflight_table, key, {2, 1}, {key, 0})
    :ok
  end

  def acquire_concurrency(api_key_id, limit) when is_integer(limit) do
    key = api_key_id
    new_value = :ets.update_counter(@inflight_table, key, {2, 1}, {key, 0})

    if new_value <= limit do
      :ok
    else
      # Over limit — roll back the increment. Guard against negative.
      :ets.update_counter(@inflight_table, key, {2, -1})
      {:error, :concurrency_exceeded}
    end
  end

  @doc """
  Release a previously acquired concurrency slot.

  Decrements the in-flight counter, flooring at 0. Idempotent: calling
  release when the count is already 0 leaves it at 0.
  """
  @spec release_concurrency(api_key_id :: String.t() | term()) :: :ok
  def release_concurrency(api_key_id) do
    key = api_key_id

    # Decrement only if the current count is positive; never go negative.
    # Use a conditional counter update so the read-then-decrement is atomic
    # from ETS' perspective: if the value is > 0 it is decremented in the
    # same atomic op; otherwise nothing happens.
    :ets.update_counter(@inflight_table, key, {2, -1, 0, 0}, {key, 0})

    :ok
  end

  @doc """
  Current in-flight request count for `api_key_id`.
  """
  @spec current_concurrency(api_key_id :: String.t() | term()) :: non_neg_integer()
  def current_concurrency(api_key_id) do
    read_concurrency(api_key_id)
  end

  @doc """
  Combined acquire: check rate first, then concurrency.

  If the rate check succeeds but concurrency fails, the rate token is
  *not* rolled back — rate tokens are cheap (a single counter increment)
  and the caller will retry shortly. Documented intentionally.
  """
  @spec acquire(
          api_key_id :: String.t() | term(),
          limits :: %{rpm_limit: pos_integer() | nil, concurrency_limit: pos_integer() | nil}
        ) :: :ok | {:error, :rate_limited, non_neg_integer()} | {:error, :concurrency_exceeded}
  def acquire(api_key_id, %{rpm_limit: rpm, concurrency_limit: conc}) do
    case check_rate(api_key_id, rpm) do
      :ok ->
        acquire_concurrency(api_key_id, conc)

      {:error, :rate_limited, _ms} = err ->
        err
    end
  end

  @doc """
  Release a concurrency slot acquired via `acquire/2`.
  """
  @spec release(api_key_id :: String.t() | term()) :: :ok
  def release(api_key_id) do
    release_concurrency(api_key_id)
  end

  # --- GenServer ---

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ensure_rpm_table()
    ensure_inflight_table()
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_old_buckets()
    schedule_sweep()
    {:noreply, state}
  end

  # --- Internals ---

  defp ensure_rpm_table do
    if :ets.whereis(@rpm_table) == :undefined do
      :ets.new(@rpm_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end
  end

  defp ensure_inflight_table do
    if :ets.whereis(@inflight_table) == :undefined do
      :ets.new(@inflight_table, [
        :set,
        :public,
        :named_table,
        write_concurrency: true
      ])
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp sweep_old_buckets do
    now = System.system_time(:second)
    current_bucket = div(now, 60)
    cutoff = current_bucket - @bucket_retention_minutes

    # ETS does not support range deletes; select and delete individually.
    # Use a match spec that captures keys with bucket < cutoff.
    match_spec = [
      {{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}
    ]

    :ets.select_delete(@rpm_table, match_spec)
  end

  defp read_bucket(api_key_id, bucket) do
    :ets.lookup_element(@rpm_table, {api_key_id, bucket}, 2, 0)
  end

  defp read_concurrency(api_key_id) do
    :ets.lookup_element(@inflight_table, api_key_id, 2, 0)
  end

  defp retry_after_ms(now) do
    elapsed = rem(now, 60)
    ms_remaining_in_minute = (60 - elapsed) * 1000

    # The weighted count drops as the previous bucket's contribution decays
    # and the current minute rolls over. The earliest moment the count can
    # fall below the limit is the next minute boundary. Approximate with the
    # ms remaining in the current minute, floored at 1000.
    max(ms_remaining_in_minute, 1000)
  end
end
