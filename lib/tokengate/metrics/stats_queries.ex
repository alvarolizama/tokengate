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
      from = Map.get(filters, :from)
      to = Map.get(filters, :to)

      # El rollup sólo puede responder buckets de hora COMPLETOS dentro de
      # la ventana, así que ésta se parte en tres tramos disjuntos:
      #
      #   [from, ceil_hour(from))            — crudo (bucket parcial inicial)
      #   [ceil_hour(from), bound)           — rollup (buckets completos)
      #   [bound, to]                        — crudo (bucket de corte + cola)
      #
      # con `bound = floor_hour(min(to || ahora, corte_fresco))`. Sin esta
      # partición alineada a la hora, una ventana que termina justo en un
      # borde de hora (los períodos anteriores de los deltas terminan en el
      # inicio exacto del actual) se comía el bucket entero que arranca en
      # `to` (`hour_utc <= to`), y un arranque a media hora perdía su bucket
      # parcial: ni rollup (`hour_utc >= from`) ni cola cruda lo cubrían.
      bound = rollup_bound(to)
      rollup_from = ceil_hour(from)

      parts = [
        Rollup.summary_from_rollup(
          member_ids: filters[:member_ids] || filters[:group_member_ids],
          from: rollup_from,
          to: bound
        )
        | raw_edge_summaries(filters, from, rollup_from, bound, to)
      ]

      Enum.reduce(parts, &merge_summaries/2)
    else
      raw_summary(filters)
    end
  end

  # Fin de la parte rollup: la ventana acotada al corte fresco y alineada a
  # la hora — los buckets se leen con `<` (ver `maybe_rollup_to`), así que
  # el bucket que arranca exactamente en `bound` queda para el lado crudo.
  defp rollup_bound(nil), do: tail_floor()

  defp rollup_bound(%DateTime{} = to) do
    cutoff = tail_floor()

    if DateTime.compare(to, cutoff) == :lt, do: floor_hour(to), else: cutoff
  end

  # Tramos crudos de los bordes de la ventana: el bucket parcial del inicio
  # (sólo cuando `from` no cae en borde de hora) y todo lo posterior al
  # límite del rollup — bucket de corte incluido, que es el que doblaba o
  # se perdía cuando el corte era al segundo y no al borde de hora.
  #
  # Los límites se acotan con min/max contra la ventana: en ventanas más
  # cortas que una hora (rollup_from > bound) el tramo rollup queda vacío
  # y los crudos tienen que repartirse [from, to] sin solaparse ni
  # salirse de la ventana pedida.
  defp raw_edge_summaries(filters, from, rollup_from, bound, to) do
    start_edge =
      if DateTime.compare(rollup_from, from) == :gt do
        edge_to = min_dt(DateTime.add(rollup_from, -1, :second), to)
        [raw_summary(Map.merge(filters, %{from: from, to: edge_to}))]
      else
        []
      end

    tail_start = max_dt(bound, rollup_from)
    start_edge ++ [raw_summary(Map.merge(filters, %{from: tail_start, to: to}))]
  end

  defp min_dt(%DateTime{} = a, nil), do: a

  defp min_dt(%DateTime{} = a, %DateTime{} = b) do
    if DateTime.compare(a, b) == :lt, do: a, else: b
  end

  defp max_dt(%DateTime{} = a, %DateTime{} = b) do
    if DateTime.compare(a, b) == :gt, do: a, else: b
  end

  # El corte fresco alineado a la hora: los buckets >= este instante se
  # leen de request_logs. Alinear evita el solape/descubrimiento del bucket
  # que contiene el corte cuando éste cae a media hora.
  defp tail_floor do
    DateTime.add(DateTime.utc_now(), -@tail_hours * 3600, :second) |> floor_hour()
  end

  defp floor_hour(%DateTime{} = dt),
    do: %{dt | minute: 0, second: 0, microsecond: {0, 0}}

  defp ceil_hour(%DateTime{} = dt) do
    floored = floor_hour(dt)

    if DateTime.compare(floored, dt) == :eq,
      do: floored,
      else: DateTime.add(floored, 3600, :second)
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

  # Los breakdowns híbridos parten la ventana en el MISMO corte alineado a
  # la hora que el summary: el rollup responde [from, tail_floor) con
  # buckets completos (semántica `<`) y el crudo [tail_floor, to]. El corte
  # anterior era al segundo (`tail_from/0`): el bucket que contiene el corte
  # quedaba a caballo de los dos lados — contado doble o descubierto según
  # `<=`/`<` — y un arranque de ventana a media hora perdía su bucket
  # parcial en el lado rollup.
  defp rollup_breakdown(:model, opts) do
    Rollup.breakdown_by_model_from_rollup(
      from: ceil_hour(Keyword.fetch!(opts, :from)),
      to: tail_floor()
    )
  end

  defp rollup_breakdown(:member, opts) do
    Rollup.breakdown_by_member_from_rollup(
      from: ceil_hour(Keyword.fetch!(opts, :from)),
      to: tail_floor(),
      member_ids: opts[:member_ids]
    )
  end

  defp rollup_breakdown(:group, opts) do
    Rollup.breakdown_by_group_from_rollup(
      from: ceil_hour(Keyword.fetch!(opts, :from)),
      to: tail_floor(),
      member_ids: opts[:member_ids]
    )
  end

  defp rollup_hour_counts(opts) do
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    from(m in Tokengate.Metrics.RequestMetricsHourly,
      where: m.hour_utc >= ^Keyword.fetch!(opts, :from) and m.hour_utc < ^tail_floor(),
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

  defp raw_breakdown(kind, group_id, opts) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.get(opts, :to)
    rollup_from = ceil_hour(from)

    # Mismo particionado que el summary: bucket parcial inicial crudo +
    # cola desde el corte alineado. En ventanas cortas el tramo rollup
    # queda vacío y los crudos se reparten la ventana completa.
    start_rows =
      if DateTime.compare(rollup_from, from) == :gt do
        edge_to = min_dt(DateTime.add(rollup_from, -1, :second), to)
        raw_breakdown_query(kind, group_id, opts, from, edge_to)
      else
        []
      end

    tail_rows =
      raw_breakdown_query(kind, group_id, opts, max_dt(tail_floor(), rollup_from), to)

    merge_rows(start_rows, tail_rows)
  end

  defp raw_breakdown_query(:model, group_id, opts, from, to) do
    Rollup.breakdown_by_model(group_id, Keyword.merge(opts, from: from, to: to))
  end

  defp raw_breakdown_query(:member, group_id, opts, from, to) do
    Rollup.breakdown_by_member(group_id, Keyword.merge(opts, from: from, to: to))
  end

  defp raw_breakdown_query(:group, _group_id, opts, from, to) do
    Rollup.breakdown_by_group(Keyword.merge(opts, from: from, to: to))
  end

  defp tail_hour_counts(opts) do
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    from(rl in RequestLog,
      where: rl.inserted_at >= ^tail_floor(),
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
  # `total_latency_ms` via Map.get: la cara cruda (`Logs.cost_summary/1`)
  # no lo devuelve — sin él, el avg_tps combinado perdía la latencia del
  # tramo crudo y el KPI quedaba sesgado.
  defp merge_summaries(a, b) do
    %{
      total_cost_usd: Decimal.add(a.total_cost_usd, b.total_cost_usd),
      total_prompt_tokens: a.total_prompt_tokens + b.total_prompt_tokens,
      total_completion_tokens: a.total_completion_tokens + b.total_completion_tokens,
      total_cache_read_tokens: a.total_cache_read_tokens + b.total_cache_read_tokens,
      total_cache_creation_tokens: a.total_cache_creation_tokens + b.total_cache_creation_tokens,
      request_count: a.request_count + b.request_count,
      total_latency_ms:
        (Map.get(a, :total_latency_ms) || 0) + (Map.get(b, :total_latency_ms) || 0),
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
