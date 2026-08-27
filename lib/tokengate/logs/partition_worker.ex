defmodule Tokengate.Logs.PartitionWorker do
  @moduledoc """
  Oban worker that maintains daily partitions of `request_logs`.

  `request_logs` is a native Postgres RANGE-partitioned table on
  `inserted_at`, but without daily partitions actually existing, every row
  lands in `request_logs_default` and partition pruning is dead weight:
  every aggregate scans the whole default partition instead of touching
  only the days in range. This worker keeps partitions operational.

  ## What it does (each run)

    1. `ensure_upcoming_partitions/1` — creates partitions for today plus
       the next `@lookahead_days` days so inserts never hit the default
       partition.
    2. `backfill_default_partitions/1` — finds distinct days that still
       live in `request_logs_default` and moves them into proper
       partitions (see the backfill recipe below). Days older than the
       retention cutoff are deliberately left in the default partition —
       `cleanup_old_partitions/1` would drop them immediately otherwise,
       destroying data.
    3. `cleanup_old_partitions/1` — drops named partitions older than
       `@retention_days` (log retention policy).

  ## Scheduling

  Wired into `config/config.exs` Oban `:crontab` (daily, 00:05 UTC), plus
  an at-boot `ensure_on_boot/0` call from the supervision tree so today's
  partition exists before the first cron run.

  ## Backfill recipe (why not just CREATE ... PARTITION OF)

  `CREATE TABLE x PARTITION OF request_logs FOR VALUES ...` fails with
  `check_violation` while the default partition still holds rows for that
  range. The recovery:

    1. `CREATE TABLE x (LIKE request_logs_default INCLUDING ALL)` — a
       standalone table with the same PK and all indexes (including the
       member covering index).
    2. `WITH moved AS (DELETE FROM request_logs_default WHERE inserted_at
       IN range RETURNING *) INSERT INTO x SELECT * FROM moved` — atomic
       move (single statement, runs inside one transaction with step 3).
    3. `ALTER TABLE request_logs ATTACH PARTITION x FOR VALUES ...` —
       succeeds because the range is now empty in the default partition.

  Concurrent writers racing between the move and the ATTACH simply land
  back in the default partition and the ATTACH fails again — the next
  scheduled run retries. The window is tiny and the worker is idempotent.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  require Logger

  alias Tokengate.Repo

  @lookahead_days 3
  @retention_days 90
  # Safety cap: never process more than this many days of default-partition
  # backfill in a single run (a pathological backlog shouldn't wedge cron).
  @backfill_day_cap 2_000

  @partition_prefix "request_logs_"

  # ---------------------------------------------------------------------------
  # Oban entry point
  # ---------------------------------------------------------------------------

  @impl true
  def perform(_job) do
    ensure_upcoming_partitions(@lookahead_days)
    backfill_default_partitions(retention_days: @retention_days)
    cleanup_old_partitions(@retention_days)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Boot hook
  # ---------------------------------------------------------------------------

  @doc """
  Ensures upcoming partitions exist at application boot, so today's inserts
  hit a real partition before the first cron run. No-op when the
  `:partition_boot_ensure` app env is false (test env). Never raises — a DB
  hiccup at boot must not kill the app; the nightly cron catches up.
  """
  @spec ensure_on_boot() :: :ok
  def ensure_on_boot do
    if Application.get_env(:tokengate, :partition_boot_ensure, true) do
      {:ok, results} = ensure_upcoming_partitions(@lookahead_days)

      created =
        Enum.count(results, fn
          {_date, status} when status in [:created, :backfilled] -> true
          _ -> false
        end)

      if created > 0 do
        Logger.info("PartitionWorker: ensured #{created} new request_logs partition(s)")
      end
    end

    :ok
  rescue
    e ->
      Logger.error("PartitionWorker: boot ensure crashed: #{inspect(e)}")
      :ok
  end

  # ---------------------------------------------------------------------------
  # Ensure (create missing partitions)
  # ---------------------------------------------------------------------------

  @doc """
  Ensures partitions exist for `base_date` plus the next `lookahead_days`
  days. Returns `{:ok, [{date, status}]}` where status is `:created`,
  `:backfilled`, `:exists`, or `{:error, :default_conflict}`.
  """
  @spec ensure_upcoming_partitions(non_neg_integer(), Date.t()) ::
          {:ok,
           [
             {Date.t(), :created | :backfilled | :exists | {:error, :default_conflict}}
           ]}
  def ensure_upcoming_partitions(lookahead_days \\ @lookahead_days, base_date \\ Date.utc_today()) do
    results =
      for offset <- 0..lookahead_days do
        date = Date.add(base_date, offset)

        status =
          case ensure_partition(date) do
            {:ok, s} -> s
            {:error, reason} -> {:error, reason}
          end

        {date, status}
      end

    {:ok, results}
  end

  @doc """
  Ensures the partition for a single day exists, moving any default-
  partition rows for that day into it. Returns `{:ok, status}` where status
  is `:created` (fast path), `:backfilled` (rows had to be moved from the
  default partition), `:exists`, or `{:error, :default_conflict}` when new
  rows raced into the default partition during the ATTACH (safe to retry).
  """
  @spec ensure_partition(Date.t()) ::
          {:ok, :created | :backfilled | :exists} | {:error, :default_conflict}
  def ensure_partition(date) do
    name = partition_name(date)

    cond do
      attached?(name) ->
        {:ok, :exists}

      table_exists?(name) ->
        # Standalone leftover table (previous run created it but ATTACH
        # failed) — finish the job.
        attach_with_backfill(name, date)

      true ->
        try_fast_attach(name, date)
    end
  end

  # ---------------------------------------------------------------------------
  # Backfill from the default partition
  # ---------------------------------------------------------------------------

  @doc """
  Moves every distinct day currently sitting in `request_logs_default` into
  its own partition. Days older than the retention cutoff are skipped (they
  stay in the default partition; creating named partitions for them would
  just hand them to `cleanup_old_partitions/1`).

  Bounded by `@backfill_day_cap` days per run.
  """
  @spec backfill_default_partitions(keyword()) :: {:ok, [{Date.t(), atom()}]}
  def backfill_default_partitions(opts \\ []) do
    retention_days = Keyword.get(opts, :retention_days, @retention_days)

    case Repo.query!(
           "SELECT min(inserted_at)::date, max(inserted_at)::date FROM request_logs_default"
         ).rows do
      [[nil, nil]] ->
        {:ok, []}

      [[%Date{} = min_d, %Date{} = max_d]] ->
        earliest_allowed = Date.add(Date.utc_today(), -retention_days)
        first = max_date(min_d, earliest_allowed)

        days =
          if Date.compare(first, max_d) == :gt do
            []
          else
            Date.range(first, max_d) |> Enum.take(@backfill_day_cap)
          end

        results =
          Enum.map(days, fn date ->
            case ensure_partition(date) do
              {:ok, s} -> {date, s}
              {:error, reason} -> {date, {:error, reason}}
            end
          end)

        {:ok, results}
    end
  end

  # ---------------------------------------------------------------------------
  # Cleanup
  # ---------------------------------------------------------------------------

  @doc """
  Drops named daily partitions strictly older than `retention_days`. The
  default partition is never touched. Returns `{:ok, [dropped_names]}`.
  """
  @spec cleanup_old_partitions(non_neg_integer()) :: {:ok, [String.t()]}
  def cleanup_old_partitions(retention_days \\ @retention_days) do
    cutoff = Date.add(Date.utc_today(), -retention_days)

    dropped =
      list_partition_names()
      |> Enum.filter(fn name ->
        case partition_date(name) do
          nil -> false
          date -> Date.compare(date, cutoff) == :lt
        end
      end)
      |> Enum.map(fn name ->
        Repo.query!("DROP TABLE #{name}")
        name
      end)

    {:ok, dropped}
  end

  # ---------------------------------------------------------------------------
  # Introspection helpers
  # ---------------------------------------------------------------------------

  @doc "Names of all partitions attached to `request_logs` (default included)."
  @spec list_partition_names() :: [String.t()]
  def list_partition_names do
    Repo.query!("""
    SELECT c.relname
    FROM pg_inherits i
    JOIN pg_class c ON c.oid = i.inhrelid
    JOIN pg_class p ON p.oid = i.inhparent
    WHERE p.relname = 'request_logs'
    ORDER BY c.relname
    """).rows
    |> List.flatten()
  end

  @doc "The daily partition name for a date: `request_logs_YYYY_MM_DD`."
  @spec partition_name(Date.t()) :: String.t()
  def partition_name(date) do
    (@partition_prefix <> Date.to_string(date)) |> String.replace("-", "_")
  end

  # Parses `request_logs_YYYY_MM_DD` back into a Date; nil for anything else
  # (this is what keeps the default partition out of cleanup).
  defp partition_date(name) do
    with @partition_prefix <> ymd <- name,
         [y, m, d] <- String.split(ymd, "_"),
         {:ok, date} <- Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
      date
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp try_fast_attach(name, date) do
    {from_iso, to_iso} = partition_bounds(date)

    Repo.query!(
      "CREATE TABLE #{name} PARTITION OF request_logs FOR VALUES FROM ('#{from_iso}') TO ('#{to_iso}')"
    )

    {:ok, :created}
  rescue
    e in Postgrex.Error ->
      if e.postgres.code == :check_violation do
        attach_with_backfill(name, date)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp attach_with_backfill(name, date) do
    {from_iso, to_iso} = partition_bounds(date)

    result =
      Repo.transaction(fn ->
        Repo.query!(
          "CREATE TABLE IF NOT EXISTS #{name} (LIKE request_logs_default INCLUDING ALL)"
        )

        Repo.query!("""
        WITH moved AS (
          DELETE FROM request_logs_default
          WHERE inserted_at >= '#{from_iso}'::timestamp
            AND inserted_at < '#{to_iso}'::timestamp
          RETURNING *
        )
        INSERT INTO #{name}
        SELECT * FROM moved
        """)

        Repo.query!(
          "ALTER TABLE request_logs ATTACH PARTITION #{name} FOR VALUES FROM ('#{from_iso}') TO ('#{to_iso}')"
        )
      end)

    case result do
      {:ok, _} ->
        # Statistics for the planner right away (outside the txn is fine).
        Repo.query!("ANALYZE #{name}")
        {:ok, :backfilled}

      {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ->
        # Rows raced into the default partition between DELETE and ATTACH.
        # Nothing lost — the next run retries.
        {:error, :default_conflict}

      {:error, reason} ->
        raise "unexpected ATTACH failure for #{name}: #{inspect(reason)}"
    end
  end

  defp attached?(name) do
    Repo.query!(
      """
      SELECT 1
      FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
      JOIN pg_class p ON p.oid = i.inhparent
      WHERE p.relname = 'request_logs' AND c.relname = $1
      """,
      [name]
    ).rows != []
  end

  defp table_exists?(name) do
    Repo.query!("SELECT to_regclass($1)", ["public." <> name]).rows != [[nil]]
  end

  # Partition bounds for a date: [date 00:00, date+1 00:00)
  defp partition_bounds(date) do
    {Date.to_iso8601(date), Date.to_iso8601(Date.add(date, 1))}
  end

  defp max_date(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)
end
