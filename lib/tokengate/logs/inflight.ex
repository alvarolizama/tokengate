defmodule Tokengate.Logs.Inflight do
  @moduledoc """
  ETS-backed registry of in-flight (pending) proxy requests.

  Powers the "Pending" rows in the Logs UI: the proxy registers a request
  here right before calling the provider and completes it when the
  response finishes (or fails), so connected LiveViews see the request
  live while it streams.

  ## Concurrency model

  Same pattern as `Tokengate.Metrics.Collector`: the GenServer only owns
  the public named ETS table `:tokengate_inflight_requests` and runs the
  TTL sweep. `start_request/1`, `finish_request/1` and `list/0` run in the
  caller's process directly against the table — no GenServer bottleneck
  on the hot path.

  ## TTL sweep

  Entries older than `ttl_ms/0` are swept every minute and broadcast as
  done, so a crashed request never leaves a phantom "Pending" row.

  ## PubSub

  Topic `logs:inflight`:

    * `{:inflight_started, entry}` — on `start_request/1`
    * `{:inflight_done, id}` — on `finish_request/1` or TTL sweep
  """

  use GenServer

  @table :tokengate_inflight_requests
  @pubsub Tokengate.PubSub
  @topic "logs:inflight"
  @ttl_ms 10 * 60 * 1_000
  @sweep_interval_ms 60_000

  @typedoc "An in-flight request entry."
  @type entry :: %{
          id: String.t(),
          team_member_id: term(),
          user_email: String.t() | nil,
          team_name: String.t() | nil,
          model_requested: String.t() | nil,
          agent_type: String.t() | nil,
          streaming: boolean(),
          think: boolean(),
          effort: String.t() | nil,
          started_at: DateTime.t()
        }

  ## Public API (caller process) -----------------------------------------

  @doc "The PubSub topic for in-flight events."
  def topic, do: @topic

  @doc "Sweep TTL in milliseconds (exposed for tests/UI hints)."
  def ttl_ms, do: @ttl_ms

  @doc """
  Registers an in-flight request. Accepts an optional `:id` (generated
  otherwise) and returns the full entry. Broadcasts `:inflight_started`.
  """
  @spec start_request(map()) :: entry()
  def start_request(attrs) do
    ensure_table()

    entry = %{
      id: Map.get(attrs, :id) || Ecto.UUID.generate(),
      team_member_id: Map.get(attrs, :team_member_id),
      user_email: Map.get(attrs, :user_email),
      team_name: Map.get(attrs, :team_name),
      model_requested: Map.get(attrs, :model_requested),
      agent_type: Map.get(attrs, :agent_type),
      streaming: Map.get(attrs, :streaming, false),
      think: Map.get(attrs, :think, false),
      effort: Map.get(attrs, :effort),
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    :ets.insert(@table, {entry.id, entry, mono_now()})
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:inflight_started, entry})

    entry
  end

  @doc """
  Completes an in-flight request. Idempotent: unknown ids are a noop.
  Broadcasts `:inflight_done` only when the entry existed.
  """
  @spec finish_request(String.t()) :: :ok
  def finish_request(id) do
    ensure_table()

    case :ets.take(@table, id) do
      [] ->
        :ok

      [_] ->
        Phoenix.PubSub.broadcast(@pubsub, @topic, {:inflight_done, id})
        :ok
    end
  end

  @doc "All in-flight entries, most recent first."
  @spec list() :: [entry()]
  def list do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, entry, _mono} -> entry end)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  @doc false
  # Test helper: ages an entry past the TTL so the sweep picks it up.
  def backdate_for_test(id, ms) do
    ensure_table()

    case :ets.lookup(@table, id) do
      [{^id, entry, mono}] ->
        :ets.insert(@table, {id, entry, mono - ms})
        :ok

      [] ->
        :ok
    end
  end

  ## GenServer (table owner + sweeper) ------------------------------------

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ensure_table()
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = mono_now() - @ttl_ms

    @table
    |> :ets.select([{{:"$1", :"$2", :"$3"}, [{:<, :"$3", cutoff}], [:"$1"]}])
    |> Enum.each(fn id -> finish_request(id) end)

    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals -------------------------------------------------------------

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

      _tid ->
        @table
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp mono_now, do: System.monotonic_time(:millisecond)
end
