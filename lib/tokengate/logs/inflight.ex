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
          client_agent: String.t() | nil,
          team_id: String.t() | nil,
          streaming: boolean(),
          think: boolean(),
          effort: String.t() | nil,
          provider_name: String.t() | nil,
          api_key_prefix: String.t() | nil,
          credential_name: String.t() | nil,
          provider_key_suffix: String.t() | nil,
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
      client_agent: Map.get(attrs, :client_agent),
      team_id: Map.get(attrs, :team_id),
      streaming: Map.get(attrs, :streaming, false),
      think: Map.get(attrs, :think, false),
      effort: Map.get(attrs, :effort),
      provider_name: Map.get(attrs, :provider_name),
      api_key_prefix: Map.get(attrs, :api_key_prefix),
      credential_name: Map.get(attrs, :credential_name),
      provider_key_suffix: Map.get(attrs, :provider_key_suffix),
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
    |> :ets.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$2", :"$3"}}]}])
    |> Enum.map(fn {entry, _mono} -> entry end)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  @doc """
  Number of currently in-flight requests — the count the dashboard's
  "En vuelo" badge and the logs page render. Equal to `length(list/0)`
  but reads the table directly so it stays O(n) on the entry count
  without building the full entries.
  """
  @spec count() :: non_neg_integer()
  def count do
    ensure_table()
    :ets.info(@table, :size) || 0
  end

  @doc """
  In-flight count per model — groups current entries by `model_requested`.
  Returns a list of maps sorted by count descending, capped at `limit`
  entries. Each map has:

    * `:model` — the model_requested string
    * `:count` — number of in-flight requests
    * `:credential_name` — credential alias (if available)
    * `:provider_key_suffix` — last 4 chars of the provider API key
  """
  @spec count_by_model(non_neg_integer()) :: [
          %{
            model: String.t(),
            count: non_neg_integer(),
            credential_name: String.t() | nil,
            provider_key_suffix: String.t() | nil
          }
        ]
  def count_by_model(limit \\ 5) do
    ensure_table()

    # Project only the 3 fields we need instead of copying full 20-key maps.
    # The match spec returns a 3-tuple {model, credential_name, key_suffix}.
    @table
    |> :ets.select([
      {{:"$1", %{model_requested: :"$2", credential_name: :"$3", provider_key_suffix: :"$4"},
        :"$5"}, [], [{{:"$2", :"$3", :"$4"}}]}
    ])
    |> Enum.reject(fn {model, _cred, _suffix} -> is_nil(model) end)
    |> Enum.group_by(fn {model, _cred, _suffix} -> model end)
    |> Enum.map(fn {model, group} ->
      {_model, credential_name, provider_key_suffix} = List.first(group)

      %{
        model: model,
        count: length(group),
        credential_name: credential_name,
        provider_key_suffix: provider_key_suffix
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
    |> Enum.take(limit)
  end

  @doc """
  In-flight count per user — groups current entries by `user_email`.
  Returns a list of maps sorted by count descending, capped at `limit`
  entries. Each map has:

    * `:user` — the user email (falls back to "desconocido" when nil)
    * `:count` — number of in-flight requests
    * `:credential_name` — credential alias (if available)
    * `:provider_key_suffix` — last 4 chars of the provider API key
  """
  @spec count_by_user(non_neg_integer()) :: [
          %{
            user: String.t(),
            count: non_neg_integer(),
            credential_name: String.t() | nil,
            provider_key_suffix: String.t() | nil
          }
        ]
  def count_by_user(limit \\ 5) do
    ensure_table()

    # Same projection trick: 3-tuples instead of full entries. nil user_email
    # groups under "desconocido" (the UI label for service/system requests).
    @table
    |> :ets.select([
      {{:"$1", %{user_email: :"$2", credential_name: :"$3", provider_key_suffix: :"$4"}, :"$5"},
       [], [{{:"$2", :"$3", :"$4"}}]}
    ])
    |> Enum.group_by(fn {user_email, _cred, _suffix} -> user_email || "desconocido" end)
    |> Enum.map(fn {user, group} ->
      {_email, credential_name, provider_key_suffix} = List.first(group)

      %{
        user: user,
        count: length(group),
        credential_name: credential_name,
        provider_key_suffix: provider_key_suffix
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
    |> Enum.take(limit)
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
