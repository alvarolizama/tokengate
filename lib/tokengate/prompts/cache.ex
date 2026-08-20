defmodule Tokengate.Prompts.Cache do
  @moduledoc """
  Volatile ETS cache of captured prompts for the Prompt Inspector LiveView.

  ## Concurrency model

  Same pattern as `Tokengate.Logs.Inflight` and `Tokengate.Accounts.ApiKeyCache`:
  the GenServer only owns the public named ETS tables and runs the TTL sweep.
  `capture/1`, `list_recent/2`, `get/1`, `list/0` and `delete/1` run in the
  caller's process directly against the tables — no GenServer bottleneck on
  the hot path.

  ## Two tables: rows (light) + full entries

  * `:tokengate_prompts_cache` — full entries, including the complete
    `messages` payload. Read only by `get/1`, when the Inspector modal opens.
  * `:tokengate_prompts_rows` — the same entries WITHOUT `messages`, plus a
    `last_preview` field. Read by `list_recent/2` (table + filters) and
    broadcast over PubSub on capture.

  Keeping `messages` out of the list/broadcast path means the LiveView never
  materializes full prompt bodies in memory just to render the table, and the
  WebSocket only ever carries lightweight rows. The full entry is fetched by
  id on demand (`get/1`).

  ## TTL sweep

  Entries older than `@ttl_ms` (1h) are swept every minute.
  When entries exceed `@max_entries` (2000), oldest are purged.
  If memory usage exceeds 100 MB, aggressive purge + warning log.

  ## Degradation graceful

  If the ETS tables don't exist (hot code reload, GenServer restart), all
  operations degrade gracefully: `capture/1` returns the entry without
  inserting; `list_recent/2` and `list/0` return `[]`; `get/1` returns `nil`.
  The cache is an optimization, never a hard dependency — the proxy hot path
  must keep working without it.

  ## PubSub

  Topic `prompts:new`:

    * `{:prompt_captured, row}` — on `capture/1` (lightweight row, no messages)
  """

  use GenServer

  require Logger

  @table :tokengate_prompts_cache
  @rows_table :tokengate_prompts_rows
  @pubsub Tokengate.PubSub
  @topic "prompts:new"
  @ttl_ms 1 * 60 * 60 * 1_000
  @sweep_ms 60_000
  @max_entries 2_000

  # 100 MB in words (Erlang word size on 64-bit = 8 bytes)
  @memory_limit_words (100 * 1024 * 1024) |> div(8)

  @typedoc "A captured prompt entry (full, includes `messages`)."
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
          last_preview: String.t(),
          started_at: DateTime.t()
        }

  @typedoc "A lightweight row (no `messages`), used for the table and PubSub."
  @type row :: map()

  ## Public API (caller process) -----------------------------------------

  @doc "The PubSub topic for prompt-captured events."
  def topic, do: @topic

  @doc "TTL in milliseconds (exposed for tests)."
  def ttl_ms, do: @ttl_ms

  @doc "Max entries before aggressive purge."
  def max_entries, do: @max_entries

  @doc """
  Captures a prompt entry. Returns the entry with `id` (UUID),
  `started_at`, `preview` (first-message content, 200 chars) and
  `last_preview` (last-message content, 200 chars).
  Stores the full entry plus a lightweight row, and broadcasts
  `{:prompt_captured, row}` on the prompts:new topic.
  Degrades gracefully: if the table doesn't exist, returns entry without inserting.
  """
  @spec capture(map()) :: entry()
  def capture(attrs) do
    messages = Map.get(attrs, :messages) || Map.get(attrs, "messages") || []

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
      preview: first_message_preview(messages),
      last_preview: last_message_preview(messages),
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    safe_insert(entry)
    entry
  end

  @doc """
  The most recent `limit` rows (lightweight, no `messages`), newest first.

  `filters` is an optional map with `user_email` / `subject_type` / `model`
  keys; empty values match everything. Filtering happens in memory over the
  lightweight rows, so it never touches full prompt bodies.
  """
  @spec list_recent(pos_integer(), map() | nil) :: [row()]
  def list_recent(limit, filters \\ nil) do
    if :ets.whereis(@rows_table) == :undefined do
      []
    else
      rows =
        @rows_table
        |> :ets.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$2", :"$3"}}]}])
        |> Enum.map(fn {row, _mono} -> row end)

      rows =
        if filters, do: Enum.filter(rows, &matches_filters?(&1, filters)), else: rows

      rows
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> Enum.take(limit)
    end
  rescue
    ArgumentError -> []
  end

  @doc "True when `row` matches the given filter map (empty values match everything)."
  @spec matches_filters?(row(), map() | nil) :: boolean()
  def matches_filters?(_row, nil), do: true

  def matches_filters?(row, filters) do
    email_match?(row.user_email, Map.get(filters, "user_email")) and
      subject_type_match?(row.subject_type, Map.get(filters, "subject_type")) and
      model_match?(row.model_requested, Map.get(filters, "model"))
  end

  @doc "Fetch a single full entry by id (includes `messages`). Returns nil if missing."
  @spec get(String.t()) :: entry() | nil
  def get(id) do
    if :ets.whereis(@table) == :undefined do
      nil
    else
      case :ets.lookup(@table, id) do
        [{^id, entry, _mono}] -> entry
        [] -> nil
      end
    end
  rescue
    ArgumentError -> nil
  end

  @doc "All captured prompt entries (full, with messages), most recent first."
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

  @doc "Delete a single entry by id (from both tables). Idempotent."
  @spec delete(String.t()) :: :ok
  def delete(id) do
    if :ets.whereis(@table) != :undefined do
      purge(id)
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
    ensure_named_table(@table)
    ensure_named_table(@rows_table)
  end

  defp ensure_named_table(name) do
    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, [
          :named_table,
          :public,
          :set,
          write_concurrency: true,
          read_concurrency: true
        ])

      _tid ->
        name
    end
  end

  # Insert with graceful degradation: if any table is gone, return without
  # crashing. This mirrors ApiKeyCache.fetch/2 — cache is optimization, never
  # dependency. Both tables must exist so we never end up with a full entry
  # but no row (or vice versa) after a partial hot reload.
  defp safe_insert(entry) do
    if :ets.whereis(@table) == :undefined or :ets.whereis(@rows_table) == :undefined do
      :ok
    else
      try do
        row = row_for(entry)
        :ets.insert(@table, {entry.id, entry, mono_now()})
        :ets.insert(@rows_table, {entry.id, row, mono_now()})
        # Broadcast the lightweight row (no messages) so LiveViews never
        # receive full prompt bodies over PubSub / the WebSocket.
        Phoenix.PubSub.broadcast(@pubsub, @topic, {:prompt_captured, row})
      rescue
        # Table raced away between whereis and insert (owner died / restart).
        # Degrade silently — proxy keeps working, prompt not cached this time.
        ArgumentError -> :ok
      end
    end
  end

  defp row_for(entry) do
    Map.delete(entry, :messages)
  end

  defp sweep_expired do
    cutoff = mono_now() - @ttl_ms

    if :ets.whereis(@table) != :undefined do
      @table
      |> :ets.select([{{:"$1", :"$2", :"$3"}, [{:<, :"$3", cutoff}], [:"$1"]}])
      |> Enum.each(&purge/1)
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

        Enum.each(excess, fn {id, _} -> purge(id) end)
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
        |> Enum.each(fn {id, _} -> purge(id) end)
      end
    end
  rescue
    ArgumentError -> :ok
  end

  # Delete an id from both tables (full entries + rows) so they stay in sync.
  defp purge(id) do
    :ets.delete(@table, id)
    :ets.delete(@rows_table, id)
  end

  defp email_match?(_email, search) when search in [nil, ""], do: true
  defp email_match?(nil, _search), do: true
  defp email_match?(email, search), do: String.contains?(email, search)

  defp subject_type_match?(_type, search) when search in [nil, ""], do: true
  defp subject_type_match?(type, type), do: true
  defp subject_type_match?(_, _), do: false

  defp model_match?(_model, search) when search in [nil, ""], do: true
  defp model_match?(model, model), do: true
  defp model_match?(_, _), do: false

  # First message content, truncated to 200 chars.
  defp first_message_preview(messages) do
    messages
    |> Enum.find_value("", fn
      %{"content" => content} when is_binary(content) -> content
      _ -> nil
    end)
    |> String.slice(0, 200)
  end

  # Last message content, truncated to 200 chars — what the table shows.
  defp last_message_preview([]), do: ""

  defp last_message_preview(messages) do
    case List.last(messages) do
      %{"content" => content} when is_binary(content) -> String.slice(content, 0, 200)
      _ -> ""
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)

  defp mono_now, do: System.monotonic_time(:millisecond)
end
