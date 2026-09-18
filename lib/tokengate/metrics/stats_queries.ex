defmodule Tokengate.Metrics.StatsQueries do
  @moduledoc """
  Read facade for the stats dashboards: answers period aggregates from the
  **hourly rollup** (`request_metrics_hourly`) whenever the window allows it,
  falling back to raw `request_logs` for the fresh tail the `RollupWorker`
  has not aggregated yet.

  ## Why hybrid

  The rollup worker re-aggregates the last `@tail_hours` (3) hours every 60s,
  so hours older than that are trustworthy; the tail of the window — anything
  after `now - 3h` — may not be in the rollup yet. Queries here split the
  requested `[from, to]` window at `rollup_cutoff = now - 3h`:

    * rollup part — aggregated integer sums (fast: no partitions to Append,
      no Decimal aggregation, thousands of rows instead of millions);
    * tail part — the same aggregate over raw `request_logs`, bounded to at
      most 3h of data, so it only ever touches today's partitions.

  Both halves are additive counters, so merging is summing. Freshness is
  unchanged: the numbers describe the same instant the raw query would.

  ## Env flag

  `config :tokengate, :stats_rollup, hybrid: false` (the test env) disables
  the split — every query answers from raw `request_logs`, matching the
  pre-rollup behaviour so fixtures with arbitrary historical dates stay
  correct without depending on the worker.

  ## Coverage

  Only aggregates whose dimensions exist in the rollup go hybrid: summary,
  `breakdown_by_model`, `breakdown_by_member`, `breakdown_by_group`,
  `usage_by_hour_of_day`. Aggregates keyed on `service_id`, `status_code` or
  sub-hour buckets have no rollup counterpart and stay raw (callers keep
  using `Tokengate.Metrics.Rollup` / `Tokengate.Logs` directly for those).
  """

  import Ecto.Query, warn: false

  alias Tokengate.Logs
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Repo

  # Same refresh window the RollupWorker re-aggregates every tick — anything
  # older is immutable in practice (request_logs is append-only).
  @tail_hours 3

  # ---------------------------------------------------------------------
  # Summary
  # ---------------------------------------------------------------------

  @doc """
  Period summary (the KPI card numbers): request count, cost, tokens,
  avg tps. Accepts the same filter map as `Logs.cost_summary/1`
  (`:from`/`:to`/`:model_id`/`:group_id`/`:service_id`/`:member_ids`/
  `:group_member_ids`) or the equivalent keyword list; extra filter keys
  are passed through to the raw side untouched.
  """
  def summary(filters \\ []) do
    filters = normalize_filters(filters)

    if hybrid?(filters) do
      merge_summaries(
        Rollup.summary_from_rollup(
          member_ids: filters[:member_ids] || filters[:group_member_ids],
          from: Map.get(filters, :from),
          to: tail_from()
        ),
        raw_summary(Map.put(filters, :from, tail_from()))
      )
    else
      raw_summary(filters)
    end
  end

  # ---------------------------------------------------------------------
  # Breakdowns
  # ---------------------------------------------------------------------

  @doc "Per-model breakdown. Same row shape as `Rollup.breakdown_by_model/2`."
  def breakdown_by_model(group_id \\ nil, opts \\ []) do
    if hybrid?(opts) and is_nil(group_id) do
      merge_rows(
        rollup_breakdown(:model, opts),
        raw_breakdown(:model, group_id, opts)
      )
    else
      Rollup.breakdown_by_model(group_id, opts)
    end
  end

  @doc "Per-member breakdown. Same row shape as `Rollup.breakdown_by_member/2`."
  def breakdown_by_member(group_id \\ nil, opts \\ []) do
    if hybrid?(opts) and is_nil(group_id) do
      merge_rows(
        rollup_breakdown(:member, opts),
        raw_breakdown(:member, group_id, opts)
      )
    else
      Rollup.breakdown_by_member(group_id, opts)
    end
  end

  @doc "Per-group breakdown. Same row shape as `Rollup.breakdown_by_group/1`."
  def breakdown_by_group(opts \\ []) do
    if hybrid?(opts) do
      merge_rows(
        rollup_breakdown(:group, opts),
        raw_breakdown(:group, nil, opts)
      )
    else
      Rollup.breakdown_by_group(opts)
    end
  end

  @doc "24h UTC hour-of-day distribution. Same shape as `Rollup.usage_by_hour_of_day/2`."
  def usage_by_hour_of_day(group_id \\ nil, opts \\ []) do
    if hybrid?(opts) and is_nil(group_id) do
      counts =
        Enum.reduce(rollup_hour_counts(opts) ++ tail_hour_counts(opts), %{}, fn {hour, n}, acc ->
          Map.update(acc, hour, n, &(&1 + n))
        end)

      for hour <- 0..23 do
        %{hour: hour, request_count: Map.get(counts, hour, 0)}
      end
    else
      Rollup.usage_by_hour_of_day(group_id, opts)
    end
  end

  # ---------------------------------------------------------------------
  # Rollup-side queries
  # ---------------------------------------------------------------------

  defp rollup_breakdown(:model, opts) do
    Rollup.breakdown_by_model_from_rollup(from: Keyword.fetch!(opts, :from), to: tail_from())
  end

  defp rollup_breakdown(:member, opts) do
    Rollup.breakdown_by_member_from_rollup(
      from: Keyword.fetch!(opts, :from),
      to: tail_from(),
      member_ids: opts[:member_ids]
    )
  end

  defp rollup_breakdown(:group, opts) do
    Rollup.breakdown_by_group_from_rollup(
      from: Keyword.fetch!(opts, :from),
      to: tail_from(),
      member_ids: opts[:member_ids]
    )
  end

  defp rollup_hour_counts(opts) do
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    from(m in Tokengate.Metrics.RequestMetricsHourly,
      where: m.hour_utc >= ^Keyword.fetch!(opts, :from) and m.hour_utc < ^tail_from(),
      group_by: fragment("1"),
      select: %{
        hour:
          type(
            fragment(
              "EXTRACT(hour FROM (? AT TIME ZONE 'Etc/UTC') AT TIME ZONE ?)",
              m.hour_utc,
              ^timezone
            ),
            :integer
          ),
        n: fragment("COALESCE(SUM(?), 0)::bigint", m.request_count)
      }
    )
    |> Repo.all()
    |> Enum.map(&{&1.hour, &1.n})
  end

  # ---------------------------------------------------------------------
  # Raw-side queries (the fresh ≤3h tail — same shapes as the full versions)
  # ---------------------------------------------------------------------

  defp normalize_filters([]), do: %{}

  defp normalize_filters(filters) when is_list(filters), do: Map.new(filters)

  defp normalize_filters(filters) when is_map(filters), do: filters

  defp raw_summary(filters) do
    filters
    |> Map.drop([:timezone])
    |> Logs.cost_summary()
  end

  defp raw_breakdown(:model, group_id, opts) do
    Rollup.breakdown_by_model(group_id, tail_opts(opts))
  end

  defp raw_breakdown(:member, group_id, opts) do
    Rollup.breakdown_by_member(group_id, tail_opts(opts))
  end

  defp raw_breakdown(:group, _group_id, opts) do
    Rollup.breakdown_by_group(tail_opts(opts))
  end

  defp tail_opts(opts) do
    opts
    |> Keyword.put(:from, tail_from())
    |> Keyword.put(:to, Keyword.get(opts, :to))
  end

  defp tail_hour_counts(opts) do
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    from(rl in RequestLog,
      where: rl.inserted_at >= ^tail_from(),
      group_by: fragment("1"),
      select: %{
        hour:
          type(
            fragment(
              "EXTRACT(hour FROM (? AT TIME ZONE 'Etc/UTC') AT TIME ZONE ?)",
              rl.inserted_at,
              ^timezone
            ),
            :integer
          ),
        n: count(rl.id)
      }
    )
    |> maybe_member_ids(opts[:member_ids])
    |> Repo.all()
    |> Enum.map(&{&1.hour, &1.n})
  end

  defp maybe_member_ids(query, nil), do: query

  defp maybe_member_ids(query, ids),
    do: where(query, [rl], rl.group_member_id in ^ids)

  # ---------------------------------------------------------------------
  # Merging
  # ---------------------------------------------------------------------

  # Sums the additive counters of two Logs.cost_summary/1-shaped maps.
  defp merge_summaries(a, b) do
    %{
      total_cost_usd: Decimal.add(a.total_cost_usd, b.total_cost_usd),
      total_prompt_tokens: a.total_prompt_tokens + b.total_prompt_tokens,
      total_completion_tokens: a.total_completion_tokens + b.total_completion_tokens,
      total_cache_read_tokens: a.total_cache_read_tokens + b.total_cache_read_tokens,
      total_cache_creation_tokens: a.total_cache_creation_tokens + b.total_cache_creation_tokens,
      request_count: a.request_count + b.request_count,
      avg_tps: merged_tps(a, b)
    }
  end

  # avg_tps is derived (completion_tokens / latency): merge the inputs.
  defp merged_tps(a, b) do
    tokens = a.total_completion_tokens + b.total_completion_tokens

    latency =
      (Map.get(a, :total_latency_ms) || 0) + (Map.get(b, :total_latency_ms) || 0)

    cond do
      tokens == 0 -> nil
      latency == 0 -> 0.0
      true -> tokens / (latency / 1000)
    end
  end

  # Merges two breakdown row lists (rollup half + raw-tail half) by identity
  # key, summing additive counters. Rows only in the raw half are appended;
  # avg_tps is recomputed from the summed inputs.
  defp merge_rows(rollup_rows, raw_rows) do
    Enum.reduce(raw_rows, rollup_rows, fn raw, acc ->
      case Enum.find_index(acc, &same_row?(&1, raw)) do
        nil -> acc ++ [raw]
        idx -> List.update_at(acc, idx, &sum_row(&1, raw))
      end
    end)
  end

  defp same_row?(a, b) do
    keys = [a[:model_id], a[:user_id], a[:group_member_id], a[:group_id]]

    keys_with_values =
      Enum.zip(keys, [b[:model_id], b[:user_id], b[:group_member_id], b[:group_id]])

    Enum.any?(keys_with_values, fn {a_id, b_id} -> not is_nil(a_id) and a_id == b_id end)
  end

  defp sum_row(a, b) do
    tokens = (a.completion_tokens || 0) + (b.completion_tokens || 0)
    latency = (a[:total_latency_ms] || 0) + (b[:total_latency_ms] || 0)

    a
    |> Map.put(:request_count, a.request_count + b.request_count)
    |> Map.put(:cost_usd, Decimal.add(a.cost_usd, b.cost_usd))
    |> Map.put(:prompt_tokens, (a.prompt_tokens || 0) + (b.prompt_tokens || 0))
    |> Map.put(:completion_tokens, tokens)
    |> Map.put(:cache_read_tokens, (a.cache_read_tokens || 0) + (b.cache_read_tokens || 0))
    |> Map.put(:avg_tps, compute_tps(tokens, latency))
  end

  defp compute_tps(_tokens, 0), do: nil
  defp compute_tps(0, _latency), do: 0.0
  defp compute_tps(tokens, latency), do: tokens / (latency / 1000)

  # ---------------------------------------------------------------------
  # Hybrid gating
  # ---------------------------------------------------------------------

  # Hybrid only when: flag on, the window has a `:from`, and the window
  # reaches beyond the fresh tail (recent-only windows answer raw anyway).
  #
  # `from` must be EARLIER than the tail cutoff, so the rollup half covers
  # `[from, tail_from)` and the raw half covers `[tail_from, to]` — disjoint,
  # together the requested window. The comparison was inverted (it read
  # `tail_from < from`), which (a) answered every multi-hour window fully raw
  # and (b) for windows starting inside the last 3h made the raw half start at
  # `tail_from`, folding up to 3h of pre-window rows into the KPI.
  #
  # The rollup only carries `(hour, group_member_id, model_id, provider_id)`
  # dimensions, so any filter it cannot express (`service_id`, `model_id`,
  # `group_id`, `provider_id`, …) forces the raw path — otherwise the rollup
  # half would silently ignore the filter and answer org-wide.
  defp hybrid?(filters_or_opts) do
    from = get_from(filters_or_opts)

    hybrid_enabled?() and is_struct(from, DateTime) and
      DateTime.compare(from, tail_from()) == :lt and
      rollup_scope?(filters_or_opts)
  end

  @rollup_keys [:from, :to, :timezone, :member_ids, :group_member_ids]

  defp rollup_scope?(filters) when is_map(filters),
    do: filters |> Map.keys() |> Enum.all?(&(&1 in @rollup_keys))

  defp rollup_scope?(opts) when is_list(opts),
    do: opts |> Keyword.keys() |> Enum.all?(&(&1 in @rollup_keys))

  defp get_from(filters) when is_map(filters), do: Map.get(filters, :from)
  defp get_from(opts) when is_list(opts), do: Keyword.get(opts, :from)

  defp hybrid_enabled? do
    Application.get_env(:tokengate, :stats_rollup, hybrid: true)[:hybrid] != false
  end

  defp tail_from do
    DateTime.add(DateTime.utc_now(), -@tail_hours * 3600, :second)
    |> DateTime.truncate(:second)
  end
end
