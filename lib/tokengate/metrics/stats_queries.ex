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
  `breakdown_by_user`, `breakdown_by_model_and_member`,
  `usage_by_hour_of_day`. Aggregates keyed on `service_id`, `status_code` or
  sub-hour buckets have no rollup counterpart and stay raw (callers keep
  using `Tokengate.Metrics.Rollup` / `Tokengate.Logs` directly for those).
  """

  import Ecto.Query, warn: false

  alias Tokengate.Accounts.GroupMember
  alias Tokengate.Accounts.User
  alias Tokengate.Logs
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Metrics.RequestMetricsHourly
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Providers.Model
  alias Tokengate.Providers.Provider
  alias Tokengate.Repo

  # Same budget the heavy reads in `Rollup` get (same env key): the overview
  # cards scan whole windows cold in production.
  @stats_query_timeout 120_000

  defp stats_query_timeout,
    do: Application.get_env(:tokengate, :stats_query_timeout_ms, @stats_query_timeout)

  # Same refresh window the RollupWorker re-aggregates every tick — anything
  # older is immutable in practice (request_logs is append-only).
  @tail_hours 3

  # TTL of the rollup-coverage verdict. The span it describes is CLOSED and
  # `request_logs` is append-only, so the only thing that can change the
  # answer mid-TTL is someone repairing the rollup (backfill). 60s keeps that
  # window short while removing the repeated COUNT from every viewer's read —
  # see `rollup_trusted?/4`.
  @guard_cache_ttl_ms 60_000

  # ---------------------------------------------------------------------
  # Summary
  # ---------------------------------------------------------------------

  @doc """
  Period summary (the KPI card numbers): request count, cost, tokens,
  `:error_count`, `:avg_latency_ms`, `:avg_ttft_ms` and `:avg_tps`. Accepts the
  same filter map as `Logs.cost_summary/1`
  (`:from`/`:to`/`:model_id`/`:group_id`/`:service_id`/`:member_ids`/
  `:group_member_ids`) or the equivalent keyword list; extra filter keys
  are passed through to the raw side untouched.

  In the hybrid path the two halves are merged field by field
  (`merge_summaries/2`): counters are summed and every derived value is
  recomputed from the summed inputs, so no half's errors, latency or
  throughput can be dropped by the split.
  """
  def summary(filters \\ []) do
    filters = normalize_filters(filters) |> Logs.ensure_window!("StatsQueries.summary/1")

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

      rollup_summary =
        Rollup.summary_from_rollup(
          member_ids: filters[:member_ids] || filters[:group_member_ids],
          user_ids: filters[:user_ids],
          model_id: filters[:model_id],
          provider_id: filters[:provider_id],
          from: rollup_from,
          to: bound
        )

      # Coverage guard: an empty/behind rollup half must NOT answer as "the
      # period had almost no traffic" — fall back to the full raw window.
      # See `rollup_trusted?/3`.
      if rollup_trusted?(filters, rollup_from, bound, rollup_summary.request_count) do
        parts = [rollup_summary | raw_edge_summaries(filters, from, rollup_from, bound, to)]
        Enum.reduce(parts, &merge_summaries/2)
      else
        raw_summary(filters)
      end
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
      hybrid_breakdown(:model, group_id, opts)
    else
      Rollup.breakdown_by_model(group_id, opts)
    end
  end

  @doc "Per-member breakdown. Same row shape as `Rollup.breakdown_by_member/2`."
  def breakdown_by_member(group_id \\ nil, opts \\ []) do
    if hybrid?(opts) and is_nil(group_id) do
      hybrid_breakdown(:member, group_id, opts)
    else
      Rollup.breakdown_by_member(group_id, opts)
    end
  end

  @doc "Per-group breakdown. Same row shape as `Rollup.breakdown_by_group/1`."
  def breakdown_by_group(opts \\ []) do
    if hybrid?(opts) do
      hybrid_breakdown(:group, nil, opts)
    else
      Rollup.breakdown_by_group(opts)
    end
  end

  @doc """
  Per-user breakdown. Same row shape as `Rollup.breakdown_by_user/1`.

  Attribution is the DURABLE `user_id` column of the bucket (the rollup keeps
  it when the membership is let go), so a member turnover — the old
  `group_member` deleted, a new one created for the same user — still answers
  with one row per user carrying the whole window. `memberships`/`groups` are
  rebuilt from the union of live memberships seen on each half, matching the
  raw aggregation over the full window.
  """
  def breakdown_by_user(opts \\ []) do
    if hybrid?(opts) do
      {from, to} = rollup_window(opts)

      if rollup_trusted?(opts, from, to) do
        merge_user_rows(rollup_by_user_rows(opts), raw_user_edges(opts))
      else
        # Rollup without coverage for the closed part: the WHOLE window raw,
        # never just the ≤3h tail (that is the "figures collapse to almost
        # nothing" failure the guard exists for).
        raw_by_user_rows(opts, Keyword.fetch!(opts, :from), Keyword.get(opts, :to))
      end
    else
      Rollup.breakdown_by_user(opts)
    end
  end

  @doc """
  Model + member breakdowns from ONE grouped read per half (rollup + tail) —
  the dashboard's per-viewer batch. Returns `{model_rows, member_rows}` with
  exactly the shapes of `breakdown_by_model/2` and `breakdown_by_member/2`.

  Only used with a NON-EMPTY `:user_ids` scope (the dashboard's shape): the
  shared rows are grouped per (user, membership, group, model) and pivoted in
  the BEAM, so a pure user scope is required — without it the pivot would have
  to carry service traffic too and the member half would not match its raw
  counterpart.
  """
  def breakdown_by_model_and_member(opts \\ []) do
    user_ids = Keyword.get(opts, :user_ids)

    cond do
      not is_list(user_ids) or user_ids == [] ->
        {breakdown_by_model(nil, opts), breakdown_by_member(nil, opts)}

      hybrid?(opts) ->
        {from, to} = rollup_window(opts)

        if rollup_trusted?(opts, from, to) do
          model_and_member_rows(rollup_model_member_rows(opts) ++ raw_model_member_edges(opts))
        else
          opts
          |> raw_model_member_rows(Keyword.fetch!(opts, :from), Keyword.get(opts, :to))
          |> model_and_member_rows()
        end

      true ->
        {breakdown_by_model(nil, opts), breakdown_by_member(nil, opts)}
    end
  end

  @doc "24h UTC hour-of-day distribution. Same shape as `Rollup.usage_by_hour_of_day/2`."
  def usage_by_hour_of_day(group_id \\ nil, opts \\ []) do
    if hybrid?(opts) and is_nil(group_id) do
      if coverage_ok?(opts) do
        counts =
          Enum.reduce(rollup_hour_counts(opts) ++ tail_hour_counts(opts), %{}, fn {hour, n},
                                                                                  acc ->
            Map.update(acc, hour, n, &(&1 + n))
          end)

        for hour <- 0..23 do
          %{hour: hour, request_count: Map.get(counts, hour, 0)}
        end
      else
        Rollup.usage_by_hour_of_day(group_id, opts)
      end
    else
      Rollup.usage_by_hour_of_day(group_id, opts)
    end
  end

  @doc """
  Perfil hora × proveedor del período. Same shape as
  `Rollup.usage_by_hour_of_day_by_provider/1`.

  Hybrid: the rollup answers the hour buckets (dims `hour_utc` + `provider_id`
  are both in the rollup) and only the fresh tail is raw — in production this
  turns a multi-million-row month scan into a few thousand rollup rows. The
  chart goes through the coverage guard (see `rollup_trusted?/4`): with a
  rollup gap it answers the WHOLE window raw, so a chart can never draw a
  smaller total than the KPI card next to it.
  """
  def usage_by_hour_of_day_by_provider(opts \\ []) do
    cond do
      not hybrid?(opts) ->
        Rollup.usage_by_hour_of_day_by_provider(opts)

      not coverage_ok?(opts) ->
        Rollup.usage_by_hour_of_day_by_provider(opts)

      true ->
        Rollup.hour_provider_profile(
          rollup_hour_provider_rows(opts) ++ tail_hour_provider_rows(opts)
        )
    end
  end

  @doc """
  Gráfica apilada modelo × proveedor. Same shape as
  `Rollup.usage_by_model_provider_stacked/1`. Hybrid — see
  `usage_by_hour_of_day_by_provider/1`, guard included.
  """
  def usage_by_model_provider_stacked(opts \\ []) do
    stacked_opts = Keyword.take(opts, [:sort_by, :limit])

    cond do
      not hybrid?(opts) ->
        Rollup.usage_by_model_provider_stacked(opts)

      not coverage_ok?(opts) ->
        Rollup.usage_by_model_provider_stacked(opts)

      true ->
        rollup_rows = opts |> rollup_model_provider_rows() |> model_provider_names()
        tail_rows = tail_model_provider_rows(opts)

        Rollup.model_provider_stacked(merge_flat_rows(rollup_rows, tail_rows), stacked_opts)
    end
  end

  @doc """
  Serie diaria por proveedor del período (`Rollup.daily_series_by_provider/1`),
  híbrida sobre `request_metrics_hourly` + bordes crudos.
  """
  def daily_series_by_provider(opts \\ []) do
    cond do
      not hybrid?(opts) ->
        Rollup.daily_series_by_provider(opts)

      not coverage_ok?(opts) ->
        Rollup.daily_series_by_provider(opts)

      true ->
        from = Keyword.fetch!(opts, :from)
        to = Keyword.get(opts, :to)
        {rollup_from, rollup_to} = rollup_window(opts)

        rollup_rows =
          if DateTime.compare(rollup_to, rollup_from) == :gt do
            Rollup.daily_series_by_provider_from_rollup(
              Keyword.merge(opts, from: rollup_from, to: rollup_to)
            )
          else
            []
          end

        start_rows =
          if DateTime.compare(rollup_from, from) == :gt do
            edge_to = min_dt(DateTime.add(rollup_from, -1, :second), to)
            Rollup.daily_series_by_provider(Keyword.merge(opts, from: from, to: edge_to))
          else
            []
          end

        tail_rows =
          Rollup.daily_series_by_provider(Keyword.merge(opts, from: raw_tail_start(opts), to: to))

        merge_daily_provider_rows(rollup_rows ++ start_rows ++ tail_rows)
    end
  end

  defp merge_daily_provider_rows(rows) do
    rows
    |> Enum.group_by(&{&1.date, &1.provider_id, &1.label})
    |> Enum.map(fn {{date, provider_id, label}, entries} ->
      %{
        date: date,
        provider_id: provider_id,
        label: label,
        label_logo: Enum.find_value(entries, & &1.label_logo),
        request_count: Enum.reduce(entries, 0, &(&1.request_count + &2)),
        total_cost_usd:
          Enum.reduce(entries, Decimal.new(0), fn e, acc ->
            Decimal.add(acc, e.total_cost_usd)
          end),
        prompt_tokens: Enum.reduce(entries, 0, &(&1.prompt_tokens + &2)),
        completion_tokens: Enum.reduce(entries, 0, &(&1.completion_tokens + &2)),
        error_count: Enum.reduce(entries, 0, &((&1.error_count || 0) + &2))
      }
    end)
    |> Enum.sort_by(&{&1.date, &1.label})
  end

  @doc "Top N horas con más requests o costo. Same shape as `Rollup.busiest_hours/2`."
  def busiest_hours(group_id \\ nil, opts \\ [])

  def busiest_hours(group_id, opts) when not is_nil(group_id),
    do: Rollup.busiest_hours(group_id, opts)

  def busiest_hours(nil, opts) do
    cond do
      not hybrid?(opts) ->
        Rollup.busiest_hours(nil, opts)

      # El bucket local del rollup es el bucket UTC: sólo coincide con la
      # hora local cuando el offset de la zona es de horas enteras (LatAm,
      # Europa). Con offsets :30/:45 la respuesta exacta exige el crudo.
      not whole_hour_zone?(opts) ->
        Rollup.busiest_hours(nil, opts)

      # Mismo guard que el resto de las gráficas híbridas: con un hueco en el
      # rollup el top saldría subcontado en silencio.
      not coverage_ok?(opts) ->
        Rollup.busiest_hours(nil, opts)

      true ->
        # Rollup: buckets UTC enteros → key = instante (para zonas de hora
        # entera el bucket UTC ES la hora local). Cola cruda: el mismo
        # date_trunc local del lado completo, que aterriza en el mismo
        # instante. Merge aditivo por key y top-N en memoria.
        counts =
          Enum.reduce(tail_hour_buckets(opts), rollup_hour_buckets(opts), fn {bucket, vals},
                                                                             acc ->
            Map.update(acc, bucket, vals, fn cur ->
              %{
                request_count: cur.request_count + vals.request_count,
                cost_usd: Decimal.add(cur.cost_usd, vals.cost_usd)
              }
            end)
          end)

        limit = Keyword.get(opts, :limit, 5)
        metric = Keyword.get(opts, :metric, :requests)

        # Tie-break: on equal cost/count the EARLIER bucket wins, so the top-N
        # is deterministic run to run. The old `:cost` branch compared a
        # transposed tuple (`{v1.request_count, b2} >= {v2.request_count, b1}`),
        # i.e. count ascending against a bucket from the OTHER row — neither
        # antisymmetric nor stable, so the chart could reshuffle between two
        # identical reads.
        sorted =
          case metric do
            :cost ->
              Enum.sort(counts, fn {b1, v1}, {b2, v2} ->
                case Decimal.compare(v1.cost_usd, v2.cost_usd) do
                  :eq -> {-v1.request_count, b1} <= {-v2.request_count, b2}
                  order -> order == :gt
                end
              end)

            _ ->
              Enum.sort_by(counts, fn {bucket, vals} -> {-vals.request_count, bucket} end)
          end

        sorted
        |> Enum.take(limit)
        |> Enum.map(fn {bucket, vals} ->
          %{bucket: bucket, request_count: vals.request_count, cost_usd: vals.cost_usd}
        end)
    end
  end

  # Coverage verdict for the closed span of a hybrid read — one call site per
  # aggregate, cached per (scope, span) inside `rollup_trusted?/4`.
  defp coverage_ok?(opts) do
    {from, to} = rollup_window(opts)
    rollup_trusted?(opts, from, to)
  end

  # El offset de la zona en `from` y en el corte del rollup debe ser de
  # horas enteras (un DST que cae dentro de la ventana mueve el offset, no
  # lo vuelve fraccionario — se revisa en ambos extremos).
  defp whole_hour_zone?(opts) do
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    from = Keyword.fetch!(opts, :from)

    Enum.all?([from, tail_floor()], fn instant ->
      shifted = DateTime.shift_zone!(instant, timezone)
      rem(DateTime.diff(shifted, DateTime.shift_zone!(instant, "Etc/UTC")), 3600) == 0
    end)
  end

  # Suma filas planas idénticas ({model_id, provider_stats_id}) — rollup y
  # cola cruda pueden traer la misma pareja. `Enum.group_by` + un reduce por
  # grupo: O(n) en lugar del `Enum.find_index` + `List.update_at` (O(n²) con
  # una lista que además se reconstruía entera en cada fila de la cola).
  defp merge_flat_rows(rollup_rows, tail_rows) do
    (rollup_rows ++ tail_rows)
    |> Enum.group_by(&{&1.model_id, &1.provider_stats_id})
    |> Enum.map(fn {_key, [row | rest]} ->
      Enum.reduce(rest, row, fn other, acc ->
        %{
          acc
          | request_count: acc.request_count + other.request_count,
            cost_usd: Decimal.add(acc.cost_usd, other.cost_usd)
        }
      end)
    end)
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
  # Same time partition as `summary/2` for every hybrid aggregate. In a closed
  # window (last month, previous period) the cutoff MUST honor its `to`: the
  # fresh-tail floor alone would fold current-month rollup buckets into an old
  # month, while the raw tail would (correctly) return empty and not catch it.
  defp rollup_window(opts) do
    {ceil_hour(Keyword.fetch!(opts, :from)), rollup_bound(Keyword.get(opts, :to))}
  end

  defp raw_tail_start(opts) do
    {rollup_from, rollup_to} = rollup_window(opts)
    max_dt(rollup_to, rollup_from)
  end

  defp rollup_breakdown(:model, opts) do
    {from, to} = rollup_window(opts)

    Rollup.breakdown_by_model_from_rollup(
      from: from,
      to: to,
      # Member scope is a rollup column (`group_member_id`) and the raw half
      # filters on it too — dropping it here made a member-scoped viewer see
      # org-wide model rows on the closed part of the window.
      member_ids: opts[:member_ids],
      user_ids: opts[:user_ids],
      model_id: opts[:model_id],
      provider_id: opts[:provider_id]
    )
  end

  defp rollup_breakdown(:member, opts) do
    {from, to} = rollup_window(opts)

    Rollup.breakdown_by_member_from_rollup(
      from: from,
      to: to,
      member_ids: opts[:member_ids],
      user_ids: opts[:user_ids],
      model_id: opts[:model_id],
      provider_id: opts[:provider_id]
    )
  end

  defp rollup_breakdown(:group, opts) do
    {from, to} = rollup_window(opts)

    Rollup.breakdown_by_group_from_rollup(
      from: from,
      to: to,
      member_ids: opts[:member_ids],
      user_ids: opts[:user_ids],
      model_id: opts[:model_id],
      provider_id: opts[:provider_id]
    )
  end

  # ---------------------------------------------------------------------
  # Per-user reads (hybrid: rollup closed buckets + raw tail)
  # ---------------------------------------------------------------------

  # Rollup half of `breakdown_by_user/1`. Mirrors `Rollup.breakdown_by_user/1`
  # exactly — the durable identity is the bucket's own `user_id` column, the
  # membership context is LEFT joined (a rotated membership leaves the bucket
  # alive with a NULL `group_member_id`), and `membership_ids`/`group_ids` ride
  # along so the tail merge can rebuild `memberships`/`groups` as the UNION
  # seen over the whole window instead of approximating with a max.
  defp rollup_by_user_rows(opts) do
    {from, to} = rollup_window(opts)

    from(m in RequestMetricsHourly,
      where: m.hour_utc >= ^from and m.hour_utc < ^to,
      left_join: tm in GroupMember,
      on: m.group_member_id == tm.id,
      as: :member,
      left_join: u in User,
      on: m.user_id == u.id,
      as: :user,
      where: not is_nil(u.id),
      group_by: [m.user_id, u.id],
      select: %{
        user_id: u.id,
        user_name: u.name,
        user_email: u.email,
        membership_ids: fragment("ARRAY_AGG(DISTINCT ?::text)", tm.id),
        group_ids: fragment("ARRAY_AGG(DISTINCT ?::text)", tm.group_id),
        request_count: fragment("COALESCE(SUM(?), 0)::bigint", m.request_count),
        error_count: fragment("COALESCE(SUM(?), 0)::bigint", m.error_count),
        cost_usd_raw: fragment("COALESCE(SUM(?), 0)::bigint", m.cost_micro),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.cache_read_tokens),
        cache_creation_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.cache_creation_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)::bigint", m.total_latency_ms)
      }
    )
    |> rollup_day_bounds(from, to)
    |> maybe_rollup_scope(opts)
    |> Repo.all(timeout: stats_query_timeout())
    |> Enum.map(&by_user_row/1)
  end

  # Raw side of `breakdown_by_user/1`: a copy of `Rollup.breakdown_by_user/1`
  # bounded to the arm being read. It is duplicated here on purpose (rollup
  # module is not ours to change) — if `Rollup.breakdown_by_user/1` gains or
  # renames a dimension, this must follow, and the parity test in
  # `stats_queries_test.exs` is what catches the drift: it asserts the hybrid
  # result equals the raw aggregation over the same window.
  #
  # `subject_type = 'user'` mirrors `Rollup.breakdown_by_user/1`: a SERVICE row
  # can carry `user_id` (attribution/top-ups populate it), and without the
  # filter the user ranking summed service traffic — and drifted from
  # `breakdown_by_service/1` by exactly the rows that carry both ids.
  defp raw_by_user_rows(opts, from, to) do
    RequestLog
    |> where([rl], rl.subject_type == "user")
    |> where([rl], rl.inserted_at >= ^from)
    |> maybe_to(to)
    |> maybe_member_ids(opts[:member_ids])
    |> maybe_user_ids(opts[:user_ids])
    |> maybe_provider_id(opts[:provider_id])
    |> join(:left, [rl], tm in GroupMember, on: rl.group_member_id == tm.id, as: :member)
    |> join(:left, [rl], u in User, on: rl.user_id == u.id, as: :user)
    |> where([user: u], not is_nil(u.id))
    |> group_by([user: u], u.id)
    |> select([rl, user: u, member: tm], %{
      user_id: u.id,
      user_name: u.name,
      user_email: u.email,
      membership_ids: fragment("ARRAY_AGG(DISTINCT ?::text)", tm.id),
      group_ids: fragment("ARRAY_AGG(DISTINCT ?::text)", tm.group_id),
      request_count: count(rl.id),
      error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
      cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
      prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
      completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
      cache_read_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_read_tokens),
      cache_creation_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_creation_tokens),
      total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
    })
    |> Repo.all(timeout: stats_query_timeout())
    |> Enum.map(fn row ->
      %{
        user_id: row.user_id,
        user_name: row.user_name,
        user_email: row.user_email,
        membership_ids: row.membership_ids,
        group_ids: row.group_ids,
        request_count: row.request_count,
        error_count: row.error_count || 0,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        cache_read_tokens: row.cache_read_tokens,
        cache_creation_tokens: row.cache_creation_tokens,
        total_latency_ms: row.total_latency_ms
      }
    end)
  end

  defp by_user_row(row) do
    %{
      user_id: row.user_id,
      user_name: row.user_name,
      user_email: row.user_email,
      membership_ids: row.membership_ids,
      group_ids: row.group_ids,
      request_count: row.request_count,
      error_count: row.error_count || 0,
      cost_usd: micro_to_decimal(row.cost_usd_raw),
      prompt_tokens: row.prompt_tokens,
      completion_tokens: row.completion_tokens,
      cache_read_tokens: row.cache_read_tokens,
      cache_creation_tokens: row.cache_creation_tokens,
      total_latency_ms: row.total_latency_ms
    }
  end

  # Raw arms of the per-user hybrid: the partial first hour (when `from` is
  # not hour-aligned) plus everything from the rollup's end of window. Same
  # partition as `raw_breakdown/3`.
  defp raw_user_edges(opts) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.get(opts, :to)
    rollup_from = ceil_hour(from)

    start_rows =
      if DateTime.compare(rollup_from, from) == :gt do
        edge_to = min_dt(DateTime.add(rollup_from, -1, :second), to)
        raw_by_user_rows(opts, from, edge_to)
      else
        []
      end

    start_rows ++ raw_by_user_rows(opts, raw_tail_start(opts), to)
  end

  # Merges the two halves per user: additive counters summed, `memberships`
  # and `groups` rebuilt from the union of the live memberships each half saw.
  defp merge_user_rows(rollup_rows, raw_rows) do
    rows = rollup_rows ++ raw_rows
    # Labels are resolved ONCE per read (never per row) and not at all for an
    # empty window — an empty period used to pay a `groups` query whose result
    # was never printed.
    group_names = if rows == [], do: %{}, else: Tokengate.Accounts.group_names_by_id()

    rows
    |> Enum.group_by(& &1.user_id)
    |> Enum.map(fn {_user_id, [first | rest]} ->
      member_ids = union_ids([first | rest], :membership_ids)
      group_ids = union_ids([first | rest], :group_ids)

      merged = Enum.reduce(rest, first, &sum_row/2)

      %{
        user_id: merged.user_id,
        user_name: merged.user_name,
        user_email: merged.user_email,
        memberships: length(member_ids),
        groups:
          group_ids
          |> Enum.map(&%{id: &1, name: Map.get(group_names, &1, "—")})
          |> Enum.sort_by(& &1.name),
        request_count: merged.request_count,
        error_count: Map.get(merged, :error_count, 0),
        cost_usd: merged.cost_usd,
        prompt_tokens: merged.prompt_tokens,
        completion_tokens: merged.completion_tokens,
        cache_read_tokens: Map.get(merged, :cache_read_tokens, 0),
        cache_creation_tokens: Map.get(merged, :cache_creation_tokens, 0),
        # A single-row group never went through `sum_row/2`, so derive the
        # ratio here (same formula) instead of reading a missing key.
        avg_tps: compute_tps(merged.completion_tokens, merged[:total_latency_ms] || 0)
      }
    end)
    |> sort_by_cost()
  end

  defp union_ids(rows, key) do
    rows
    |> Enum.flat_map(&(Map.get(&1, key) || []))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # ---------------------------------------------------------------------
  # Model + member batch (dashboard): ONE grouped read per half
  # ---------------------------------------------------------------------

  # Flat rows keyed by (user, membership, group, model). Both the per-model and
  # the per-member tables are pivots of this SAME result, so the dashboard pays
  # one scan per half instead of two.
  #
  # TWO passes over two very different row counts: the aggregate runs on the
  # bucket columns alone (`user_id`, `group_member_id`, `model_id`) and the
  # joins that turn those ids into names are applied to its OUTPUT. Grouping by
  # `u.id`/`tm.id`/`t.id`/`ma.id` (both sides of every join) instead made the
  # planner hash-join the whole window before aggregating, and the six-uuid
  # sort key spilled to disk — `Sort Method: external merge  Disk: 17432kB`
  # for 125 output rows, over half the query's time. The names cannot ride in
  # the first pass either: a `MAX()` on them still joins every input row.
  # Measured (2M logs, 25 users): 210 → 79 ms over 7 days and 6.7 → 4.9 ms in
  # the 3h window this reader actually asks for.
  #
  # The outer GROUP BY is deliberate, not redundant: `request_metrics_hourly`
  # has NO foreign key on `group_member_id` (unlike `request_logs`, whose FK is
  # `ON DELETE SET NULL`), so a rollup bucket keeps the id of a membership that
  # no longer exists. Skipping the aggregate would hand the pivots N rows that
  # all resolve to the same NULL membership instead of the one row the single
  # GROUP BY produced.
  defp rollup_model_member_rows(opts) do
    {from, to} = rollup_window(opts)

    buckets =
      from(m in RequestMetricsHourly,
        where: m.hour_utc >= ^from and m.hour_utc < ^to,
        group_by: [m.user_id, m.group_member_id, m.model_id],
        select: %{
          user_id: m.user_id,
          group_member_id: m.group_member_id,
          model_id: m.model_id,
          request_count: fragment("COALESCE(SUM(?), 0)::bigint", m.request_count),
          cost_usd_raw: fragment("COALESCE(SUM(?), 0)::bigint", m.cost_micro),
          prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.prompt_tokens),
          completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.completion_tokens),
          cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.cache_read_tokens),
          total_latency_ms: fragment("COALESCE(SUM(?), 0)::bigint", m.total_latency_ms)
        }
      )
      |> rollup_day_bounds(from, to)
      |> maybe_rollup_scope(opts)
      |> subquery()

    from(b in buckets,
      left_join: ma in Model,
      on: b.model_id == ma.id,
      as: :model,
      left_join: u in User,
      on: b.user_id == u.id,
      as: :user,
      left_join: tm in GroupMember,
      on: b.group_member_id == tm.id,
      as: :member,
      left_join: t in assoc(tm, :group),
      as: :group,
      group_by: [b.user_id, u.id, tm.id, t.id, ma.id],
      select: %{
        user_id: b.user_id,
        user_email: u.email,
        group_member_id: tm.id,
        group_name: t.name,
        model_id: ma.id,
        model_name: ma.name,
        request_count: fragment("COALESCE(SUM(?), 0)::bigint", b.request_count),
        cost_usd_raw: fragment("COALESCE(SUM(?), 0)::bigint", b.cost_usd_raw),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", b.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", b.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", b.cache_read_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)::bigint", b.total_latency_ms)
      }
    )
    |> Repo.all(timeout: stats_query_timeout())
    |> Enum.map(fn row -> Map.put(row, :cost_usd, micro_to_decimal(row.cost_usd_raw)) end)
  end

  defp raw_model_member_rows(opts, from, to) do
    # Same two-pass shape as `rollup_model_member_rows/1`; the names are joined
    # onto the aggregate instead of into it.
    buckets =
      RequestLog
      |> where([rl], rl.inserted_at >= ^from)
      |> maybe_to(to)
      |> maybe_member_ids(opts[:member_ids])
      |> maybe_user_ids(opts[:user_ids])
      |> maybe_provider_id(opts[:provider_id])
      |> group_by([rl], [rl.user_id, rl.group_member_id, rl.model_id])
      |> select([rl], %{
        user_id: rl.user_id,
        group_member_id: rl.group_member_id,
        model_id: rl.model_id,
        request_count: count(),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_read_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })
      |> subquery()

    from(b in buckets,
      left_join: ma in Model,
      on: b.model_id == ma.id,
      as: :model,
      left_join: u in User,
      on: b.user_id == u.id,
      as: :user,
      left_join: tm in GroupMember,
      on: b.group_member_id == tm.id,
      as: :member,
      left_join: t in assoc(tm, :group),
      as: :group,
      group_by: [b.user_id, u.id, tm.id, t.id, ma.id],
      select: %{
        user_id: b.user_id,
        user_email: u.email,
        group_member_id: tm.id,
        group_name: t.name,
        model_id: ma.id,
        model_name: ma.name,
        request_count: fragment("COALESCE(SUM(?), 0)::bigint", b.request_count),
        cost_usd: fragment("COALESCE(SUM(?), 0)", b.cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", b.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", b.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", b.cache_read_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)::bigint", b.total_latency_ms)
      }
    )
    |> Repo.all(timeout: stats_query_timeout())
    |> Enum.map(fn row -> Map.put(row, :cost_usd, Decimal.new(to_string(row.cost_usd))) end)
  end

  defp raw_model_member_edges(opts) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.get(opts, :to)
    rollup_from = ceil_hour(from)

    start_rows =
      if DateTime.compare(rollup_from, from) == :gt do
        edge_to = min_dt(DateTime.add(rollup_from, -1, :second), to)
        raw_model_member_rows(opts, from, edge_to)
      else
        []
      end

    start_rows ++ raw_model_member_rows(opts, raw_tail_start(opts), to)
  end

  defp model_and_member_rows(flat_rows) do
    {model_rows(flat_rows), member_rows(flat_rows)}
  end

  defp model_rows(flat_rows) do
    flat_rows
    |> Enum.group_by(& &1.model_id)
    |> Enum.map(fn {model_id, rows} ->
      agg = aggregate_flat(rows)
      [first | _] = rows

      %{
        model_id: model_id,
        model_name: first.model_name || "—",
        request_count: agg.request_count,
        cost_usd: agg.cost_usd,
        prompt_tokens: agg.prompt_tokens,
        completion_tokens: agg.completion_tokens,
        cache_read_tokens: agg.cache_read_tokens,
        avg_tps: compute_tps(agg.completion_tokens, agg.total_latency_ms)
      }
    end)
    |> sort_by_cost()
  end

  # Member rows follow `Rollup.breakdown_by_member/1`: one row per
  # (user, live membership, group) and only rows whose user still resolves
  # (the raw aggregation joins the user table, so a deleted user's traffic is
  # absent from the member table even though it stays in the model table).
  defp member_rows(flat_rows) do
    flat_rows
    |> Enum.reject(&is_nil(&1.user_email))
    |> Enum.group_by(&{&1.user_id, &1.group_member_id, &1.group_name})
    |> Enum.map(fn {_identity, rows} ->
      agg = aggregate_flat(rows)
      [first | _] = rows

      %{
        group_member_id: first.group_member_id,
        user_id: first.user_id,
        group_name: first.group_name,
        user_email: first.user_email,
        request_count: agg.request_count,
        cost_usd: agg.cost_usd,
        prompt_tokens: agg.prompt_tokens,
        completion_tokens: agg.completion_tokens,
        cache_read_tokens: agg.cache_read_tokens,
        avg_tps: compute_tps(agg.completion_tokens, agg.total_latency_ms)
      }
    end)
    |> sort_by_cost()
  end

  defp aggregate_flat(rows) do
    Enum.reduce(
      rows,
      %{
        request_count: 0,
        cost_usd: Decimal.new(0),
        prompt_tokens: 0,
        completion_tokens: 0,
        cache_read_tokens: 0,
        total_latency_ms: 0
      },
      fn row, acc ->
        %{
          request_count: acc.request_count + row.request_count,
          cost_usd: Decimal.add(acc.cost_usd, row.cost_usd),
          prompt_tokens: acc.prompt_tokens + (row.prompt_tokens || 0),
          completion_tokens: acc.completion_tokens + (row.completion_tokens || 0),
          cache_read_tokens: acc.cache_read_tokens + (row.cache_read_tokens || 0),
          total_latency_ms: acc.total_latency_ms + (row.total_latency_ms || 0)
        }
      end
    )
  end

  defp rollup_hour_counts(opts) do
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    {from, to} = rollup_window(opts)

    from(m in Tokengate.Metrics.RequestMetricsHourly,
      where: m.hour_utc >= ^from and m.hour_utc < ^to,
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
    |> rollup_day_bounds(from, to)
    |> maybe_rollup_scope(opts)
    |> Repo.all(timeout: stats_query_timeout())
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
      raw_breakdown_query(kind, group_id, opts, raw_tail_start(opts), to)

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

  # Hybrid read for one breakdown kind with the ROLLUP-COVERAGE GUARD: the
  # rollup half is only merged when it actually covers the closed part of the
  # window. Without the guard an empty/behind rollup (fresh deploy before
  # `mix tokengate.rollup.backfill`, or a worker down >3h — its re-aggregation
  # only reaches 3h back, so the gap is permanent) silently answers with the
  # ≤3h tail only, i.e. figures that "collapsed to nothing" with no error.
  defp hybrid_breakdown(kind, group_id, opts) do
    {from, to} = rollup_window(opts)

    # Guard FIRST: the reconciliation is two small queries, while the rollup
    # aggregate is the heavy half. Running it only when the closed span is
    # provably covered avoids paying for a read whose result would be thrown
    # away on the fallback.
    if rollup_trusted?(opts, from, to) do
      merge_rows(rollup_breakdown(kind, opts), raw_breakdown(kind, group_id, opts))
    else
      # Full raw over the requested window — INCLUDING the tail — never just
      # the closed arms (that would double-count the tail rows).
      raw_breakdown_query(
        kind,
        group_id,
        opts,
        Keyword.fetch!(opts, :from),
        Keyword.get(opts, :to)
      )
    end
  end

  # ---------------------------------------------------------------------
  # Rollup coverage guard
  # ---------------------------------------------------------------------

  # Decides whether the rollup half of a hybrid read may be trusted for the
  # closed span `[rollup_from, rollup_to)` (both bounds hour-aligned, so the
  # raw rows and the rollup buckets cover the SAME instants).
  #
  # The check is an EXACT reconciliation, not a presence probe:
  #
  #     count(request_logs   in the closed span, same scope) ==
  #     sum(request_metrics_hourly.request_count in the same span)
  #
  # Equal counts mean every row of the closed span is aggregated, so the
  # rollup half + raw tail is the whole window. Any mismatch — empty rollup
  # (fresh deploy before the backfill), a worker down long enough that the gap
  # left its 3h re-aggregation window (permanent), an interior day a backfill
  # skipped, or rollup rows whose raw rows were dropped by retention — falls
  # back to the WHOLE window raw, which is exact by construction and cannot
  # double count (the tail is not merged on top).
  #
  # Cost: one COUNT over the closed span plus one SUM over the rollup span, per
  # hybrid read — memoized per (scope, closed span) for `@guard_cache_ttl_ms`.
  # The verdict only covers an already-closed, hour-aligned span of an
  # append-only table, so a second read of the same window in the same minute
  # is the same question with the same answer; two viewers or four graph cards
  # behind one bundle pay it once.
  #
  # Goal (A17): replace the COUNT by a watermark (`max(hour_utc)` of the
  # rollup) — O(1) instead of O(n) — once gap instrumentation exists. A
  # watermark alone cannot tell a partial interior gap from a covered hour,
  # which is why the exact reconciliation stays the source of truth for now.
  defp rollup_trusted?(opts, rollup_from, rollup_to, known_rollup_requests \\ nil) do
    if DateTime.compare(rollup_to, rollup_from) != :gt do
      true
    else
      key = guard_cache_key(opts, rollup_from, rollup_to)

      case cached_verdict(key) do
        {:ok, verdict} ->
          verdict

        :miss ->
          verdict = verify_coverage(opts, rollup_from, rollup_to, known_rollup_requests)
          cache_verdict(key, verdict)
          verdict
      end
    end
  end

  defp verify_coverage(opts, rollup_from, rollup_to, known_rollup_requests) do
    rollup_requests =
      known_rollup_requests || rollup_requests_between(opts, rollup_from, rollup_to)

    raw_rows_between?(opts, rollup_from, rollup_to) == rollup_requests
  end

  # Scope + closed span. Both bounds are hour-aligned absolute instants, so
  # the key rotates by itself as the window advances; the TTL bounds the key
  # space (two per hour per scope at most).
  defp guard_cache_key(opts, from, to) do
    {:stats_rollup_guard, guard_scope(opts), from, to}
  end

  defp guard_scope(opts) do
    {filter_value(opts, :member_ids) || filter_value(opts, :group_member_ids),
     filter_value(opts, :user_ids), filter_value(opts, :model_id),
     filter_value(opts, :provider_id)}
  end

  # Same switch the stats surface uses to disable its caches in the test env:
  # specs share one ETS table, so a verdict cached by one test must never
  # answer another.
  defp verdict_cache_enabled?,
    do: Application.get_env(:tokengate, :stats_structural_cache, enabled: true)[:enabled] != false

  defp cached_verdict(key) do
    if verdict_cache_enabled?() and DashboardCache.available?() do
      case DashboardCache.fetch(key) do
        {:ok, verdict} -> {:ok, verdict}
        :miss -> :miss
      end
    else
      :miss
    end
  end

  defp cache_verdict(key, verdict) do
    if verdict_cache_enabled?() and DashboardCache.available?() do
      DashboardCache.put(key, verdict, @guard_cache_ttl_ms)
    end

    verdict
  end

  defp raw_rows_between?(opts, from, to) do
    RequestLog
    |> where([rl], rl.inserted_at >= ^from and rl.inserted_at < ^to)
    |> maybe_guard_member_ids(opts)
    |> maybe_user_ids(filter_value(opts, :user_ids))
    |> maybe_guard_model_id(opts)
    |> maybe_guard_provider_id(opts)
    |> Repo.aggregate(:count, :id, timeout: stats_query_timeout())
  end

  defp rollup_requests_between(opts, from, to) do
    RequestMetricsHourly
    |> where([m], m.hour_utc >= ^from and m.hour_utc < ^to)
    |> rollup_day_bounds(from, to)
    |> maybe_rollup_scope(normalize_guard_scope(opts))
    |> select([m], %{n: fragment("COALESCE(SUM(?), 0)::bigint", m.request_count)})
    |> Repo.one(timeout: stats_query_timeout())
    |> case do
      nil -> 0
      %{n: n} -> n
    end
  end

  # `filter_value/2` reads the same key off the map form (`summary/1`) and the
  # keyword form (breakdowns). Member scope arrives as `:member_ids` on the
  # breakdowns and as `:group_member_ids` from `StatsLive.fetch_summary/2` —
  # both are the same rollup column, so the guard accepts either.
  defp filter_value(filters, key) when is_map(filters), do: Map.get(filters, key)
  defp filter_value(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp maybe_guard_member_ids(query, opts) do
    case filter_value(opts, :member_ids) || filter_value(opts, :group_member_ids) do
      nil -> query
      ids -> maybe_member_ids(query, ids)
    end
  end

  defp maybe_guard_model_id(query, opts) do
    case filter_value(opts, :model_id) do
      nil -> query
      model_id -> where(query, [rl], rl.model_id == ^model_id)
    end
  end

  defp maybe_guard_provider_id(query, opts) do
    case filter_value(opts, :provider_id) do
      nil -> query
      provider_id -> where(query, [rl], rl.provider_id == ^provider_id)
    end
  end

  # `maybe_rollup_scope/2` reads keyword keys; the summary's map form gets the
  # member scope translated to its rollup column name first.
  defp normalize_guard_scope(filters) when is_map(filters) do
    case Map.get(filters, :group_member_ids) do
      nil ->
        Map.to_list(filters)

      ids ->
        filters |> Map.delete(:group_member_ids) |> Map.put(:member_ids, ids) |> Map.to_list()
    end
  end

  defp normalize_guard_scope(opts) when is_list(opts), do: opts

  defp tail_hour_counts(opts) do
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    from(rl in RequestLog,
      where: rl.inserted_at >= ^raw_tail_start(opts),
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
    |> maybe_user_ids(opts[:user_ids])
    |> Repo.all(timeout: stats_query_timeout())
    |> Enum.map(&{&1.hour, &1.n})
  end

  defp maybe_member_ids(query, nil), do: query

  defp maybe_member_ids(query, ids),
    do: where(query, [rl], rl.group_member_id in ^ids)

  defp maybe_user_ids(query, nil), do: query

  defp maybe_user_ids(query, ids),
    do: where(query, [rl], rl.user_id in ^ids)

  defp maybe_provider_id(query, nil), do: query

  defp maybe_provider_id(query, provider_id) when is_binary(provider_id),
    do: where(query, [rl], rl.provider_id == ^provider_id)

  defp maybe_to(query, nil), do: query
  defp maybe_to(query, %DateTime{} = to), do: where(query, [rl], rl.inserted_at <= ^to)

  # ---------------------------------------------------------------------
  # Agent ranking
  # ---------------------------------------------------------------------

  @doc """
  Ranking of coding agents over the period: one row per RAW identity bucket
  `(agent_type, client_agent)`.

  `request_logs` stores the client identity as it arrived (the `X-Agent-Type`
  header plus `X-Title` → `User-Agent`), not a canonical agent, and the rollup
  has no agent dimension — so this is a raw read bounded by the period. The
  caller normalizes each bucket with `Tokengate.Agents.identify/2` and merges
  by key: the same agent reaching the proxy through two headers (or through
  the historical `agent_type: "api"`) must collapse into ONE row.

  `avg_latency_ms` travels with `latency_count` (rows that actually carry a
  latency): merging averages without that weight would let a 1-request bucket
  weigh as much as a 10k-request one.
  """
  @spec agent_ranking(keyword()) :: [map()]
  def agent_ranking(opts \\ []) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.get(opts, :to)

    RequestLog
    |> where([rl], rl.inserted_at >= ^from)
    |> maybe_to(to)
    |> maybe_member_ids(opts[:member_ids])
    |> group_by([rl], [rl.agent_type, rl.client_agent])
    |> select([rl], %{
      agent_type: rl.agent_type,
      client_agent: rl.client_agent,
      request_count: count(rl.id),
      error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
      cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
      prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.prompt_tokens),
      completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.completion_tokens),
      cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_read_tokens),
      cache_creation_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_creation_tokens),
      avg_latency_ms: fragment("AVG(?)", rl.latency_ms),
      latency_count: fragment("COUNT(?)", rl.latency_ms)
    })
    |> Repo.all(timeout: stats_query_timeout())
  end

  # ---------------------------------------------------------------------
  # Rollup-side reads for the overview's heavy cards
  # ---------------------------------------------------------------------

  # Perfil hora × proveedor: buckets completos [ceil_hour(from), tail_floor).
  # La hora LOCAL sale del mismo EXTRACT que `rollup_hour_counts/1` — el
  # bias de zonas con offset no-entero (:30/:45) es el aceptado ahí.
  defp rollup_hour_provider_rows(opts) do
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    {from, to} = rollup_window(opts)

    from(m in RequestMetricsHourly,
      where: m.hour_utc >= ^from and m.hour_utc < ^to,
      group_by: [fragment("1"), m.provider_id],
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
        provider_id: m.provider_id,
        request_count: fragment("COALESCE(SUM(?), 0)::bigint", m.request_count),
        cost_usd_raw: fragment("COALESCE(SUM(?), 0)::bigint", m.cost_micro)
      }
    )
    |> rollup_day_bounds(from, to)
    |> maybe_rollup_scope(opts)
    |> Repo.all(timeout: stats_query_timeout())
    |> Enum.map(fn row ->
      %{
        hour: row.hour,
        provider_id: row.provider_id,
        request_count: row.request_count,
        cost_usd: micro_to_decimal(row.cost_usd_raw)
      }
    end)
  end

  # La cola cruda (≤3h) del perfil hora × proveedor: misma forma de fila.
  defp tail_hour_provider_rows(opts) do
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    to = Keyword.get(opts, :to)

    RequestLog
    |> where([rl], rl.inserted_at >= ^raw_tail_start(opts))
    |> maybe_to(to)
    |> group_by([rl], [fragment("1"), rl.provider_id])
    |> select([rl], %{
      hour:
        type(
          fragment(
            "EXTRACT(hour FROM (? AT TIME ZONE 'Etc/UTC') AT TIME ZONE ?)",
            rl.inserted_at,
            ^timezone
          ),
          :integer
        ),
      provider_id: rl.provider_id,
      request_count: count(rl.id),
      cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)
    })
    |> maybe_member_ids(opts[:member_ids])
    |> maybe_user_ids(opts[:user_ids])
    |> Repo.all(timeout: stats_query_timeout())
  end

  # Modelo × proveedor desde el rollup: `provider_stats_id` es el id del
  # PROVEEDOR (dimensión del rollup) — el mismo que abre el detalle.
  defp rollup_model_provider_rows(opts) do
    {from, to} = rollup_window(opts)

    from(m in RequestMetricsHourly,
      where: m.hour_utc >= ^from and m.hour_utc < ^to,
      group_by: [m.model_id, m.provider_id],
      select: %{
        model_id: m.model_id,
        provider_id: m.provider_id,
        request_count: fragment("COALESCE(SUM(?), 0)::bigint", m.request_count),
        cost_usd_raw: fragment("COALESCE(SUM(?), 0)::bigint", m.cost_micro)
      }
    )
    |> rollup_day_bounds(from, to)
    |> maybe_rollup_scope(opts)
    |> Repo.all(timeout: stats_query_timeout())
  end

  # La cola cruda (≤3h) del stacked: la misma query plana del lado completo,
  # acotada al corte — reusa `Rollup.model_provider_flat_rows/1`.
  defp tail_model_provider_rows(opts) do
    Rollup.model_provider_flat_rows(
      from: raw_tail_start(opts),
      to: Keyword.get(opts, :to),
      member_ids: opts[:member_ids]
    )
  end

  # Nombres y logos del catálogo para las filas planas del rollup (una query
  # por tabla, sobre ids del resultado — nunca joins por fila agregada).
  defp model_provider_names(rollup_rows) do
    model_ids = rollup_rows |> Enum.map(& &1.model_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    provider_ids =
      rollup_rows |> Enum.map(& &1.provider_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    model_names =
      from(ma in Model, where: ma.id in ^model_ids, select: {ma.id, ma.name})
      |> Repo.all(timeout: stats_query_timeout())
      |> Map.new()

    provider_identities =
      from(p in Provider, where: p.id in ^provider_ids, select: {p.id, p.name, p.logo_url})
      |> Repo.all(timeout: stats_query_timeout())
      |> Map.new(fn {id, name, logo} -> {id, {name, logo}} end)

    Enum.map(rollup_rows, fn row ->
      {provider_name, provider_logo} =
        Map.get(provider_identities, row.provider_id, {nil, nil})

      %{
        model_id: row.model_id,
        model_name: Map.get(model_names, row.model_id) || "—",
        provider_id: row.provider_id,
        provider_stats_id: row.provider_id,
        provider_name: provider_name || "—",
        provider_logo_url: provider_logo,
        request_count: row.request_count,
        cost_usd: micro_to_decimal(row.cost_usd_raw)
      }
    end)
  end

  # Scoping del rollup: member_ids cubre memberships vivas, user_ids el
  # histórico post-rotación (misma convención que los breakdowns híbridos).
  defp maybe_rollup_scope(query, opts) do
    query
    |> maybe_rollup_member_ids(opts[:member_ids])
    |> maybe_rollup_user_ids(opts[:user_ids])
    |> maybe_rollup_model_id(opts[:model_id])
    |> maybe_rollup_provider_id(opts[:provider_id])
  end

  # The rollup's indexes are prefixed by `day` (the UTC date of `hour_utc`),
  # so an `hour_utc`-only window forces a seq scan over the whole table.
  # Bounding `day` too lets PG use the index prefix: `day >= date(from)` and
  # `day <= date(to)` are a superset of the hour window, so the result set
  # is unchanged (day and hour_utc are correlated, never contradictory).
  defp rollup_day_bounds(query, %DateTime{} = from, to) do
    query
    |> where([m], m.day >= ^DateTime.to_date(from))
    |> rollup_day_upper(to)
  end

  defp rollup_day_upper(query, nil), do: query

  defp rollup_day_upper(query, %DateTime{} = to),
    do: where(query, [m], m.day <= ^DateTime.to_date(to))

  defp maybe_rollup_model_id(query, nil), do: query

  defp maybe_rollup_model_id(query, model_id) when is_binary(model_id),
    do: where(query, [m], m.model_id == ^model_id)

  defp maybe_rollup_provider_id(query, nil), do: query

  defp maybe_rollup_provider_id(query, provider_id) when is_binary(provider_id),
    do: where(query, [m], m.provider_id == ^provider_id)

  defp maybe_rollup_member_ids(query, nil), do: query

  defp maybe_rollup_member_ids(query, member_ids) when is_list(member_ids),
    do: where(query, [m], m.group_member_id in ^member_ids)

  defp maybe_rollup_user_ids(query, nil), do: query

  defp maybe_rollup_user_ids(query, user_ids) when is_list(user_ids),
    do: where(query, [m], m.user_id in ^user_ids)

  defp micro_to_decimal(micro) when is_integer(micro) do
    micro |> Decimal.new() |> Decimal.div(Decimal.new(1_000_000))
  end

  defp micro_to_decimal(nil), do: Decimal.new(0)

  # Busiest hours: buckets de hora local. El rollup trae buckets UTC enteros
  # — el bucket local se obtiene desplazando el instante (los offsets de hora
  # entera hacen que el bucket UTC ≡ bucket local); la cola cruda agrupa con
  # el mismo date_trunc local del lado completo. Ambos lados normalizan el
  # key a UTC para que el merge sea por instante.
  defp rollup_hour_buckets(opts) do
    {from, to} = rollup_window(opts)

    from(m in RequestMetricsHourly,
      where: m.hour_utc >= ^from and m.hour_utc < ^to,
      group_by: m.hour_utc,
      select: %{
        hour_utc: m.hour_utc,
        n: fragment("COALESCE(SUM(?), 0)::bigint", m.request_count),
        cost_micro: fragment("COALESCE(SUM(?), 0)::bigint", m.cost_micro)
      }
    )
    |> rollup_day_bounds(from, to)
    |> maybe_rollup_scope(opts)
    |> Repo.all(timeout: stats_query_timeout())
    |> Map.new(fn row ->
      {to_utc_dt(row.hour_utc),
       %{request_count: row.n, cost_usd: micro_to_decimal(row.cost_micro)}}
    end)
  end

  defp tail_hour_buckets(opts) do
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    to = Keyword.get(opts, :to)

    bucketed =
      RequestLog
      |> where([rl], rl.inserted_at >= ^raw_tail_start(opts))
      |> maybe_to(to)
      |> select([rl], %{
        bucket:
          fragment(
            "date_trunc('hour', ? AT TIME ZONE ?) AT TIME ZONE ?",
            rl.inserted_at,
            ^timezone,
            ^timezone
          ),
        id: rl.id,
        spend: rl.provider_cost_usd
      })
      |> subquery()

    from(b in bucketed,
      group_by: b.bucket,
      select: %{
        bucket: b.bucket,
        n: count(b.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", b.spend)
      }
    )
    |> maybe_member_ids(opts[:member_ids])
    |> maybe_user_ids(opts[:user_ids])
    |> Repo.all(timeout: stats_query_timeout())
    |> Map.new(fn row ->
      {to_utc_dt(row.bucket),
       %{request_count: row.n, cost_usd: Decimal.new(to_string(row.cost_usd))}}
    end)
  end

  defp to_utc_dt(%DateTime{} = dt), do: dt

  defp to_utc_dt(%NaiveDateTime{} = ndt),
    do: DateTime.from_naive!(ndt, "Etc/UTC")

  # ---------------------------------------------------------------------
  # Merging
  # ---------------------------------------------------------------------

  # Sums the additive counters of two Logs.cost_summary/1-shaped maps.
  #
  # Every derived value is RE-derived from summed inputs instead of being
  # dropped or averaged:
  #
  #   * `error_count` — both halves publish it (`cost_summary/1` counts the
  #     >= 400 rows); the old merge dropped the key entirely, so a hybrid KPI
  #     card lost the errors of the period.
  #   * `avg_latency_ms` — weighted by each half's own `latency_count`, i.e.
  #     total latency over total samples. Averaging the two averages gave a
  #     1-request tail the same weight as 10k rollup requests.
  #   * `avg_ttft_ms` — same weighting over `ttft_count` (the rollup has no
  #     TTFT column, so it contributes samples=0 and a raw-only tail wins).
  #   * `avg_tps` — from the summed completion tokens and total latency, the
  #     one shared formula (`Logs.compute_tps/2`).
  defp merge_summaries(a, b) do
    total_latency_ms = (Map.get(a, :total_latency_ms) || 0) + (Map.get(b, :total_latency_ms) || 0)
    latency_count = (Map.get(a, :latency_count) || 0) + (Map.get(b, :latency_count) || 0)
    completion_tokens = a.total_completion_tokens + b.total_completion_tokens

    %{
      total_cost_usd: Decimal.add(a.total_cost_usd, b.total_cost_usd),
      total_prompt_tokens: a.total_prompt_tokens + b.total_prompt_tokens,
      total_completion_tokens: completion_tokens,
      total_cache_read_tokens: a.total_cache_read_tokens + b.total_cache_read_tokens,
      total_cache_creation_tokens: a.total_cache_creation_tokens + b.total_cache_creation_tokens,
      request_count: a.request_count + b.request_count,
      error_count: (Map.get(a, :error_count) || 0) + (Map.get(b, :error_count) || 0),
      total_latency_ms: total_latency_ms,
      latency_count: latency_count,
      ttft_count: (Map.get(a, :ttft_count) || 0) + (Map.get(b, :ttft_count) || 0),
      avg_latency_ms: weighted_avg(total_latency_ms, latency_count),
      avg_ttft_ms: weighted_ttft(a, b),
      avg_tps: compute_tps(completion_tokens, total_latency_ms)
    }
  end

  # Mean over the samples that actually measured the metric; `nil` when there
  # are none (never an invented 0).
  defp weighted_avg(_total, 0), do: nil

  defp weighted_avg(total, count) when is_integer(count) and count > 0,
    do: Float.round(total / count, 1)

  # `avg_ttft_ms` is a mean, not a sum: rebuild it as
  # `(avg_a * count_a + avg_b * count_b) / (count_a + count_b)` so a half that
  # measured nothing cannot dilute the other.
  defp weighted_ttft(a, b) do
    a_count = Map.get(a, :ttft_count) || 0
    b_count = Map.get(b, :ttft_count) || 0
    a_avg = Map.get(a, :avg_ttft_ms)
    b_avg = Map.get(b, :avg_ttft_ms)

    cond do
      a_avg == nil and b_avg == nil -> nil
      b_avg == nil -> a_avg
      a_avg == nil -> b_avg
      a_count + b_count == 0 -> nil
      true -> Float.round((a_avg * a_count + b_avg * b_count) / (a_count + b_count), 1)
    end
  end

  # Merges two breakdown row lists (rollup half + raw-tail half) by identity
  # key, summing additive counters. `Enum.group_by/2` + one `sum_row/2` per
  # group keeps this O(n) instead of the old O(n²) `List.update_at` scan;
  # avg_tps is recomputed from the summed inputs.
  defp merge_rows(rollup_rows, raw_rows) do
    (rollup_rows ++ raw_rows)
    |> Enum.group_by(&row_identity/1)
    |> Enum.map(fn {_key, [row | rest]} ->
      Enum.reduce(rest, row, fn other, acc ->
        # `group_by` already guarantees same row, but keep the guard so a
        # future identity change can never sum unrelated rows.
        if same_row?(acc, other), do: sum_row(acc, other), else: acc
      end)
    end)
    |> Enum.sort(fn a, b ->
      case Decimal.compare(a.cost_usd, b.cost_usd) do
        :eq -> a.request_count > b.request_count
        :lt -> false
        :gt -> true
      end
    end)
  end

  # Ranking shared by every breakdown: real cost first, then volume. Same
  # order the raw aggregates publish (`ORDER BY SUM(provider_cost_usd) DESC`).
  defp sort_by_cost(rows) do
    Enum.sort(rows, fn a, b ->
      case Decimal.compare(a.cost_usd, b.cost_usd) do
        :eq -> a.request_count > b.request_count
        :lt -> false
        :gt -> true
      end
    end)
  end

  # Row identity is EVERY breakdown dimension, not "any of them": two rows
  # are the same row only when all four ids match (nil == nil counts). The
  # old `Enum.any?` collapsed a model row with an unrelated user row whenever
  # one id happened to coincide.
  @row_identity_keys [:model_id, :user_id, :group_member_id, :group_id]

  defp same_row?(a, b),
    do: Enum.all?(@row_identity_keys, fn key -> a[key] == b[key] end)

  defp row_identity(row), do: Enum.map(@row_identity_keys, &row[&1])

  defp sum_row(a, b) do
    tokens = (a.completion_tokens || 0) + (b.completion_tokens || 0)
    latency = (a[:total_latency_ms] || 0) + (b[:total_latency_ms] || 0)

    # `Map.get` for the optional counters: the per-user rows (and any caller
    # that does not publish `cache_read_tokens`) simply have no such key, and
    # dot access on a missing key raises.
    a
    |> Map.put(:request_count, a.request_count + b.request_count)
    |> Map.put(:error_count, Map.get(a, :error_count, 0) + Map.get(b, :error_count, 0))
    |> Map.put(:cost_usd, Decimal.add(a.cost_usd, b.cost_usd))
    |> Map.put(:prompt_tokens, (a.prompt_tokens || 0) + (b.prompt_tokens || 0))
    |> Map.put(:completion_tokens, tokens)
    |> Map.put(
      :cache_read_tokens,
      Map.get(a, :cache_read_tokens, 0) + Map.get(b, :cache_read_tokens, 0)
    )
    |> Map.put(
      :cache_creation_tokens,
      Map.get(a, :cache_creation_tokens, 0) + Map.get(b, :cache_creation_tokens, 0)
    )
    |> Map.put(:avg_tps, compute_tps(tokens, latency))
  end

  # Same shared formula as `Rollup` / `Logs` — see `Logs.compute_tps/2` for the
  # nil/0.0 contract. Keeping a local copy is what let the three modules drift.
  defp compute_tps(tokens, latency), do: Logs.compute_tps(tokens, latency)

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

  # `model_id` / `provider_id` are real rollup dimensions, so those filters
  # can answer from the rollup half. `service_id`, `api_key_id` and
  # `status_code` have NO rollup counterpart (`request_metrics_hourly` has no
  # such columns): keeping them out forces the raw path — letting them in
  # would make the rollup half ignore the filter and answer org-wide.
  @rollup_keys [
    :from,
    :to,
    :timezone,
    :member_ids,
    :group_member_ids,
    :user_ids,
    :model_id,
    :provider_id,
    :sort_by,
    :limit,
    :metric
  ]

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
