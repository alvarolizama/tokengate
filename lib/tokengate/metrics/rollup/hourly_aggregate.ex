defmodule Tokengate.Metrics.Rollup.HourlyAggregate do
  @moduledoc """
  Writes the hourly metrics rollup (`request_metrics_hourly`) from
  `request_logs`.

  The single entry point is `aggregate_hours/1`: for a UTC hour range, it
  groups `request_logs` by `(hour, group_member_id, model_id,
  provider_id)` and upserts the sums into the rollup table. Because each
  hour is **fully re-aggregated** (not incremented), the operation is
  idempotent: late-arriving logs, corrected rows, or a crashed run simply
  converge on the next execution.

  Read paths live in `Tokengate.Metrics.Rollup` (`hourly_series_from_rollup/2`,
  `summary_from_rollup/2`, `top_errors_from_rollup/2`).

  ## Cost precision

  `provider_cost_usd` (Decimal) is stored as integer micro-USD
  (`ROUND(usd * 1_000_000)`). Summing integers is exact; converting back
  is a single `Decimal` division per display value. The rounding error is
  bounded by 1 micro-dollar per hour-bucket-dimension, far below any
  display precision the dashboards use (6+ decimals).
  """

  import Ecto.Query, warn: false
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Metrics.RequestMetricsHourly
  alias Tokengate.Repo

  require Logger

  # Same policy as the `request_logs` partition DROP
  # (`Tokengate.Logs.PartitionWorker.retention_days/0`): the rollup and the raw
  # table age out together, or the hybrid reads would serve a rollup window the
  # raw side no longer has.
  @retention_days 90

  # The readers serve the rollup only for hours that closed at least
  # `@reader_tail_hours` ago (see `Tokengate.Metrics.StatsQueries`); raw rows
  # newer than that come from `request_logs`. A rollup lag smaller than this
  # is normal and is repaired by the worker's tail refresh — only a BIGGER lag
  # means the readers are already falling back to raw.
  @reader_tail_hours 3

  @doc """
  Re-aggregates the UTC hours covered by `[from, to)` into
  `request_metrics_hourly`.

  `from` and `to` must be UTC `DateTime`s; the range is clamped to whole
  hours (`date_trunc('hour', ...)`). Each execution **deletes the hour range
  and re-inserts it** from `request_logs`, so the rollup content for the
  range is a pure function of the raw table — regardless of run order,
  repetition, or **key changes** (the bucket key now carries `user_id`, and
  membership rotation rewrites `group_member_id` to NULL; an upsert-only
  writer would leave stale rows under the old key and double-count).

  The delete+insert pair runs in ONE transaction: a reader never sees the
  window half-written.

  Returns `{:ok, rows_written}` with the Postgres command tag row count
  (rows inserted).
  """
  @spec aggregate_hours(DateTime.t(), DateTime.t()) :: {:ok, non_neg_integer()}
  def aggregate_hours(from, to) when is_struct(from, DateTime) and is_struct(to, DateTime) do
    # `from` SIEMPRE al piso de la hora. El DELETE borra por `hour_utc >= from`
    # y el INSERT re-agrega por `inserted_at >= from`: con un `from` a media
    # hora (el worker pasa `now - 3h`, que casi nunca cae en borde) el bucket
    # que CONTIENE `from` quedaba fuera del DELETE pero dentro del INSERT, así
    # que el ON CONFLICT lo sobreescribía con el agregado parcial
    # `[from, fin del bucket]`. Cuando la ventana de 3h se deslizaba y dejaba
    # atrás ese bucket, el parcial quedaba congelado: cada hora del rollup
    # terminaba con ~1 minuto de tráfico en lugar de la hora entera, y todas
    # las lecturas híbridas (Resumen, dashboard, desgloses) caían contra el
    # crudo (En vivo, tope diario global).
    from = from |> DateTime.truncate(:second) |> floor_hour()
    to = DateTime.truncate(to, :second)

    delete_sql = """
    DELETE FROM request_metrics_hourly
     WHERE hour_utc >= $1 AND hour_utc < $2
    """

    insert_sql = """
    WITH bucketed AS (
      SELECT
        date_trunc('hour', rl.inserted_at) AS hour_utc,
        rl.user_id,
        rl.group_member_id,
        rl.model_id,
        rl.provider_id,
        rl.status_code,
        rl.prompt_tokens,
        rl.completion_tokens,
        rl.cache_read_tokens,
        rl.cache_creation_tokens,
        rl.provider_cost_usd,
        rl.latency_ms
      FROM request_logs rl
      WHERE rl.inserted_at >= $1 AND rl.inserted_at < $2
    )
    INSERT INTO request_metrics_hourly
      (id, day, hour_utc, user_id, group_member_id, model_id, provider_id,
       request_count, error_count, prompt_tokens, completion_tokens,
       cache_read_tokens, cache_creation_tokens, cost_micro,
       total_latency_ms, latency_count, inserted_at, updated_at)
    SELECT
      gen_random_uuid(),
      b.hour_utc::date,
      b.hour_utc,
      b.user_id,
      b.group_member_id,
      b.model_id,
      b.provider_id,
      COUNT(*),
      COUNT(*) FILTER (WHERE b.status_code >= 400),
      COALESCE(SUM(b.prompt_tokens), 0)::bigint,
      COALESCE(SUM(b.completion_tokens), 0)::bigint,
      COALESCE(SUM(b.cache_read_tokens), 0)::bigint,
      COALESCE(SUM(b.cache_creation_tokens), 0)::bigint,
      COALESCE(SUM(ROUND(b.provider_cost_usd * 1000000)), 0)::bigint,
      COALESCE(SUM(b.latency_ms), 0)::bigint,
      COUNT(b.latency_ms),
      now(),
      now()
    FROM bucketed b
    GROUP BY b.hour_utc, b.user_id, b.group_member_id, b.model_id, b.provider_id
    ON CONFLICT (day, hour_utc, user_id, group_member_id, model_id, provider_id)
    DO UPDATE SET
      request_count = EXCLUDED.request_count,
      error_count = EXCLUDED.error_count,
      prompt_tokens = EXCLUDED.prompt_tokens,
      completion_tokens = EXCLUDED.completion_tokens,
      cache_read_tokens = EXCLUDED.cache_read_tokens,
      cache_creation_tokens = EXCLUDED.cache_creation_tokens,
      cost_micro = EXCLUDED.cost_micro,
      total_latency_ms = EXCLUDED.total_latency_ms,
      latency_count = EXCLUDED.latency_count,
      updated_at = now()
    """

    Repo.transaction(fn ->
      Repo.query!(delete_sql, [from, to], log: false)
      Repo.query!(insert_sql, [from, to], log: false)
    end)

    {:ok, rows_written} = count_rows(from, to)
    {:ok, rows_written}
  end

  # Row count for the aggregated range — the INSERT tag under a transaction
  # wrapper is not surfaced, so the count answers "rows written" explicitly.
  defp count_rows(from, to) do
    result =
      Repo.one(
        from m in Tokengate.Metrics.RequestMetricsHourly,
          where: m.hour_utc >= ^from and m.hour_utc < ^to,
          select: count(m.id)
      )

    {:ok, result}
  end

  @doc """
  Backfills the rollup for every UTC hour between `from` and `to` (or up
  to `Date.utc_today()` when omitted), one day at a time to keep each
  transaction bounded.

  Returns `{:ok, %{days: n, rows: total_rows, from: first_day, to: last_day,
  remaining_days: n}}`. `remaining_days` is always 0 when the call returns
  normally — it is non-zero only in the tuple the progress callback sees, so
  a caller tailing the log knows how much is left.

  Safe to re-run: every hour is re-aggregated with upserts. For a first
  production backfill over millions of `request_logs` rows, run inside
  `iex` and watch the day counters (each day is its own statement — a
  failed day does not lose the progress of previous days).

  ## Options

    * `:on_progress` — 1-arity fun called with
      `%{day: Date, rows: n, done: n, total: n, remaining_days: n}` after each
      day commits. Defaults to logging the day counter (the only progress
      signal an operator watching `iex` gets, and where a cut run resumes).
  """
  @spec backfill(DateTime.t(), DateTime.t() | nil, keyword()) ::
          {:ok,
           %{
             days: non_neg_integer(),
             rows: non_neg_integer(),
             from: Date.t(),
             to: Date.t(),
             remaining_days: 0
           }}
  def backfill(from, to \\ nil, opts \\ []) when is_struct(from, DateTime) do
    to = to || DateTime.new!(Date.utc_today() |> Date.add(1), ~T[00:00:00], "Etc/UTC")

    from_day = DateTime.to_date(from)
    to_day = DateTime.to_date(to)
    days = Date.range(from_day, to_day) |> Enum.to_list()
    total = length(days)
    on_progress = Keyword.get(opts, :on_progress, &log_progress/1)

    {rows, done} =
      Enum.reduce(days, {0, 0}, fn day, {rows, done} ->
        day_from = DateTime.new!(day, ~T[00:00:00], "Etc/UTC")

        day_to =
          DateTime.new!(Date.add(day, 1), ~T[00:00:00], "Etc/UTC")
          |> min_dt(to)

        {:ok, day_rows} = aggregate_hours(day_from, day_to)
        done = done + 1

        on_progress.(%{
          day: day,
          rows: day_rows,
          done: done,
          total: total,
          remaining_days: total - done
        })

        {rows + day_rows, done}
      end)

    {:ok, %{days: done, rows: rows, from: from_day, to: to_day, remaining_days: 0}}
  end

  defp log_progress(%{day: day, rows: rows, done: done, total: total}) do
    # Un día por transacción: en un backfill de 90 días esto es la única
    # señal de avance que ve quien lo corre (y de dónde reanudar si corta).
    Logger.info(
      "[rollup backfill] #{day} → #{rows} buckets (#{done}/#{total}, faltan #{total - done})"
    )
  end

  # -----------------------------------------------------------------------
  # Coverage / self-healing
  # -----------------------------------------------------------------------

  @doc """
  Start of the newest hour that has rows in `request_logs` (`nil` when the
  table is empty). Index-only over the `inserted_at` index: the cheapest
  possible "is there raw data the rollup has not seen" probe.
  """
  @spec newest_raw_hour() :: DateTime.t() | nil
  def newest_raw_hour do
    newest =
      RequestLog
      |> select([rl], max(rl.inserted_at))
      |> Repo.one(timeout: stats_timeout())

    case as_utc(newest) do
      nil -> nil
      dt -> floor_hour(dt)
    end
  end

  @doc """
  Hours between the newest raw log hour and the newest rollup bucket —
  `:empty` when either side has no data.

  A value above `#{@reader_tail_hours}` means the readers are serving raw
  rows for hours the rollup should already own (the guard fails and every
  hybrid read falls back to a full raw window).
  """
  @spec gap_hours() :: float() | :empty
  def gap_hours do
    with %DateTime{} = raw <- newest_raw_hour(),
         %{last_hour_utc: %DateTime{} = covered} <- Tokengate.Metrics.Rollup.coverage() do
      max(DateTime.diff(raw, covered, :second) / 3600, 0.0)
    else
      _ -> :empty
    end
  end

  @doc """
  Closes the gap between the newest rollup bucket and the newest raw hour —
  the self-healing half of `Tokengate.Metrics.RollupWorker` (F29).

  Runs only when the lag exceeds `:threshold_hours` (default
  `#{@reader_tail_hours}`, the readers' raw tail): below that the worker's
  tail refresh is the cheaper fix and re-aggregating history every tick is
  exactly the write amplification this replaces.

  A rollup with no data at all (fresh deploy) is backfilled from
  `retention_days` before the newest raw hour, one day per transaction.

  Returns `{:ok, %{status: :covered | :backfilled | :no_data, gap_hours: f,
  days: n, rows: n}}`.
  """
  @spec backfill_gap(keyword()) ::
          {:ok,
           %{
             status: :covered | :backfilled | :no_data,
             gap_hours: float() | :empty,
             days: non_neg_integer(),
             rows: non_neg_integer()
           }}
  def backfill_gap(opts \\ []) do
    threshold_hours = Keyword.get(opts, :threshold_hours, @reader_tail_hours)
    retention_days = Keyword.get(opts, :retention_days, retention_days())
    gap = gap_hours()

    case {gap, newest_raw_hour()} do
      {:empty, nil} ->
        {:ok, %{status: :no_data, gap_hours: :empty, days: 0, rows: 0}}

      {gap, %DateTime{} = raw_to} ->
        if is_float(gap) and gap <= threshold_hours do
          {:ok, %{status: :covered, gap_hours: gap, days: 0, rows: 0}}
        else
          to = DateTime.add(raw_to, 3600, :second)

          from =
            case Tokengate.Metrics.Rollup.coverage().last_hour_utc do
              nil -> DateTime.add(to, -retention_days * 86_400, :second)
              covered -> covered
            end

          {:ok, %{days: days, rows: rows}} =
            backfill(floor_hour(from), to, Keyword.take(opts, [:on_progress]))

          {:ok, %{status: :backfilled, gap_hours: gap, days: days, rows: rows}}
        end
    end
  end

  # -----------------------------------------------------------------------
  # Retention
  # -----------------------------------------------------------------------

  @doc """
  Retention window in days — the SAME one the `request_logs` partition DROP
  uses (`Tokengate.Logs.PartitionWorker.retention_days/0`). Overridable per
  environment through `config :tokengate, :logs_retention_days`; tests pass
  `:retention_days` explicitly.
  """
  @spec retention_days() :: non_neg_integer()
  def retention_days do
    Application.get_env(:tokengate, :logs_retention_days, @retention_days)
  end

  @doc """
  Drops rollup rows past retention, aligned with the raw partition DROP by
  CALENDAR DAY: the partition worker keeps every day `>= today -
  retention_days` and drops the rest, so the rollup deletes `day <
  today - retention_days`. The previous sliding cutoff
  (`hour_utc < now - 90d`) could delete a day the raw side still had (or keep
  a day it had already dropped), leaving the hybrid reads with a rollup half
  that no longer reconciles with the raw half.

  Deletes on the `day` prefix of every rollup index.
  """
  @spec prune(keyword()) :: {:ok, %{deleted: non_neg_integer(), cutoff_day: Date.t()}}
  def prune(opts \\ []) do
    cutoff_day = Date.add(Date.utc_today(), -Keyword.get(opts, :retention_days, retention_days()))

    {deleted, _} =
      Repo.delete_all(from m in RequestMetricsHourly, where: m.day < ^cutoff_day)

    {:ok, %{deleted: deleted, cutoff_day: cutoff_day}}
  end

  defp as_utc(nil), do: nil
  defp as_utc(%DateTime{} = dt), do: dt
  defp as_utc(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

  defp stats_timeout, do: Application.get_env(:tokengate, :stats_query_timeout_ms, 120_000)

  defp min_dt(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)

  defp floor_hour(%DateTime{} = dt), do: %{dt | minute: 0, second: 0, microsecond: {0, 0}}
end
