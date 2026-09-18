defmodule Tokengate.Auditing.PartitionWorker do
  @moduledoc """
  Oban worker that maintains **monthly** partitions of `audit_logs`.

  `audit_logs` is a native Postgres RANGE-partitioned table on `inserted_at`
  (see migration `audit_logs_partitioned_and_context`). Without named monthly
  partitions, every row lands in `audit_logs_default` and partition pruning is
  dead weight. This worker keeps them operational and enforces retention.

  ## What it does (each run)

    1. `ensure_upcoming_partitions/1` — creates the partition for the current
       month plus the next `@months_ahead` months, so inserts hit a real
       partition.
    2. `backfill_default_partitions/0` — moves months still sitting in
       `audit_logs_default` into their own partition (same recipe as
       `Tokengate.Logs.PartitionWorker`: create standalone `LIKE ... INCLUDING
       ALL`, move the rows atomically, then `ATTACH PARTITION`).
    3. `cleanup_old_partitions/1` — drops monthly partitions whose entire range
       is older than `@retention_days`. Monthly granularity means the effective
       retention is 90–120 days ("at least 90 days").

  ## Scheduling

  Wired into `config/config.exs` Oban `:crontab` (daily, 00:10 UTC), plus an
  at-boot `ensure_on_boot/0` from the supervision tree.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  require Logger
  alias Tokengate.Repo

  @retention_days 90
  @months_ahead 2
  @table "audit_logs"
  @default_partition "audit_logs_default"
  @partition_prefix "audit_logs_"

  # ---------------------------------------------------------------------------
  # Oban entry point
  # ---------------------------------------------------------------------------

  @impl true
  def perform(_job) do
    ensure_upcoming_partitions(@months_ahead)
    backfill_default_partitions()
    cleanup_old_partitions(@retention_days)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Boot hook
  # ---------------------------------------------------------------------------

  @doc """
  Ensures upcoming partitions exist at application boot, so the first inserts
  hit a real partition before the first cron run. No-op when the
  `:audit_partition_boot_ensure` app env is false (test env). Never raises.
  """
  @spec ensure_on_boot() :: :ok
  def ensure_on_boot do
    if Application.get_env(:tokengate, :audit_partition_boot_ensure, true) do
      {:ok, results} = ensure_upcoming_partitions(@months_ahead)

      created =
        Enum.count(results, fn
          {_month, status} when status in [:created, :backfilled] -> true
          _ -> false
        end)

      if created > 0 do
        Logger.info("Audit PartitionWorker: ensured #{created} new audit_logs partition(s)")
      end
    end

    :ok
  rescue
    e ->
      Logger.error("Audit PartitionWorker: boot ensure crashed: #{inspect(e)}")
      :ok
  end

  # ---------------------------------------------------------------------------
  # Ensure (create missing partitions)
  # ---------------------------------------------------------------------------

  @doc """
  Ensures partitions exist for the current month plus the next
  `months_ahead` months. Returns `{:ok, [{month_start_date, status}]}`.
  """
  @spec ensure_upcoming_partitions(non_neg_integer(), Date.t()) ::
          {:ok, [{Date.t(), atom()}]}
  def ensure_upcoming_partitions(months_ahead \\ @months_ahead, base_date \\ Date.utc_today()) do
    first = Date.new!(base_date.year, base_date.month, 1)

    results =
      Enum.map(0..months_ahead, fn offset ->
        month = add_months(first, offset)

        status =
          case ensure_partition(month) do
            {:ok, s} -> s
            {:error, reason} -> {:error, reason}
          end

        {month, status}
      end)

    {:ok, results}
  end

  @doc """
  Ensures the partition for a single month exists, moving any default-partition
  rows for that month into it. Returns `{:ok, :created | :backfilled | :exists}`
  or `{:error, :default_conflict}` (safe to retry).
  """
  @spec ensure_partition(Date.t()) ::
          {:ok, :created | :backfilled | :exists} | {:error, :default_conflict}
  def ensure_partition(month) do
    name = partition_name(month)

    cond do
      attached?(name) -> {:ok, :exists}
      table_exists?(name) -> attach_with_backfill(name, month)
      true -> try_fast_attach(name, month)
    end
  end

  # ---------------------------------------------------------------------------
  # Backfill from the default partition
  # ---------------------------------------------------------------------------

  @doc """
  Moves every month currently sitting in `audit_logs_default` into its own
  partition. Months older than the retention cutoff are skipped (creating a
  named partition for them would hand them straight to cleanup).
  """
  @spec backfill_default_partitions() :: {:ok, [{Date.t(), atom()}]}
  def backfill_default_partitions do
    case Repo.query!(
           "SELECT date_trunc('month', min(inserted_at))::date, date_trunc('month', max(inserted_at))::date FROM #{@default_partition}"
         ).rows do
      [[nil, nil]] ->
        {:ok, []}

      [[%Date{} = min_m, %Date{} = max_m]] ->
        cutoff = retention_cutoff(@retention_days)
        first = if Date.compare(min_m, cutoff) == :lt, do: cutoff, else: min_m

        months =
          if Date.compare(first, max_m) == :gt do
            []
          else
            months_between(first, max_m)
          end

        results =
          Enum.map(months, fn month ->
            case ensure_partition(month) do
              {:ok, s} -> {month, s}
              {:error, reason} -> {month, {:error, reason}}
            end
          end)

        {:ok, results}
    end
  end

  # ---------------------------------------------------------------------------
  # Cleanup
  # ---------------------------------------------------------------------------

  @doc """
  Drops named monthly partitions whose entire range ends at or before the
  retention cutoff (`today - retention_days`). The default partition is never
  touched. Returns `{:ok, [dropped_names]}`.
  """
  @spec cleanup_old_partitions(non_neg_integer()) :: {:ok, [String.t()]}
  def cleanup_old_partitions(retention_days \\ @retention_days) do
    cutoff = retention_cutoff(retention_days)

    dropped =
      list_partition_names()
      |> Enum.filter(fn name ->
        case partition_month(name) do
          nil -> false
          month -> Date.compare(next_month(month), cutoff) != :gt
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

  @doc "Names of all partitions attached to `audit_logs` (default included)."
  @spec list_partition_names() :: [String.t()]
  def list_partition_names do
    Repo.query!("""
    SELECT c.relname
    FROM pg_inherits i
    JOIN pg_class c ON c.oid = i.inhrelid
    JOIN pg_class p ON p.oid = i.inhparent
    WHERE p.relname = '#{@table}'
    ORDER BY c.relname
    """).rows
    |> List.flatten()
  end

  @doc "The monthly partition name for a date: `audit_logs_YYYY_MM`."
  @spec partition_name(Date.t()) :: String.t()
  def partition_name(date) do
    @partition_prefix <> pad4(date.year) <> "_" <> pad2(date.month)
  end

  # Parses `audit_logs_YYYY_MM` back into the month's first date; nil for
  # anything else (this is what keeps the default partition out of cleanup).
  defp partition_month(name) do
    with @partition_prefix <> ym <- name,
         [y, m] <- String.split(ym, "_"),
         {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(m),
         {:ok, date} <- Date.new(year, month, 1) do
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

  defp try_fast_attach(name, month) do
    {from_iso, to_iso} = partition_bounds(month)

    Repo.query!(
      "CREATE TABLE #{name} PARTITION OF #{@table} FOR VALUES FROM ('#{from_iso}') TO ('#{to_iso}')"
    )

    {:ok, :created}
  rescue
    e in Postgrex.Error ->
      if e.postgres.code == :check_violation do
        attach_with_backfill(name, month)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp attach_with_backfill(name, month) do
    {from_iso, to_iso} = partition_bounds(month)

    result =
      Repo.transaction(fn ->
        Repo.query!(
          "CREATE TABLE IF NOT EXISTS #{name} (LIKE #{@default_partition} INCLUDING ALL)"
        )

        Repo.query!("""
        WITH moved AS (
          DELETE FROM #{@default_partition}
          WHERE inserted_at >= '#{from_iso}'::timestamp
            AND inserted_at < '#{to_iso}'::timestamp
          RETURNING *
        )
        INSERT INTO #{name}
        SELECT * FROM moved
        """)

        Repo.query!(
          "ALTER TABLE #{@table} ATTACH PARTITION #{name} FOR VALUES FROM ('#{from_iso}') TO ('#{to_iso}')"
        )
      end)

    case result do
      {:ok, _} ->
        Repo.query!("ANALYZE #{name}")
        {:ok, :backfilled}

      {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ->
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
      WHERE p.relname = $1 AND c.relname = $2
      """,
      [@table, name]
    ).rows != []
  end

  defp table_exists?(name) do
    Repo.query!("SELECT to_regclass($1)", ["public." <> name]).rows != [[nil]]
  end

  # Partition bounds for a month: [first-of-month 00:00, first-of-next 00:00)
  defp partition_bounds(month) do
    {Date.to_iso8601(month), Date.to_iso8601(next_month(month))}
  end

  defp next_month(month), do: add_months(month, 1)

  defp add_months(%Date{year: y, month: m}, n) do
    total = y * 12 + (m - 1) + n
    Date.new!(div(total, 12), rem(total, 12) + 1, 1)
  end

  defp months_between(from, to) do
    Stream.iterate(from, &add_months(&1, 1))
    |> Enum.take_while(&(Date.compare(&1, to) != :gt))
  end

  defp retention_cutoff(days), do: Date.utc_today() |> Date.add(-days) |> first_of_month()

  defp first_of_month(date), do: Date.new!(date.year, date.month, 1)

  defp pad2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
  defp pad4(n), do: String.pad_leading(Integer.to_string(n), 4, "0")
end
