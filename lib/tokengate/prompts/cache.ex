defmodule Tokengate.Prompts.Cache do
  @moduledoc """
  Volatile ETS cache of captured prompts for the Prompt Inspector LiveView.

  ## Concurrency model

  Same pattern as `Tokengate.Logs.Inflight` and `Tokengate.Accounts.ApiKeyCache`:
  the GenServer only owns the public named ETS table and runs the TTL sweep.
  `capture/1`, `list/0` and `delete/1` run in the caller's process directly
  against the table — no GenServer bottleneck on the hot path.

  ## TTL sweep

  Entries older than `@ttl_ms` (1h) are swept every minute.
  When entries exceed `@max_entries` (2000), oldest are purged.
  If memory usage exceeds 100 MB, aggressive purge + warning log.

  ## Degradation graceful

  If the ETS table doesn't exist (hot code reload, GenServer restart), all
  operations degrade gracefully: `capture/1` returns the entry without
  inserting; `list/0` returns `[]`. The cache is an optimization, never
  a hard dependency — the proxy hot path must keep working without it.

  ## PubSub

  Topic `prompts:new`:

    * `{:prompt_captured, entry}` — on `capture/1`
  """

  use GenServer

  require Logger

  @table :tokengate_prompts_cache
  @pubsub Tokengate.PubSub
  @topic "prompts:new"
  @ttl_ms 1 * 60 * 60 * 1_000
  @sweep_ms 60_000
  @max_entries 2_000

  # 100 MB in words (Erlang word size on 64-bit = 8 bytes)
  @memory_limit_words (100 * 1024 * 1024) |> div(8)

  @typedoc "A captured prompt entry."
  @type entry :: %{
          id: String.t(),
          team_member_id: term(),
          subject_type: String.t() | nil,
          user_email: String.t() | nil,
          service_name: String.t() | nil,
          team_name: String.t() | nil,
          team_id: String.t() | nil,
          model_requested: String.t() | nil,
          agent_type: String.t() | nil,
          client_agent: String.t() | nil,
          messages: [map()],
          preview: String.t(),
          started_at: DateTime.t()
        }

  ## Public API (caller process) -----------------------------------------

  @doc "The PubSub topic for prompt-captured events."
  def topic, do: @topic

  @doc "TTL in milliseconds (exposed for tests)."
  def ttl_ms, do: @ttl_ms

  @doc "Max entries before aggressive purge."
  def max_entries, do: @max_entries

  @doc """
  Captures a prompt entry. Returns the entry with `id` (UUID),
  `started_at`, and `preview` (truncated first-message content to 200 chars).
  Broadcasts `{:prompt_captured, entry}` on the prompts:new topic.
  Degrades gracefully: if the table doesn't exist, returns entry without inserting.
  """
  @spec capture(map()) :: entry()
  def capture(attrs) do
    messages = Map.get(attrs, :messages) || Map.get(attrs, "messages") || []

    # Preview: first user message content, truncated to 200 chars
    preview =
      messages
      |> Enum.find_value("", fn
        %{"content" => content} when is_binary(content) -> content
        _ -> nil
      end)
      |> String.slice(0, 200)

    entry = %{
      id: Map.get(attrs, :id) || Ecto.UUID.generate(),
      team_member_id: Map.get(attrs, :team_member_id),
      subject_type: Map.get(attrs, :subject_type),
      user_email: Map.get(attrs, :user_email),
      service_name: Map.get(attrs, :service_name),
      team_name: Map.get(attrs, :team_name),
      team_id: Map.get(attrs, :team_id),
      model_requested: Map.get(attrs, :model_requested),
      agent_type: Map.get(attrs, :agent_type),
      client_agent: Map.get(attrs, :client_agent),
      messages: messages,
      preview: preview,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    safe_insert(entry)
    entry
  end

  @doc "All captured prompt entries, most recent first."
  @spec list() :: [entry()]
  def list do
    if :ets.whereis(@table) == :undefined do
      []
    else
      @table
      |> :ets.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$2", :"$3"}}]}])
      |> Enum.map(fn {entry, _mono} -> entry end)
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
    end
  rescue
    ArgumentError -> []
  end

  @doc "Delete a single entry by id. Idempotent."
  @spec delete(String.t()) :: :ok
  def delete(id) do
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table, id)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  # Test helper: ages an entry past the TTL so the sweep picks it up.
  def backdate_for_test(id, ms) do
    if :ets.whereis(@table) != :undefined do
      case :ets.lookup(@table, id) do
        [{^id, entry, mono}] ->
          :ets.insert(@table, {id, entry, mono - ms})
          :ok

        [] ->
          :ok
      end
    else
      :ok
    end
  rescue
    ArgumentError -> :ok
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
    {:ok, %{warnings: []}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired()
    sweep_if_over_cap()
    sweep_if_over_memory()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals -------------------------------------------------------------

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          write_concurrency: true,
          read_concurrency: true
        ])

      _tid ->
        @table
    end
  end

  # Insert with graceful degradation: if table is gone, return without crash.
  # This mirrors ApiKeyCache.fetch/2 — cache is optimization, never dependency.
  defp safe_insert(entry) do
    if :ets.whereis(@table) == :undefined do
      :ok
    else
      try do
        :ets.insert(@table, {entry.id, entry, mono_now()})
        Phoenix.PubSub.broadcast(@pubsub, @topic, {:prompt_captured, entry})
      rescue
        # Table raced away between whereis and insert (owner died / restart).
        # Degrade silently — proxy keeps working, prompt not cached this time.
        ArgumentError -> :ok
      end
    end
  end

  defp sweep_expired do
    cutoff = mono_now() - @ttl_ms

    if :ets.whereis(@table) != :undefined do
      @table
      |> :ets.select([{{:"$1", :"$2", :"$3"}, [{:<, :"$3", cutoff}], [:"$1"]}])
      |> Enum.each(fn id -> :ets.delete(@table, id) end)
    end
  rescue
    ArgumentError -> :ok
  end

  # When entries exceed @max_entries, delete the oldest (by mono timestamp).
  defp sweep_if_over_cap do
    if :ets.whereis(@table) != :undefined do
      count = :ets.info(@table, :size) || 0

      if count > @max_entries do
        # Select all ids with their mono timestamps, sort oldest first, delete excess
        excess =
          @table
          |> :ets.select([{{:"$1", :_, :"$3"}, [], [{{:"$1", :"$3"}}]}])
          |> Enum.sort_by(fn {_id, mono} -> mono end)
          |> Enum.take(count - @max_entries)

        Enum.each(excess, fn {id, _} -> :ets.delete(@table, id) end)
      end
    end
  rescue
    ArgumentError -> :ok
  end

  # If memory exceeds 100 MB, aggressively purge oldest 50% + log warning.
  # This is a safety valve — the sweep + cap should prevent this from happening.
  defp sweep_if_over_memory do
    if :ets.whereis(@table) != :undefined do
      mem_words = :ets.info(@table, :memory) || 0

      if mem_words > @memory_limit_words do
        Logger.warning(
          "[Prompts.Cache] Memory limit exceeded: #{mem_words} words > #{@memory_limit_words}. " <>
            "Purging oldest 50% of entries."
        )

        entries =
          @table
          |> :ets.select([{{:"$1", :_, :"$3"}, [], [{{:"$1", :"$3"}}]}])
          |> Enum.sort_by(fn {_id, mono} -> mono end)

        # Purge oldest 50%
        purge_count = div(length(entries), 2)

        entries
        |> Enum.take(purge_count)
        |> Enum.each(fn {id, _} -> :ets.delete(@table, id) end)
      end
    end
  rescue
    ArgumentError -> :ok
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)

  defp mono_now, do: System.monotonic_time(:millisecond)
end
