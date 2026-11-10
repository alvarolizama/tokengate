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
          user_ids: filters[:user_ids],
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

  @doc """
  Perfil hora × proveedor del período. Same shape as
  `Rollup.usage_by_hour_of_day_by_provider/1`.

  Hybrid: the rollup answers the hour buckets (dims `hour_utc` + `provider_id`
  are both in the rollup) and only the fresh tail is raw — in production this
  turns a multi-million-row month scan into a few thousand rollup rows.
  """
  def usage_by_hour_of_day_by_provider(opts \\ []) do
    if hybrid?(opts) do
      Rollup.hour_provider_profile(
        rollup_hour_provider_rows(opts) ++ tail_hour_provider_rows(opts)
      )
    else
      Rollup.usage_by_hour_of_day_by_provider(opts)
    end
  end

  @doc """
  Gráfica apilada modelo × proveedor. Same shape as
  `Rollup.usage_by_model_provider_stacked/1`. Hybrid — see
  `usage_by_hour_of_day_by_provider/1`.
  """
  def usage_by_model_provider_stacked(opts \\ []) do
    if hybrid?(opts) do
      rollup_rows = opts |> rollup_model_provider_rows() |> model_provider_names()
      tail_rows = tail_model_provider_rows(opts)

      Rollup.model_provider_stacked(merge_flat_rows(rollup_rows, tail_rows))
    else
      Rollup.usage_by_model_provider_stacked(opts)
    end
  end

  @doc "Top N horas con más requests. Same shape as `Rollup.busiest_hours/2`."
  def busiest_hours(group_id \\ nil, opts \\ [])

  def busiest_hours(group_id, _opts) when not is_nil(group_id),
    do: Rollup.busiest_hours(group_id)

  def busiest_hours(nil, opts) do
    cond do
      not hybrid?(opts) ->
        Rollup.busiest_hours(nil, opts)

      # El bucket local del rollup es el bucket UTC: sólo coincide con la
      # hora local cuando el offset de la zona es de horas enteras (LatAm,
      # Europa). Con offsets :30/:45 la respuesta exacta exige el crudo.
      not whole_hour_zone?(opts) ->
        Rollup.busiest_hours(nil, opts)

      true ->
        # Rollup: buckets UTC enteros → key = instante (para zonas de hora
        # entera el bucket UTC ES la hora local). Cola cruda: el mismo
        # date_trunc local del lado completo, que aterriza en el mismo
        # instante. Merge aditivo por key y top-N en memoria.
        counts =
          Enum.reduce(tail_hour_buckets(opts), rollup_hour_buckets(opts), fn {bucket, n}, acc ->
            Map.update(acc, bucket, n, &(&1 + n))
          end)

        limit = Keyword.get(opts, :limit, 5)

        counts
        |> Enum.sort_by(fn {bucket, n} -> {-n, bucket} end)
        |> Enum.take(limit)
        |> Enum.map(fn {bucket, n} -> %{bucket: bucket, request_count: n} end)
    end
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
  # cola cruda pueden traer la misma pareja.
  defp merge_flat_rows(rollup_rows, tail_rows) do
    Enum.reduce(tail_rows, rollup_rows, fn tail, acc ->
      case Enum.find_index(
             acc,
             &(&1.model_id == tail.model_id and &1.provider_stats_id == tail.provider_stats_id)
           ) do
        nil ->
          acc ++ [tail]

        idx ->
          List.update_at(acc, idx, fn row ->
            %{
              row
              | request_count: row.request_count + tail.request_count,
                cost_usd: Decimal.add(row.cost_usd, tail.cost_usd)
            }
          end)
      end
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
  defp rollup_breakdown(:model, opts) do
    Rollup.breakdown_by_model_from_rollup(
      from: ceil_hour(Keyword.fetch!(opts, :from)),
      to: tail_floor(),
      user_ids: opts[:user_ids]
    )
  end

  defp rollup_breakdown(:member, opts) do
    Rollup.breakdown_by_member_from_rollup(
      from: ceil_hour(Keyword.fetch!(opts, :from)),
      to: tail_floor(),
      member_ids: opts[:member_ids],
      user_ids: opts[:user_ids]
    )
  end

  defp rollup_breakdown(:group, opts) do
    Rollup.breakdown_by_group_from_rollup(
      from: ceil_hour(Keyword.fetch!(opts, :from)),
      to: tail_floor(),
      member_ids: opts[:member_ids],
      user_ids: opts[:user_ids]
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
    |> maybe_user_ids(opts[:user_ids])
    |> Repo.all()
    |> Enum.map(&{&1.hour, &1.n})
  end

  defp maybe_member_ids(query, nil), do: query

  defp maybe_member_ids(query, ids),
    do: where(query, [rl], rl.group_member_id in ^ids)

  defp maybe_user_ids(query, nil), do: query

  defp maybe_user_ids(query, ids),
    do: where(query, [rl], rl.user_id in ^ids)

  defp maybe_to(query, nil), do: query
  defp maybe_to(query, %DateTime{} = to), do: where(query, [rl], rl.inserted_at <= ^to)

  # ---------------------------------------------------------------------
  # Rollup-side reads for the overview's heavy cards
  # ---------------------------------------------------------------------

  # Perfil hora × proveedor: buckets completos [ceil_hour(from), tail_floor).
  # La hora LOCAL sale del mismo EXTRACT que `rollup_hour_counts/1` — el
  # bias de zonas con offset no-entero (:30/:45) es el aceptado ahí.
  defp rollup_hour_provider_rows(opts) do
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    from(m in RequestMetricsHourly,
      where: m.hour_utc >= ^ceil_hour(Keyword.fetch!(opts, :from)) and m.hour_utc < ^tail_floor(),
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
    |> where([rl], rl.inserted_at >= ^tail_floor())
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
    from(m in RequestMetricsHourly,
      where: m.hour_utc >= ^ceil_hour(Keyword.fetch!(opts, :from)) and m.hour_utc < ^tail_floor(),
      group_by: [m.model_id, m.provider_id],
      select: %{
        model_id: m.model_id,
        provider_id: m.provider_id,
        request_count: fragment("COALESCE(SUM(?), 0)::bigint", m.request_count),
        cost_usd_raw: fragment("COALESCE(SUM(?), 0)::bigint", m.cost_micro)
      }
    )
    |> maybe_rollup_scope(opts)
    |> Repo.all(timeout: stats_query_timeout())
  end

  # La cola cruda (≤3h) del stacked: la misma query plana del lado completo,
  # acotada al corte — reusa `Rollup.model_provider_flat_rows/1`.
  defp tail_model_provider_rows(opts) do
    Rollup.model_provider_flat_rows(
      from: tail_floor(),
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
  end

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
    from(m in RequestMetricsHourly,
      where: m.hour_utc >= ^ceil_hour(Keyword.fetch!(opts, :from)) and m.hour_utc < ^tail_floor(),
      group_by: m.hour_utc,
      select: %{hour_utc: m.hour_utc, n: fragment("COALESCE(SUM(?), 0)::bigint", m.request_count)}
    )
    |> maybe_rollup_scope(opts)
    |> Repo.all(timeout: stats_query_timeout())
    |> Map.new(fn row -> {to_utc_dt(row.hour_utc), row.n} end)
  end

  defp tail_hour_buckets(opts) do
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    to = Keyword.get(opts, :to)

    bucketed =
      RequestLog
      |> where([rl], rl.inserted_at >= ^tail_floor())
      |> maybe_to(to)
      |> select([rl], %{
        bucket:
          fragment(
            "date_trunc('hour', ? AT TIME ZONE ?) AT TIME ZONE ?",
            rl.inserted_at,
            ^timezone,
            ^timezone
          ),
        id: rl.id
      })
      |> subquery()

    from(b in bucketed,
      group_by: b.bucket,
      select: %{bucket: b.bucket, n: count(b.id)}
    )
    |> maybe_member_ids(opts[:member_ids])
    |> maybe_user_ids(opts[:user_ids])
    |> Repo.all(timeout: stats_query_timeout())
    |> Map.new(fn row -> {to_utc_dt(row.bucket), row.n} end)
  end

  defp to_utc_dt(%DateTime{} = dt), do: dt

  defp to_utc_dt(%NaiveDateTime{} = ndt),
    do: DateTime.from_naive!(ndt, "Etc/UTC")

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

  @rollup_keys [:from, :to, :timezone, :member_ids, :group_member_ids, :user_ids]

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
