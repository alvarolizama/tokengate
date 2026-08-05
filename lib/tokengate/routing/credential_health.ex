defmodule Tokengate.Routing.CredentialHealth do
  @moduledoc """
  ETS-backed soft health tracking per provider credential.

  The circuit breaker answers the hard question ("is it alive?") — this
  module answers the soft one ("is it fast enough to be a primary?"). A
  credential that answers successfully but slower than `slow_threshold_ms`
  is marked *degraded*; while degraded it sinks to the bottom of its
  routing tier so subscriptions that are merely slow stop hogging traffic
  without being taken out of rotation entirely. The next fast success (or
  the natural `slow_penalty_ms` expiry) clears the mark and the credential
  returns to its normal priority.

  ## Table

    * `:tokengate_credential_health` — `credential_id => degraded_since_ms`
      (monotonic). Only degraded credentials appear; healthy ones are absent.

  ## Public API

    * `mark_slow/1`    — record a slow success (async cast).
    * `mark_healthy/1` — clear the degraded mark after a fast success (async cast).
    * `degraded?/1`    — direct ETS read (no GenServer round-trip), with lazy expiry.
    * `clear_all/0`    — drop every mark (admin/test use).

  Config (see `config :tokengate, :routing`):

    * `:slow_threshold_ms` — latency above which a success counts as slow.
    * `:slow_penalty_ms`   — how long a credential stays degraded.
  """

  use GenServer

  @table :tokengate_credential_health
  @sweep_interval_ms 60_000

  ## Public API --------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Marks `credential_id` as degraded from now on (async)."
  @spec mark_slow(binary()) :: :ok
  def mark_slow(credential_id) when is_binary(credential_id) do
    GenServer.cast(__MODULE__, {:mark_slow, credential_id})
  end

  @doc "Clears the degraded mark for `credential_id` (async)."
  @spec mark_healthy(binary()) :: :ok
  def mark_healthy(credential_id) when is_binary(credential_id) do
    GenServer.cast(__MODULE__, {:mark_healthy, credential_id})
  end

  @doc """
  Returns `true` when `credential_id` is currently degraded.

  Reads directly from the public ETS table — no GenServer round-trip.
  Entries older than `slow_penalty_ms` are treated as expired and deleted
  lazily on read. Returns `false` when the tracker is not running.
  """
  @spec degraded?(binary()) :: boolean()
  def degraded?(credential_id) when is_binary(credential_id) do
    try do
      :ets.lookup(@table, credential_id)
    rescue
      ArgumentError -> false
    else
      [{^credential_id, degraded_since}] ->
        if expired?(degraded_since) do
          GenServer.cast(__MODULE__, {:mark_healthy, credential_id})
          false
        else
          true
        end

      [] ->
        false
    end
  end

  @doc "Drops every degraded mark. Useful in tests and admin resets."
  @spec clear_all() :: :ok
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  @doc """
  Records the outcome of a successful request by latency: slow successes
  degrade, fast successes heal. Centralizes the threshold read so callers
  don't repeat the config lookup.
  """
  @spec record_success(binary(), non_neg_integer()) :: :ok
  def record_success(credential_id, latency_ms) when is_binary(credential_id) do
    if latency_ms > slow_threshold_ms() do
      mark_slow(credential_id)
    else
      mark_healthy(credential_id)
    end
  end

  @doc false
  def slow_threshold_ms do
    :tokengate
    |> Application.get_env(:routing, [])
    |> Keyword.get(:slow_threshold_ms, 30_000)
  end

  @doc false
  def slow_penalty_ms do
    :tokengate
    |> Application.get_env(:routing, [])
    |> Keyword.get(:slow_penalty_ms, 120_000)
  end

  ## GenServer callbacks ------------------------------------------------------

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true
      ])

    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:mark_slow, credential_id}, state) do
    :ets.insert(@table, {credential_id, System.monotonic_time(:millisecond)})
    {:noreply, state}
  end

  def handle_cast({:mark_healthy, credential_id}, state) do
    :ets.delete(@table, credential_id)
    {:noreply, state}
  end

  @impl true
  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    purge_expired()
    schedule_sweep()
    {:noreply, state}
  end

  ## Internal helpers ----------------------------------------------------------

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp purge_expired do
    now = System.monotonic_time(:millisecond)
    penalty = slow_penalty_ms()

    :ets.foldl(
      fn {credential_id, degraded_since}, acc ->
        if now - degraded_since > penalty do
          :ets.delete(@table, credential_id)
        end

        acc
      end,
      :ok,
      @table
    )
  end

  defp expired?(degraded_since) do
    System.monotonic_time(:millisecond) - degraded_since > slow_penalty_ms()
  end
end
