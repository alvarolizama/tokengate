defmodule Tokengate.Metrics.Rollup do
  @moduledoc """
  Durable metrics rollups over `Tokengate.Logs` (the `request_logs` table).

  This is a **pure query module** — no GenServer, no new tables. It reads
  directly from Postgres via Ecto fragments so the numbers stay consistent
  with the durable source of truth. Use `Tokengate.Metrics.Collector` for
  in-memory real-time counters.

  ## Functions

    * `hourly_series/2`     — bucketed request/cost/savings per hour
    * `top_consumers/2`     — per group-member aggregates, ranked by cost
    * `agent_breakdown/1`   — per agent_type aggregates
    * `breakdown_by_model/2` — per-model aggregates (requests, costs, tokens, tps)
    * `breakdown_by_member/2` — per-member aggregates (requests, costs, tokens, tps)
    * `breakdown_by_group/1`   — per-group aggregates (requests, costs, tokens, tps)
    * `provider_ranking/2`    — provider ranking by failures + latency, tier S/A/B/C/D
    * `usage_by_hour_of_day/2` — 24h UTC distribution (recurring usage patterns)
    * `usage_by_hour_of_day_by_provider/1` — per-hour-of-day split by provider (the
      hour card the Resumen shares with En vivo)
    * `busiest_hours/2` / `busiest_minutes/2` — top-N busiest hour/minute buckets
    * `peak_concurrency/2`    — estimated max in-flight requests (sweep line)
    * `top_errors/2`          — top HTTP error codes (>= 400) by count
  """

  import Ecto.Query, warn: false
  alias Tokengate.Accounts.ApiKey
  alias Tokengate.Accounts.GroupMember
  alias Tokengate.Accounts.Service
  alias Tokengate.Accounts.User
  # Stats reads scan raw request_logs across whole windows; cold, they can
  # exceed the DBConnection default (15s) in production. Analytics reads get
  # their own, generous budget instead of raising the Repo-wide timeout
  # (which would also cover the proxy auth/write path).
  @stats_timeout 120_000

  defp stats_timeout,
    do: Application.get_env(:tokengate, :stats_query_timeout_ms, @stats_timeout)

  alias Tokengate.Logs
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Metrics.RequestMetricsHourly
  alias Tokengate.Providers.Model
  alias Tokengate.Providers.Provider
  alias Tokengate.Repo

  # Etiqueta de los logs sin `provider_id` en el desglose horario por
  # proveedor. Tiene que ser la MISMA que la de En vivo
  # (`Logs.today_usage_by_hour_provider/0`): las dos pestañas dibujan la
  # misma tarjeta y una barra "no provider" (centinela de datos; se traduce al
  # pintar con `TokengateWeb.StatsHelpers.provider_label/1`) no puede cambiar de
  # nombre al cambiar de pestaña.
  @no_provider "no provider"

  # -----------------------------------------------------------------------
  # hourly_series/2
  # -----------------------------------------------------------------------

  @doc """
  Returns an hour-bucketed series over `request_logs`, ordered ascending.

  Each row is:

      %{
        hour: DateTime,          # truncated to the hour (in the requested timezone)
        request_count: integer,
        cost_usd: Decimal
      }

  Buckets `inserted_at` using Postgres `date_trunc("hour", inserted_at
  AT TIME ZONE ?) AT TIME ZONE ?` so the series is bucketed by **local
  hour** for the requested timezone (UTC by default). `nil` `group_id` is
  org-wide (no group join). When `group_id` is given, filters to logs whose
  group_member belongs to that group.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime); defaults to 24h ago
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:timezone` — IANA zone for local-hour bucketing; default `"Etc/UTC"`
  """
  @spec hourly_series(String.t() | nil, keyword()) :: [map()]
  def hourly_series(group_id \\ nil, opts \\ []) when is_list(opts) do
    from = Keyword.get(opts, :from) || hours_ago_default()
    to = Keyword.get(opts, :to)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    # Materialize the local-hour bucket in a subquery first: Postgres rejects
    # `GROUP BY date_trunc(... AT TIME ZONE $1)` + `SELECT date_trunc(... AT
    # TIME ZONE $2)` as "column must appear in GROUP BY" because the two
    # parametrized expressions are formally different. Grouping the outer
    # query by the subquery's materialized column sidesteps that.
    bucketed =
      RequestLog
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_join_group(group_id)
      |> select([rl], %{
        bucket:
          fragment(
            "date_trunc('hour', ? AT TIME ZONE ?) AT TIME ZONE ?",
            rl.inserted_at,
            ^timezone,
            ^timezone
          ),
        id: rl.id,
        provider_cost_usd: rl.provider_cost_usd,
        prompt_tokens: rl.prompt_tokens,
        completion_tokens: rl.completion_tokens,
        latency_ms: rl.latency_ms
      })
      |> subquery()

    query =
      from(b in bucketed,
        group_by: b.bucket,
        order_by: b.bucket,
        select: %{
          hour: b.bucket,
          request_count: count(b.id),
          cost_usd: fragment("COALESCE(SUM(?), 0)", b.provider_cost_usd),
          prompt_tokens: coalesce(sum(b.prompt_tokens), 0),
          completion_tokens: coalesce(sum(b.completion_tokens), 0),
          total_latency_ms: coalesce(sum(b.latency_ms), 0)
        }
      )

    Repo.all(query, timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        hour: to_utc_datetime(row.hour),
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        total_latency_ms: row.total_latency_ms
      }
    end)
  end

  defp hours_ago_default do
    DateTime.utc_now()
    |> DateTime.add(-24 * 3600, :second)
    |> DateTime.truncate(:second)
  end

  # -----------------------------------------------------------------------
  # top_consumers/2
  # -----------------------------------------------------------------------

  @doc """
  Returns per group-member aggregates ranked by total cost (descending).

  Each row is:

      %{
        group_member_id: binary,
        request_count: integer,
        cost_usd: Decimal
      }

  Joins `request_logs` to `group_members` filtered by `group_id`. `limit`
  defaults to 10.
  """
  @spec top_consumers(String.t(), pos_integer()) :: [map()]
  def top_consumers(group_id, limit \\ 10)

  def top_consumers(group_id, limit)
      when is_binary(group_id) and is_integer(limit) and limit > 0 do
    query =
      RequestLog
      |> join(:inner, [rl], tm in GroupMember, on: rl.group_member_id == tm.id)
      |> where([rl, tm], tm.group_id == ^group_id)
      |> group_by([rl, tm], rl.group_member_id)
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> limit(^limit)
      |> select([rl], %{
        group_member_id: rl.group_member_id,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)
      })

    Repo.all(query, timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        group_member_id: row.group_member_id,
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd))
      }
    end)
  end

  # -----------------------------------------------------------------------
  # agent_breakdown/1
  # -----------------------------------------------------------------------

  @doc """
  Returns per `agent_type` aggregates.

  Shape:

      %{agent_type => %{requests: integer, cost_usd: Decimal}}

  `nil` `group_id` is org-wide. When `group_id` is given, filters to logs
  whose group_member belongs to that group.
  """
  @spec agent_breakdown(String.t() | nil) :: map()
  def agent_breakdown(group_id \\ nil)

  def agent_breakdown(nil) do
    query =
      RequestLog
      |> where([rl], not is_nil(rl.agent_type))
      |> group_by([rl], rl.agent_type)
      |> select([rl], %{
        agent_type: rl.agent_type,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)
      })

    Repo.all(query, timeout: stats_timeout())
    |> Enum.into(%{}, fn row ->
      {row.agent_type,
       %{
         requests: row.request_count,
         cost_usd: Decimal.new(to_string(row.cost_usd))
       }}
    end)
  end

  def agent_breakdown(group_id) when is_binary(group_id) do
    query =
      RequestLog
      |> join(:inner, [rl], tm in GroupMember, on: rl.group_member_id == tm.id)
      |> where([rl, tm], tm.group_id == ^group_id and not is_nil(rl.agent_type))
      |> group_by([rl], rl.agent_type)
      |> select([rl], %{
        agent_type: rl.agent_type,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)
      })

    Repo.all(query, timeout: stats_timeout())
    |> Enum.into(%{}, fn row ->
      {row.agent_type,
       %{
         requests: row.request_count,
         cost_usd: Decimal.new(to_string(row.cost_usd))
       }}
    end)
  end

  # -----------------------------------------------------------------------
  # breakdown_by_model/2
  # -----------------------------------------------------------------------

  @doc """
  Returns per-model-aggregate metrics ranked by total cost (descending).

  Each row is:

      %{
        model_id: binary | nil,
        model_name: String.t(),
        request_count: integer,
        cost_usd: Decimal,  # what the upstream charged for the request
        prompt_tokens: integer,
        completion_tokens: integer,
        avg_tps: float | nil
      }

  `group_id` of `nil` is org-wide. When given, filters to logs whose
  group_member belongs to that group.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:member_ids` — restrict to logs of these group-member ids (scoping)
    * `:provider_id` — restrict to logs served by that provider
  """
  @spec breakdown_by_model(String.t() | nil, keyword()) :: [map()]
  def breakdown_by_model(group_id \\ nil, opts \\ [])

  def breakdown_by_model(group_id, opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    query =
      RequestLog
      |> maybe_join_group(group_id)
      |> maybe_service_id(Keyword.get(opts, :service_id))
      |> maybe_provider_id(Keyword.get(opts, :provider_id))
      |> maybe_model_id(Keyword.get(opts, :model_id))
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> maybe_user_ids(Keyword.get(opts, :user_ids))
      |> join(:left, [rl], ma in Model, on: rl.model_id == ma.id, as: :model)
      |> group_by([model: ma], ma.id)
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, model: ma], %{
        model_id: ma.id,
        model_name: ma.name,
        market_input_price_per_1m: ma.market_input_price_per_1m,
        market_output_price_per_1m: ma.market_output_price_per_1m,
        market_cache_price_per_1m: ma.market_cache_price_per_1m,
        request_count: count(rl.id),
        error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_read_tokens),
        cache_creation_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_creation_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })

    Repo.all(query, timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        model_id: row.model_id,
        model_name: row.model_name || "—",
        market_input_price_per_1m: row.market_input_price_per_1m,
        market_output_price_per_1m: row.market_output_price_per_1m,
        market_cache_price_per_1m: row.market_cache_price_per_1m,
        request_count: row.request_count,
        error_count: row.error_count || 0,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        cache_read_tokens: row.cache_read_tokens,
        cache_creation_tokens: row.cache_creation_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  # -----------------------------------------------------------------------
  # breakdown_by_member/2
  # -----------------------------------------------------------------------

  @doc """
  Breakdown de modelos usados por un miembro específico (por group_member_id).
  Útil para la vista de detalle de miembro: qué modelos usa, cuánto gasta, etc.
  """
  @spec breakdown_by_model_for_member(String.t(), keyword()) :: [map()]
  def breakdown_by_model_for_member(member_id, opts \\ [])

  def breakdown_by_model_for_member(nil, _opts), do: []

  def breakdown_by_model_for_member(member_id, opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    query =
      RequestLog
      |> where([rl], rl.group_member_id == ^member_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> join(:left, [rl], ma in Model, on: rl.model_id == ma.id, as: :model)
      |> group_by([model: ma], ma.id)
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, model: ma], %{
        model_id: ma.id,
        model_name: ma.name,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_read_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })

    Repo.all(query, timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        model_id: row.model_id,
        model_name: row.model_name || "—",
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        cache_read_tokens: row.cache_read_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  @doc """
  Returns per-group-member aggregate metrics ranked by total cost (descending).

  Each row is:

      %{
        group_member_id: binary,
        user_id: binary,
        group_name: String.t(),
        user_email: String.t(),
        request_count: integer,
        cost_usd: Decimal,  # what the upstream charged for the request
        prompt_tokens: integer,
        completion_tokens: integer,
        cache_read_tokens: integer,
        avg_tps: float | nil
      }

  `group_id` of `nil` is org-wide. When given, filters to logs whose
  group_member belongs to that group.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:member_ids` — restrict to logs of these group-member ids (scoping)
  """
  @spec breakdown_by_member(String.t() | nil, keyword()) :: [map()]
  def breakdown_by_member(group_id \\ nil, opts \\ [])

  def breakdown_by_member(group_id, opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    # Atribución por USUARIO (`rl.user_id`), no por membresía: los logs cuya
    # membresía fue rotada (group_member_id NULL tras el SET NULL) siguen
    # contando para su usuario. La membresía y su grupo se resuelven con LEFT
    # JOIN — cuando viven dan el contexto (grupo, miembro), cuando no, la fila
    # sobrevive con "—".
    query =
      RequestLog
      |> join(:left, [rl], tm in GroupMember, on: rl.group_member_id == tm.id, as: :member)
      |> join(:left, [member: tm], t in assoc(tm, :group), as: :group)
      |> join(:left, [rl], u in Tokengate.Accounts.User, on: rl.user_id == u.id, as: :user)
      |> maybe_member_group_filter(group_id)
      |> maybe_model_id(Keyword.get(opts, :model_id))
      |> maybe_provider_id(Keyword.get(opts, :provider_id))
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> maybe_user_ids(Keyword.get(opts, :user_ids))
      # Sólo logs de usuario: los de servicio (user_id nil) no son "miembros"
      # — sin esto aparecerían como fila "—" en rankings que enlazan user_id.
      |> where([rl], rl.subject_type == "user")
      |> group_by([rl, member: tm, group: t, user: u], [u.id, tm.id, t.id])
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, member: tm, group: t, user: u], %{
        group_member_id: tm.id,
        user_id: u.id,
        group_name: t.name,
        user_email: u.email,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_read_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })

    Repo.all(query, timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        group_member_id: row.group_member_id,
        user_id: row.user_id,
        group_name: row.group_name,
        user_email: row.user_email,
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        cache_read_tokens: row.cache_read_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  # -----------------------------------------------------------------------
  # breakdown_by_user/1
  # -----------------------------------------------------------------------

  @doc """
  Returns per-user aggregate metrics — one row per USER (not per group
  membership), consolidating every membership the user holds. Ranked by
  total cost (descending).

  Each row is:

      %{
        user_id: binary,
        user_name: String.t() | nil,
        user_email: String.t(),
        memberships: non_neg_integer,
        groups: [%{id: binary, name: String.t()}],
        request_count: integer,
        cost_usd: Decimal,
        prompt_tokens: integer,
        completion_tokens: integer,
        cache_read_tokens: integer,
        avg_tps: float | nil
      }

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:provider_id` — restrict to logs served by that provider
  """
  @spec breakdown_by_user(keyword()) :: [map()]
  def breakdown_by_user(opts \\ []) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    # Atribución por USUARIO (`rl.user_id`): un usuario cuya membresía fue
    # rotada sigue apareciendo en el ranking con TODO su histórico — antes
    # el INNER JOIN a group_members lo hacía desaparecer junto a su gasto.
    # El contexto (membresías/grupos) se resuelve con LEFT JOIN.
    #
    # `subject_type = 'user'` es la MISMA regla que aplica el lado híbrido
    # (`StatsQueries.raw_by_user_rows/3`): una fila de servicio puede llevar
    # `user_id` (top-ups y atribución heredada lo pueblan), y sin el filtro el
    # ranking de usuarios sumaba tráfico de servicio en las filas mixtas y
    # contradecía a `breakdown_by_service/1`.
    query =
      RequestLog
      |> where([rl], rl.subject_type == "user")
      |> join(:left, [rl], tm in GroupMember, on: rl.group_member_id == tm.id, as: :member)
      |> join(:left, [rl], u in Tokengate.Accounts.User, on: rl.user_id == u.id, as: :user)
      |> where([user: u], not is_nil(u.id))
      |> maybe_provider_id(Keyword.get(opts, :provider_id))
      |> maybe_from(from)
      |> maybe_to(to)
      |> group_by([user: u], u.id)
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, member: tm, user: u], %{
        user_id: u.id,
        user_name: u.name,
        user_email: u.email,
        membership_count: count(tm.id, :distinct),
        # `::text` explícito: `group_id` es `:binary_id` (uuid) y un
        # `ARRAY_AGG` sin tipo llega como lista de 16 bytes crudos, no como
        # UUID en texto — con esos bytes el lookup de nombres fallaba SIEMPRE
        # y la columna de perfiles de límites salía "—" para todos.
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

    # Resolve group names outside the aggregate so the index-driven join
    # stays a single pass (a join to groups in the GROUP BY would force a
    # second sort over the whole range scan). El par id+nombre viaja junto:
    # el id es lo único que permite enlazar el perfil de límites desde el listado, y
    # resolver el nombre antes de perder el id dejaba el perfil de límites como texto
    # muerto (el campo se llamaba `group_names` pero traía ids).
    #
    # ONE read of the names per call, and none when the window has no rows: the
    # map is built once and reused for every row instead of resolving per row,
    # and an empty period no longer pays a query for labels it will not print.
    rows = Repo.all(query, timeout: stats_timeout())
    group_names_by_id = if rows == [], do: %{}, else: Tokengate.Accounts.group_names_by_id()

    Enum.map(rows, fn row ->
      %{
        user_id: row.user_id,
        user_name: row.user_name,
        user_email: row.user_email,
        memberships: row.membership_count,
        # `|| []`: un usuario cuyos logs son todos post-rotación no tiene
        # grupo que agregar — ARRAY_AGG devuelve NULL, no array vacío.
        groups:
          (row.group_ids || [])
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&%{id: &1, name: Map.get(group_names_by_id, &1, "—")})
          |> Enum.sort_by(& &1.name),
        request_count: row.request_count,
        error_count: row.error_count || 0,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        cache_read_tokens: row.cache_read_tokens,
        cache_creation_tokens: row.cache_creation_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  # -----------------------------------------------------------------------
  # breakdown_by_service/1
  # -----------------------------------------------------------------------

  @doc """
  Returns per-service aggregate metrics ranked by total cost (descending).

  Services have a dedicated `service_id` column on `request_logs`
  (group_member_id is null).

  Each row is:

      %{
        service_id: binary,
        service_name: String.t(),
        request_count: integer,
        cost_usd: Decimal,
        prompt_tokens: integer,
        completion_tokens: integer,
        cache_read_tokens: integer,
        avg_tps: float | nil,
        avg_latency_ms: float | nil
      }

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:provider_id` — restrict to logs served by that provider
  """
  @spec breakdown_by_service(keyword()) :: [map()]
  def breakdown_by_service(opts \\ [])

  def breakdown_by_service(opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    # Services have a dedicated `service_id` column (group_member_id is null).
    query =
      RequestLog
      |> join(:inner, [rl], s in Tokengate.Accounts.Service, on: rl.service_id == s.id)
      |> maybe_provider_id(Keyword.get(opts, :provider_id))
      |> maybe_from(from)
      |> maybe_to(to)
      |> group_by([rl, s], s.id)
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, s], %{
        service_id: s.id,
        service_name: s.name,
        request_count: count(rl.id),
        error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_read_tokens),
        cache_creation_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_creation_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms),
        latency_count: fragment("COUNT(?)", rl.latency_ms)
      })

    Repo.all(query, timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        service_id: row.service_id,
        service_name: row.service_name,
        request_count: row.request_count,
        error_count: row.error_count || 0,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        cache_read_tokens: row.cache_read_tokens,
        cache_creation_tokens: row.cache_creation_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms),
        # Media por request con latencia (SUM ignora los NULL), igual que
        # `summary_from_rollup/1`: sin ninguna latencia registrada es nil, no 0.
        avg_latency_ms: compute_avg_latency(row.total_latency_ms, row.latency_count)
      }
    end)
  end

  # -----------------------------------------------------------------------
  # service_summaries/2
  # -----------------------------------------------------------------------

  @doc """
  Per-service aggregates for an explicit set of service ids, keyed by
  `service_id` — the summary line the supervised-services view draws per
  service (and their totals) without one query per card.

  Services carry `service_id` on `request_logs` (`group_member_id` is null),
  which is why this filters on `service_id` and not on the member column.

  Each value is:

      %{
        service_id: binary,
        request_count: integer,
        error_count: integer,   # responses with status_code >= 400
        cost_usd: Decimal,
        prompt_tokens: integer,
        completion_tokens: integer,
        cache_read_tokens: integer,
        avg_latency_ms: float | nil,
        avg_tps: float | nil
      }

  Service ids without any log in the window are simply absent from the map —
  the caller falls back to zeros.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
  """
  @spec service_summaries([binary()], keyword()) :: %{binary() => map()}
  def service_summaries(service_ids, opts \\ [])

  def service_summaries([], _opts), do: %{}

  def service_summaries(service_ids, opts) when is_list(service_ids) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    query =
      RequestLog
      |> where([rl], rl.service_id in ^service_ids)
      |> maybe_from(from)
      |> maybe_to(to)
      |> group_by([rl], rl.service_id)
      |> select([rl], %{
        service_id: rl.service_id,
        request_count: count(rl.id),
        error_count: fragment("SUM(CASE WHEN ? >= 400 THEN 1 ELSE 0 END)", rl.status_code),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_read_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms),
        latency_count: fragment("COUNT(?)", rl.latency_ms)
      })

    Repo.all(query, timeout: stats_timeout())
    |> Map.new(fn row ->
      {row.service_id,
       %{
         service_id: row.service_id,
         request_count: row.request_count,
         error_count: row.error_count || 0,
         cost_usd: Decimal.new(to_string(row.cost_usd)),
         prompt_tokens: row.prompt_tokens,
         completion_tokens: row.completion_tokens,
         cache_read_tokens: row.cache_read_tokens,
         avg_latency_ms: compute_avg_latency(row.total_latency_ms, row.latency_count),
         avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
       }}
    end)
  end

  # -----------------------------------------------------------------------
  # breakdown_by_group/1
  # -----------------------------------------------------------------------

  @doc """
  Returns per-group aggregate metrics ranked by total cost (descending).

  Each row is:

      %{
        group_id: binary,
        group_name: String.t(),
        request_count: integer,
        cost_usd: Decimal,  # what the upstream charged for the request
        prompt_tokens: integer,
        completion_tokens: integer,
        cache_read_tokens: integer,
        avg_tps: float | nil
      }

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:provider_id` — restrict to logs served by that provider
  """
  @spec breakdown_by_group(keyword()) :: [map()]
  def breakdown_by_group(opts \\ [])

  def breakdown_by_group(opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    # INNER JOIN member/group: la atribución por GRUPO es exclusiva de los
    # logs con membresía viva — un log rotado no pertenece a ningún grupo
    # actual y un log de servicio tampoco (tiene su propio breakdown). Sin el
    # INNER, filas con group_id nil llegan a consumidores que enlazan por ese
    # id (tab Grupos de /stats) y revientan el route. El dinero rotado sigue
    # contando en las vistas por USUARIO (identidad durable).
    query =
      RequestLog
      |> join(:inner, [rl], tm in GroupMember, on: rl.group_member_id == tm.id)
      |> join(:inner, [_, tm], t in assoc(tm, :group))
      |> maybe_provider_id(Keyword.get(opts, :provider_id))
      |> maybe_model_id(Keyword.get(opts, :model_id))
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> maybe_user_ids(Keyword.get(opts, :user_ids))
      |> group_by([rl, _, t], t.id)
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, _, t], %{
        group_id: t.id,
        group_name: t.name,
        request_count: count(rl.id),
        error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_read_tokens),
        cache_creation_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_creation_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })

    Repo.all(query, timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        group_id: row.group_id,
        group_name: row.group_name,
        request_count: row.request_count,
        error_count: row.error_count || 0,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        cache_read_tokens: row.cache_read_tokens,
        cache_creation_tokens: row.cache_creation_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  # -----------------------------------------------------------------------
  # breakdown_by_provider_for_model/2
  # -----------------------------------------------------------------------

  @doc """
  Returns per-model-provider aggregate metrics for a specific model model,
  ranked by total provider cost (descending).

  Groups by the concrete provider model deployment (`ModelProvider`), so two
  credentials or two provider models under the same provider show up as
  separate rows. Logs predating `model_provider_id` tracking group into a
  single "unknown" row.

  Each row is:

      %{
        model_provider_id: binary | nil,
        provider_name: String.t(),
        provider_model: String.t() | nil,   # actual model name at the provider
        credential_name: String.t() | nil,  # API key model
        request_count: integer,
        cost_usd: Decimal,  # what the upstream charged for the request
        prompt_tokens: integer,
        completion_tokens: integer,
        avg_tps: float | nil
      }

  `model_id` of `nil` returns an empty list.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:member_ids` — restrict to logs of these group-member ids (scoping)
  """
  @spec breakdown_by_provider_for_model(String.t() | nil, keyword()) :: [map()]
  def breakdown_by_provider_for_model(model_id, opts \\ [])

  def breakdown_by_provider_for_model(nil, _opts), do: []

  def breakdown_by_provider_for_model(model_id, opts)
      when is_binary(model_id) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    query =
      RequestLog
      |> where([rl], rl.model_id == ^model_id)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> join(:left, [rl], mp in Tokengate.Providers.ModelProvider,
        on: rl.model_provider_id == mp.id
      )
      |> join(:left, [rl, mp], c in Tokengate.Providers.Credential, on: mp.credential_id == c.id)
      |> join(:left, [rl, mp, c], p in Tokengate.Providers.Provider, on: c.provider_id == p.id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> group_by([rl, mp, c, p], [
        rl.model_provider_id,
        p.id,
        p.name,
        p.logo_url,
        mp.provider_model,
        c.name
      ])
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, mp, c, p], %{
        model_provider_id: rl.model_provider_id,
        provider_id: p.id,
        provider_name: p.name,
        provider_logo_url: p.logo_url,
        provider_model: mp.provider_model,
        credential_name: c.name,
        request_count: count(rl.id),
        error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_read_tokens),
        cache_creation_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_creation_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms),
        avg_latency_ms: fragment("AVG(?)", rl.latency_ms),
        avg_ttft_ms: fragment("AVG(?)", rl.ttft_ms)
      })

    Repo.all(query, timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        model_provider_id: row.model_provider_id,
        provider_id: row.provider_id,
        provider_name: row.provider_name || "—",
        provider_logo_url: row.provider_logo_url,
        provider_model: row.provider_model,
        credential_name: row.credential_name,
        request_count: row.request_count,
        error_count: row.error_count || 0,
        error_rate:
          if(row.request_count > 0,
            do: Float.round((row.error_count || 0) / row.request_count, 4),
            else: 0.0
          ),
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        cache_read_tokens: row.cache_read_tokens,
        cache_creation_tokens: row.cache_creation_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms),
        avg_latency_ms: row.avg_latency_ms && round(to_float!(row.avg_latency_ms)),
        avg_ttft_ms: row.avg_ttft_ms && round(to_float!(row.avg_ttft_ms))
      }
    end)
  end

  # -----------------------------------------------------------------------
  # breakdown_by_member_for_model/2
  # -----------------------------------------------------------------------

  @doc """
  Returns per-member aggregate metrics for a specific model model,
  ranked by total provider cost (descending).

  Each row is:

      %{
        group_member_id: binary,
        user_id: binary,
        group_id: binary,
        group_name: String.t(),
        user_email: String.t(),
        request_count: integer,
        cost_usd: Decimal,  # what the upstream charged for the request
        prompt_tokens: integer,
        completion_tokens: integer,
        avg_tps: float | nil
      }

  `model_id` of `nil` returns an empty list.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:member_ids` — restrict to logs of these group-member ids (scoping)
  """
  @spec breakdown_by_member_for_model(String.t() | nil, keyword()) :: [map()]
  def breakdown_by_member_for_model(model_id, opts \\ [])

  def breakdown_by_member_for_model(nil, _opts), do: []

  def breakdown_by_member_for_model(model_id, opts)
      when is_binary(model_id) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    query =
      RequestLog
      |> where([rl], rl.model_id == ^model_id)
      |> join(:inner, [rl], tm in GroupMember, on: rl.group_member_id == tm.id)
      |> join(:inner, [_, tm], t in assoc(tm, :group))
      |> join(:inner, [_, tm], u in assoc(tm, :user))
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> group_by([rl, tm, t, u], [tm.id, t.id, u.id])
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, tm, t, u], %{
        group_member_id: tm.id,
        user_id: u.id,
        group_id: t.id,
        group_name: t.name,
        user_email: u.email,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })

    Repo.all(query, timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        group_member_id: row.group_member_id,
        user_id: row.user_id,
        group_id: row.group_id,
        group_name: row.group_name,
        user_email: row.user_email,
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  # -----------------------------------------------------------------------
  # breakdown_by_group_for_model/2
  # -----------------------------------------------------------------------

  @doc """
  Returns per-group aggregate metrics for a specific model model,
  ranked by total provider cost (descending).

  Each row is:

      %{
        group_id: binary,
        group_name: String.t(),
        request_count: integer,
        cost_usd: Decimal,  # what the upstream charged for the request
        prompt_tokens: integer,
        completion_tokens: integer,
        avg_tps: float | nil
      }

  `model_id` of `nil` returns an empty list.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
  """
  @spec breakdown_by_group_for_model(String.t() | nil, keyword()) :: [map()]
  def breakdown_by_group_for_model(model_id, opts \\ [])

  def breakdown_by_group_for_model(nil, _opts), do: []

  def breakdown_by_group_for_model(model_id, opts)
      when is_binary(model_id) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    query =
      RequestLog
      |> where([rl], rl.model_id == ^model_id)
      |> join(:inner, [rl], tm in GroupMember, on: rl.group_member_id == tm.id)
      |> join(:inner, [_, tm], t in assoc(tm, :group))
      |> maybe_from(from)
      |> maybe_to(to)
      |> group_by([rl, _, t], t.id)
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, _, t], %{
        group_id: t.id,
        group_name: t.name,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })

    Repo.all(query, timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        group_id: row.group_id,
        group_name: row.group_name,
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  # -----------------------------------------------------------------------
  # provider_ranking/2
  # -----------------------------------------------------------------------

  @min_sample_for_tier 10

  @doc """
  Ranking de proveedores por confiabilidad y velocidad.

  Agrupa `request_logs` por `provider_id` (join directo a `Provider`).
  Fallo = `status_code >= 400` (convención del repo, igual que Alerts).

  Score 0-100: 60% confiabilidad (`1 - error_rate`) + 40% velocidad
  (latencia promedio relativa al proveedor más rápido del período — el
  mejor obtiene 100). Tiers: S ≥ 90, A ≥ 75, B ≥ 60, C ≥ 40, D < 40.

  Proveedores con menos de #{@min_sample_for_tier} requests en el período
  quedan sin score ni tier (`"—"`) y van al final de la lista.
  Proveedores sin logs en el período no aparecen.

  Cada fila:

      %{
        provider_id: binary,
        provider_name: String.t(),
        request_count: integer,
        cost_usd: Decimal,  # what the upstream charged for the request
        error_count: integer,
        error_rate: float,
        avg_latency_ms: integer | nil,
        p95_latency_ms: integer | nil,
        avg_ttft_ms: integer | nil,
        score: integer | nil,
        tier: String.t()
      }

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
  """
  @spec provider_ranking(String.t() | nil, keyword()) :: [map()]
  def provider_ranking(group_id \\ nil, opts \\ [])

  def provider_ranking(group_id, opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    # Aggregate over the FK alone and resolve the catalog row AFTER: grouping
    # over (provider_id, name, key, logo_url, doc_url) forced Postgres to sort
    # every window row by TEXT columns (9.5 MB external merge at 30 days). The
    # uuid-only group key keeps the sort narrow, and the catalog join then runs
    # over one row per provider instead of one per request_log.
    agg =
      RequestLog
      |> where([rl], not is_nil(rl.provider_id))
      |> maybe_join_group(group_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> group_by([rl], rl.provider_id)
      |> select([rl], %{
        provider_id: rl.provider_id,
        request_count: count(),
        error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_read_tokens),
        cache_creation_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_creation_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms),
        avg_latency_ms: fragment("AVG(?)", rl.latency_ms),
        p95_latency_ms:
          fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", rl.latency_ms),
        avg_ttft_ms: fragment("AVG(?)", rl.ttft_ms)
      })

    rows =
      from(a in subquery(agg),
        join: p in Provider,
        on: a.provider_id == p.id,
        select: %{
          provider_id: a.provider_id,
          provider_name: p.name,
          # Identidad del catálogo: viaja con la fila para que la tabla y el
          # detalle puedan pintar el logo y los datos del proveedor sin una
          # segunda query por fila.
          provider_key: p.key,
          provider_logo_url: p.logo_url,
          provider_doc_url: p.doc_url,
          request_count: a.request_count,
          error_count: a.error_count,
          cost_usd: a.cost_usd,
          prompt_tokens: a.prompt_tokens,
          completion_tokens: a.completion_tokens,
          cache_read_tokens: a.cache_read_tokens,
          cache_creation_tokens: a.cache_creation_tokens,
          total_latency_ms: a.total_latency_ms,
          avg_latency_ms: a.avg_latency_ms,
          p95_latency_ms: a.p95_latency_ms,
          avg_ttft_ms: a.avg_ttft_ms
        }
      )
      |> Repo.all(timeout: stats_timeout())

    min_latency =
      rows
      |> Enum.map(& &1.avg_latency_ms)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_float!/1)
      |> case do
        [] -> nil
        latencies -> Enum.min(latencies)
      end

    rows
    |> Enum.map(&score_ranking_row(&1, min_latency))
    |> Enum.sort_by(fn row ->
      {if(row.score, do: 0, else: 1), -(row.score || 0), row.provider_name}
    end)
  end

  defp score_ranking_row(row, min_latency, type \\ :provider) do
    avg_latency = row.avg_latency_ms && to_float!(row.avg_latency_ms)
    error_rate = if row.request_count > 0, do: row.error_count / row.request_count, else: 0.0

    {score, tier} =
      cond do
        row.request_count < @min_sample_for_tier ->
          {nil, "—"}

        is_nil(avg_latency) or avg_latency <= 0 or is_nil(min_latency) ->
          # Sin latencia comparable: score solo por confiabilidad.
          score = round(0.6 * ((1 - error_rate) * 100))
          {score, tier_for(score)}

        true ->
          reliability = (1 - error_rate) * 100
          speed = min_latency / avg_latency * 100
          score = round(0.6 * reliability + 0.4 * speed)
          {score, tier_for(score)}
      end

    base = %{
      request_count: row.request_count,
      error_count: row.error_count,
      error_rate: Float.round(error_rate, 4),
      avg_latency_ms: avg_latency && round(avg_latency),
      p95_latency_ms: row.p95_latency_ms && round(to_float!(row.p95_latency_ms)),
      avg_ttft_ms: row.avg_ttft_ms && round(to_float!(row.avg_ttft_ms)),
      score: score,
      tier: tier
    }

    case type do
      :model ->
        Map.merge(base, %{
          model_id: row.model_id,
          model_name: row.model_name
        })

      _ ->
        cost = Map.get(row, :cost_usd) || Decimal.new(0)
        prompt = Map.get(row, :prompt_tokens) || 0
        completion = Map.get(row, :completion_tokens) || 0
        cache_read = Map.get(row, :cache_read_tokens) || 0
        cache_creation = Map.get(row, :cache_creation_tokens) || 0
        total_latency = Map.get(row, :total_latency_ms) || 0

        Map.merge(base, %{
          provider_id: row.provider_id,
          provider_name: row.provider_name,
          provider_key: Map.get(row, :provider_key),
          provider_logo_url: Map.get(row, :provider_logo_url),
          provider_doc_url: Map.get(row, :provider_doc_url),
          cost_usd: Decimal.new(to_string(cost)),
          prompt_tokens: prompt,
          completion_tokens: completion,
          cache_read_tokens: cache_read,
          cache_creation_tokens: cache_creation,
          avg_tps: compute_tps(completion, total_latency)
        })
    end
  end

  # AVG/percentile_cont vienen de Postgres como float o Decimal según el
  # tipo de la columna — normalizar a float.
  defp to_float!(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float!(n) when is_integer(n), do: n / 1
  defp to_float!(n) when is_float(n), do: n

  defp tier_for(score) when score >= 90, do: "S"
  defp tier_for(score) when score >= 75, do: "A"
  defp tier_for(score) when score >= 60, do: "B"
  defp tier_for(score) when score >= 40, do: "C"
  defp tier_for(_score), do: "D"

  # -----------------------------------------------------------------------
  # model_ranking/2
  # -----------------------------------------------------------------------

  @doc """
  Ranking de models por confiabilidad (fallos) y velocidad (latencia).

  Igual que `provider_ranking/2` pero agrupado por `Model` en vez de
  por proveedor. Devuelve filas con la misma forma para reutilizar el
  rendering del tier y score.

  ## Options
    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:member_ids` — restrict to logs of these group-member ids (scoping)
  """
  @spec model_ranking(String.t() | nil, keyword()) :: [map()]
  def model_ranking(group_id \\ nil, opts \\ [])

  def model_ranking(group_id, opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    # Same shape as provider_ranking/2: aggregate on model_id alone, then join
    # the catalog for the display name. Grouping over `ma.name` made the
    # GroupAggregate sort 148k rows by TEXT (9.5 MB external merge); with the
    # uuid group key the sort key is 16 bytes and the name lookup happens once
    # per model.
    agg =
      RequestLog
      |> where([rl], not is_nil(rl.model_id))
      |> maybe_join_group(group_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> group_by([rl], rl.model_id)
      |> select([rl], %{
        model_id: rl.model_id,
        request_count: count(),
        error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
        avg_latency_ms: fragment("AVG(?)", rl.latency_ms),
        p95_latency_ms:
          fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", rl.latency_ms),
        avg_ttft_ms: fragment("AVG(?)", rl.ttft_ms)
      })

    rows =
      from(a in subquery(agg),
        join: ma in Model,
        on: a.model_id == ma.id,
        select: %{
          model_id: ma.id,
          model_name: ma.name,
          request_count: a.request_count,
          error_count: a.error_count,
          avg_latency_ms: a.avg_latency_ms,
          p95_latency_ms: a.p95_latency_ms,
          avg_ttft_ms: a.avg_ttft_ms
        }
      )
      |> Repo.all(timeout: stats_timeout())

    min_latency =
      rows
      |> Enum.map(& &1.avg_latency_ms)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_float!/1)
      |> case do
        [] -> nil
        latencies -> Enum.min(latencies)
      end

    rows
    |> Enum.map(&score_ranking_row(&1, min_latency, :model))
    |> Enum.sort_by(fn row ->
      {if(row.score, do: 0, else: 1), -(row.score || 0), row.model_name}
    end)
  end

  # -----------------------------------------------------------------------
  # usage_by_hour_of_day/2
  # -----------------------------------------------------------------------

  @doc """
  Distribución de requests por hora del día (hora local del timezone),
  agregada sobre el período. Devuelve siempre 24 filas (horas 0-23) con
  zero-fill — sirve para ver patrones recurrentes de uso ("¿a qué horas
  se usa más?").

  Cada fila: `%{hour: 0..23, request_count: integer}`.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:member_ids` — restrict to logs of these group-member ids (scoping)
    * `:timezone` — IANA zone for the hour-of-day extraction; default `"Etc/UTC"`
  """
  @spec usage_by_hour_of_day(String.t() | nil, keyword()) :: [map()]
  def usage_by_hour_of_day(group_id \\ nil, opts \\ []) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    counts =
      RequestLog
      |> maybe_join_group(group_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> select([rl], %{
        hour:
          fragment(
            "CAST(EXTRACT(hour FROM (? AT TIME ZONE 'Etc/UTC') AT TIME ZONE ?) AS integer)",
            rl.inserted_at,
            ^timezone
          ),
        id: rl.id
      })
      |> subquery()
      |> then(fn subq ->
        from(h in subq, group_by: h.hour, select: %{hour: h.hour, request_count: count(h.id)})
      end)
      |> Repo.all(timeout: stats_timeout())
      |> Map.new(fn row -> {row.hour, row.request_count} end)

    for hour <- 0..23 do
      %{hour: hour, request_count: Map.get(counts, hour, 0)}
    end
  end

  # -----------------------------------------------------------------------
  # usage_by_hour_of_day_by_provider/1
  # -----------------------------------------------------------------------

  @doc """
  Perfil horario del período, desglosado por proveedor — la misma tarjeta
  que "Hoy por hora · por proveedor" de En vivo, agregada sobre la ventana
  del Resumen. (Con el período "Hoy" el Resumen NO pasa por acá: ese día lo
  dibuja con el agregado del día UTC en curso,
  `Tokengate.Logs.today_usage_by_hour_provider/0`, para que mida la misma
  ventana que sus KPI y que el tope global.)

  Devuelve siempre las 24 horas (`0..23`, zero-filled, para que el eje se
  dibuje siempre). La hora es la **local del timezone**, no UTC: el Resumen
  pregunta "¿a qué horas se usa?" sobre el período entero, y esa lectura es
  la del usuario. Cada fila:

      %{
        hour: 0..23,
        total_requests: integer,
        total_cost_usd: Decimal.t(),      # suma de costos cobrados
        providers: [
          %{
            provider_name: String.t(),
            requests: integer,
            cost_usd: Decimal.t()
          }
        ]
      }

  `providers` va ordenado por requests desc (el frontend apila en ese
  orden). Los logs sin `provider_id` caen en "sin proveedor".

  Barata por el mismo camino que la de En vivo: **una** consulta agregada
  agrupada por (hora, proveedor), sin joins — los nombres se resuelven
  después, en una segunda consulta acotada a los ids que aparecieron. La
  salida es idéntica a la de `Logs.today_usage_by_hour_provider/0` para que
  las DOS pestañas alimenten la misma gráfica.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:member_ids` — restrict to logs of these group-member ids (scoping)
    * `:timezone` — IANA zone for the hour-of-day extraction; default `"Etc/UTC"`
  """
  @spec usage_by_hour_of_day_by_provider(keyword()) :: [map()]
  def usage_by_hour_of_day_by_provider(opts \\ []) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    # El bucket horario se materializa en la subquery (misma razón que en
    # `hourly_series/2`: Postgres trata `date_trunc(... AT TIME ZONE $1)` del
    # SELECT y del GROUP BY como expresiones distintas por ir con parámetros
    # separados, y exige que la columna "aparezca" en el GROUP BY).
    #
    # El nombre del proveedor tampoco entra al agregado: resolverlo exige un
    # JOIN por cada fila del período. Se agrupa por `provider_id` — lo único
    # que identifica al proveedor — y el nombre se resuelve después, sobre las
    # ~16 filas (hora × proveedor) del resultado.
    bucketed =
      RequestLog
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> select([rl], %{
        hour:
          fragment(
            "CAST(EXTRACT(hour FROM (? AT TIME ZONE 'Etc/UTC') AT TIME ZONE ?) AS integer)",
            rl.inserted_at,
            ^timezone
          ),
        provider_id: rl.provider_id,
        id: rl.id,
        cost_usd: rl.provider_cost_usd
      })
      |> subquery()

    rows =
      from(b in bucketed,
        group_by: [b.hour, b.provider_id],
        select: %{
          hour: b.hour,
          provider_id: b.provider_id,
          cost_usd: fragment("COALESCE(SUM(?), 0)", b.cost_usd),
          request_count: fragment("count(*)")
        }
      )
      |> Repo.all(timeout: stats_timeout())

    hour_provider_profile(rows)
  end

  @doc """
  Ensambla el perfil hora × proveedor a partir de filas planas
  `%{hour, provider_id, request_count, cost_usd}` — las 24 horas siempre
  presentes, proveedores colapsados por nombre. Pública porque el lado
  híbrido (`StatsQueries`) alimenta el mismo ensamblador con rollup + cola
  cruda en vez de un escaneo completo de `request_logs`.
  """
  def hour_provider_profile(rows) do
    identities = provider_identity_by_id(rows)
    by_hour = Enum.group_by(rows, & &1.hour)

    for hour <- 0..23 do
      # Varios `provider_id` pueden compartir nombre (o no tener nombre): se
      # colapsan en una sola fila del desglose, como en el resto de las
      # gráficas apiladas del hub.
      providers =
        by_hour
        |> Map.get(hour, [])
        |> Enum.map(&with_provider_identity(&1, identities))
        |> Enum.group_by(& &1.provider_name)
        |> Enum.map(fn {provider_name, entries} ->
          %{
            provider_name: provider_name,
            # El logo también se colapsa: si dos ids comparten nombre, sirve
            # cualquiera de los dos que traiga logo del catálogo.
            provider_logo_url: Enum.find_value(entries, & &1.provider_logo_url),
            requests: Enum.reduce(entries, 0, &(&1.requests + &2)),
            cost_usd:
              Enum.reduce(entries, Decimal.new(0), fn e, acc ->
                Decimal.add(acc, e.cost_usd)
              end)
          }
        end)
        |> Enum.sort_by(& &1.requests, :desc)

      %{
        hour: hour,
        total_requests: Enum.reduce(providers, 0, &(&1.requests + &2)),
        total_cost_usd:
          Enum.reduce(providers, Decimal.new(0), fn p, acc -> Decimal.add(acc, p.cost_usd) end),
        providers: providers
      }
    end
  end

  # Identidad de cada proveedor presente en las filas agregadas (nombre y logo
  # del catálogo), en una sola consulta. Un id nil o ya borrado cae al
  # `@no_provider` del llamador en vez de desaparecer del gráfico.
  defp provider_identity_by_id(rows) do
    ids = rows |> Enum.map(& &1.provider_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case ids do
      [] ->
        %{}

      ids ->
        from(p in Provider, where: p.id in ^ids, select: {p.id, p.name, p.logo_url})
        |> Repo.all(timeout: stats_timeout())
        |> Map.new(fn {id, name, logo_url} -> {id, %{name: name, logo_url: logo_url}} end)
    end
  end

  defp with_provider_identity(row, identities) do
    identity = Map.get(identities, row.provider_id, %{name: @no_provider, logo_url: nil})

    %{
      provider_name: identity.name || @no_provider,
      provider_logo_url: identity.logo_url,
      requests: row.request_count,
      cost_usd: Decimal.new(to_string(row.cost_usd))
    }
  end

  # -----------------------------------------------------------------------
  # usage_by_model_provider_stacked/2
  # -----------------------------------------------------------------------

  @doc """
  Requests agrupados por model model, con desglose por proveedor (ModelProvider).

  Devuelve una lista de models, cada uno con su total de requests y la lista
  de proveedores que lo sirvieron (con requests y costo).

  Las barras horizontales de la gráfica de stats usan esta data: una barra
  por modelo, segmentos apilados por proveedor.

  ## Opciones

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:member_ids` — restrict to logs of these group-member ids (scoping)
  """
  @spec usage_by_model_provider_stacked(keyword()) :: [map()]
  def usage_by_model_provider_stacked(opts \\ []) do
    model_provider_stacked(model_provider_flat_rows(opts), Keyword.take(opts, [:sort_by, :limit]))
  end

  @doc """
  Filas planas modelo × proveedor (una por ruta usada) sobre `request_logs`:
  `%{model_id, model_name, provider_id, provider_stats_id, provider_name,
  provider_logo_url, request_count, cost_usd}`. Pública porque el híbrido
  (`StatsQueries`) la reusa acotada a la cola fresca.
  """
  def model_provider_flat_rows(opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    RequestLog
    |> maybe_from(from)
    |> maybe_to(to)
    |> maybe_member_ids(Keyword.get(opts, :member_ids))
    |> join(:left, [rl], ma in Model, on: rl.model_id == ma.id)
    |> join(:left, [rl, ma], mp in Tokengate.Providers.ModelProvider,
      on: rl.model_provider_id == mp.id
    )
    |> join(:left, [rl, ma, mp], c in Tokengate.Providers.Credential,
      on: mp.credential_id == c.id
    )
    |> join(:left, [rl, ma, mp, c], p in Tokengate.Providers.Provider, on: c.provider_id == p.id)
    |> group_by(
      [rl, ma, mp, c, p],
      [ma.id, ma.name, mp.id, p.id, p.name, p.logo_url]
    )
    |> select(
      [rl, ma, mp, c, p],
      %{
        model_id: ma.id,
        model_name: ma.name,
        provider_id: mp.id,
        # Id del PROVEEDOR (no del model_provider): es el que abre su
        # detalle en /stats/providers/:id desde el Resumen.
        provider_stats_id: p.id,
        provider_name: p.name,
        provider_logo_url: p.logo_url,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)
      }
    )
    |> Repo.all(timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        model_id: row.model_id,
        model_name: row.model_name || "—",
        provider_id: row.provider_id,
        provider_stats_id: row.provider_stats_id,
        provider_name: row.provider_name || "—",
        provider_logo_url: row.provider_logo_url,
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd))
      }
    end)
  end

  @doc """
  Ensambla la gráfica apilada modelo × proveedor a partir de filas planas
  `%{model_id, model_name, provider_id, provider_stats_id, provider_name,
  provider_logo_url, request_count, cost_usd}`. Pública por la misma razón
  que `hour_provider_profile/1`: el híbrido la alimenta con rollup + cola.
  """
  def model_provider_stacked(rows, opts \\ []) do
    sort_by = Keyword.get(opts, :sort_by, :requests)
    limit = Keyword.get(opts, :limit, 10)

    # Agrupar por modelo
    grouped =
      rows
      |> Enum.group_by(& &1.model_id)
      |> Enum.map(fn {model_id, entries} ->
        model_name = List.first(entries).model_name

        providers =
          entries
          |> Enum.group_by(&{&1.provider_id, &1.provider_name})
          |> Enum.map(fn {{_pid, provider_name}, p_entries} ->
            requests = Enum.reduce(p_entries, 0, &(&1.request_count + &2))

            cost =
              Enum.reduce(p_entries, Decimal.new(0), fn e, acc ->
                Decimal.add(acc, e.cost_usd)
              end)

            %{
              provider_name: provider_name,
              provider_stats_id: List.first(p_entries).provider_stats_id,
              provider_logo_url: Enum.find_value(p_entries, & &1.provider_logo_url),
              requests: requests,
              cost_usd: cost
            }
          end)
          |> Enum.sort_by(& &1.requests, :desc)

        total_requests = Enum.reduce(providers, 0, &(&1.requests + &2))

        total_cost =
          Enum.reduce(providers, Decimal.new(0), fn p, acc -> Decimal.add(acc, p.cost_usd) end)

        %{
          model_id: model_id,
          model_name: model_name,
          total_requests: total_requests,
          total_cost_usd: total_cost,
          providers: providers
        }
      end)

    sorted =
      case sort_by do
        :cost ->
          Enum.sort(grouped, fn a, b ->
            case Decimal.compare(a.total_cost_usd, b.total_cost_usd) do
              :eq -> a.total_requests >= b.total_requests
              :gt -> true
              :lt -> false
            end
          end)

        _ ->
          Enum.sort_by(grouped, & &1.total_requests, :desc)
      end

    if is_integer(limit), do: Enum.take(sorted, limit), else: sorted
  end

  # -----------------------------------------------------------------------
  # busiest_hours/2 y busiest_minutes/2
  # -----------------------------------------------------------------------

  @doc """
  Top N horas (buckets `date_trunc('hour')`) con más requests en el
  período, ordenadas desc. Cada fila: `%{bucket: DateTime, request_count}`.
  """
  @spec busiest_hours(String.t() | nil, keyword()) :: [map()]
  def busiest_hours(group_id \\ nil, opts \\ []),
    do: busiest_buckets(group_id, "hour", opts)

  @doc """
  Top N minutos (buckets `date_trunc('minute')`) con más requests en el
  período, ordenados desc. Cada fila: `%{bucket: DateTime, request_count}`.
  """
  @spec busiest_minutes(String.t() | nil, keyword()) :: [map()]
  def busiest_minutes(group_id \\ nil, opts \\ []),
    do: busiest_buckets(group_id, "minute", opts)

  # The local-day bucket is computed ONCE per row (`date_trunc(?, ts AT TIME
  # ZONE tz)` -> a local timestamp) and converted back to timestamptz once per
  # GROUP, in the outer query: the round-trip conversion is the expensive half
  # and it only has to run over the distinct buckets, not over every log. Both
  # layers are needed because Postgres only matches the group key when the
  # expression is textually identical, and the ORDER BY tie-break must keep
  # ordering by the CONVERTED bucket (the timestamptz the caller sees) so the
  # top-N at a count tie is unchanged.
  defp busiest_buckets(group_id, unit, opts) when unit in ["hour", "minute"] do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    limit = Keyword.get(opts, :limit, 5)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    metric = Keyword.get(opts, :metric, :requests)

    bucketed =
      RequestLog
      |> maybe_join_group(group_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> select([rl], %{
        bucket: fragment("date_trunc(?, ? AT TIME ZONE ?)", ^unit, rl.inserted_at, ^timezone),
        provider_cost_usd: rl.provider_cost_usd
      })
      |> subquery()

    counts =
      from(b in bucketed,
        group_by: b.bucket,
        select: %{
          bucket: b.bucket,
          request_count: count(),
          cost_usd: fragment("COALESCE(SUM(?), 0)", b.provider_cost_usd)
        }
      )
      |> subquery()

    ordered =
      case metric do
        :cost ->
          order_by(counts, [c],
            desc: c.cost_usd,
            desc: c.request_count,
            asc: fragment("? AT TIME ZONE ?", c.bucket, ^timezone)
          )

        _ ->
          order_by(counts, [c],
            desc: c.request_count,
            asc: fragment("? AT TIME ZONE ?", c.bucket, ^timezone)
          )
      end

    from(c in ordered,
      limit: ^limit,
      select: %{
        bucket: fragment("? AT TIME ZONE ?", c.bucket, ^timezone),
        request_count: c.request_count,
        cost_usd: c.cost_usd
      }
    )
    |> Repo.all(timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        bucket: to_utc_datetime(row.bucket),
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd))
      }
    end)
  end

  # -----------------------------------------------------------------------
  # peak_concurrency/2
  # -----------------------------------------------------------------------

  @doc """
  Estima el pico de requests concurrentes en el período.

  `request_logs` no persiste concurrencia — se reconstruye a partir del
  intervalo de vuelo de cada request: `[inserted_at - latency_ms, inserted_at]`
  (el log se escribe al completar). Un sweep line sobre los eventos +1/-1
  da el máximo traslape. Requests con `latency_ms` nil cuentan como
  instantáneos en su `inserted_at`.

  Devuelve `%{max_concurrent: integer, at: DateTime | nil}` — `at` es el
  primer momento en que se alcanzó el máximo; nil si no hubo requests.

  El sweep corre en Postgres (suma acumulativa sobre los eventos ordenados),
  no en memoria de la BEAM: la versión anterior cargaba `(inserted_at,
  latency_ms)` de todo el período y ordenaba en Elixir, lo que a 90 días
  sobre un millón de filas costaba segundos de CPU y cientos de MB por
  recarga. El resultado es idéntico — incluido el empate a favor de los
  finales (-1) sobre los inicios (+1) en el mismo timestamp.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
  """
  @spec peak_concurrency(String.t() | nil, keyword()) :: map()
  def peak_concurrency(group_id \\ nil, opts \\ []) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    base =
      RequestLog
      |> maybe_join_group(group_id)
      |> maybe_from(from)
      |> maybe_to(to)

    # Cada log aporta dos eventos: su inicio (+1) y su fin (-1). El inicio
    # retrocede `latency_ms`; `nil` = instantáneo (mismo ts que el fin).
    starts =
      from(rl in base,
        select: %{
          ts:
            fragment(
              "? - (COALESCE(?, 0) * interval '1 millisecond')",
              rl.inserted_at,
              rl.latency_ms
            ),
          delta: 1
        }
      )

    ends = from(rl in base, select: %{ts: rl.inserted_at, delta: -1})

    # El orden del window reproduce el del sweep en Elixir: por timestamp y,
    # en empate, los finales (-1) antes que los inicios (+1) — un request que
    # termina justo cuando otro empieza no cuenta como concurrente.
    runs =
      from(e in subquery(union_all(starts, ^ends)),
        select: %{
          ts: e.ts,
          run: over(sum(e.delta), order_by: [asc: e.ts, asc: e.delta])
        }
      )

    # El pico es el mayor `run`; `at` el primer ts que lo alcanzó. Un `run`
    # máximo solo puede venir de un evento +1 (un -1 lo habría superado
    # antes), así que ordenar por ts ascendente da el primer instante real.
    from(r in subquery(runs),
      order_by: [desc: r.run, asc: r.ts],
      limit: 1,
      select: %{max_concurrent: r.run, at: r.ts}
    )
    |> Repo.one(timeout: stats_timeout())
    |> case do
      nil -> %{max_concurrent: 0, at: nil}
      row -> %{max_concurrent: row.max_concurrent, at: to_utc_datetime(row.at)}
    end
  end

  # -----------------------------------------------------------------------
  # member_usage_tiers/2
  # -----------------------------------------------------------------------

  @doc """
  Clasifica a los miembros de un perfil de límites en 3 tiers de uso: alto, regular, bajo.

  Combina volumen (tokens, costo, requests), frecuencia (días activos),
  y concurrencia (pico de requests simultáneos por minuto) en un score
  compuesto 0-100. Después aplica terciles para dividir en 3 grupos.

  ## Clasificación

    * `"alto"`   — score ≥ 66 (tercil superior)
    * `"regular"` — score 33-65 (tercil medio)
    * `"bajo"`   — score < 33 (tercil inferior) o sin actividad

  ## Métricas por miembro

      %{
        group_member_id: binary,
        group_name: String.t(),
        user_email: String.t(),
        user_name: String.t() | nil,
        request_count: integer,
        cost_usd: Decimal,
        prompt_tokens: integer,
        completion_tokens: integer,
        active_days: integer,        # días distintos con al menos 1 request
        peak_rpm: integer,            # máximo requests en 1 minuto
        avg_rpm: float,              # promedio de requests por minuto activo
        p95_rpm: integer,             # percentil 95 de RPM (sostenido)
        score: integer,               # 0-100 compuesto
        tier: String.t()              # "alto" | "regular" | "bajo"
      }

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:member_ids` — restrict to logs of these group-member ids (scoping)
  """
  @spec member_usage_tiers(String.t() | nil, keyword()) :: [map()]
  def member_usage_tiers(group_id \\ nil, opts \\ []) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    base_query =
      RequestLog
      |> join(:inner, [rl], tm in GroupMember, on: rl.group_member_id == tm.id)
      |> join(:inner, [_, tm], t in assoc(tm, :group))
      |> join(:inner, [_, tm], u in assoc(tm, :user))
      |> maybe_member_group_filter(group_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))

    # Base aggregates per member
    members =
      base_query
      |> group_by([rl, tm, t, u], [tm.id, t.name, u.email, u.name])
      |> select([rl, tm, t, u], %{
        group_member_id: tm.id,
        group_name: t.name,
        user_email: u.email,
        user_name: u.name,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        active_days:
          fragment(
            "COUNT(DISTINCT date_trunc('day', ?))",
            rl.inserted_at
          )
      })
      |> Repo.all(timeout: stats_timeout())
      |> Enum.map(fn row ->
        Map.put(row, :cost_usd, Decimal.new(to_string(row.cost_usd)))
      end)

    member_ids = Enum.map(members, & &1.group_member_id)

    # RPM stats per member (peak, avg, p95)
    rpm_stats = rpm_stats_per_member(member_ids, from, to)

    # Merge and compute score + tier
    members
    |> Enum.map(fn member ->
      stats = Map.get(rpm_stats, member.group_member_id, %{})

      member
      |> Map.merge(%{
        peak_rpm: Map.get(stats, :peak_rpm, 0),
        avg_rpm: Map.get(stats, :avg_rpm, 0.0),
        p95_rpm: Map.get(stats, :p95_rpm, 0)
      })
    end)
    |> assign_scores_and_tiers()
  end

  defp rpm_stats_per_member([], _from, _to), do: %{}

  # Buckets (member × minute) stay in Postgres: the outer aggregate turns
  # them into one row per member with max/avg/p95 — the BEAM no longer
  # materializes 50k-200k bucket rows for a 30-day window just to sort
  # them per member. `percentile_disc(0.95)` over the per-minute counts is
  # the same nearest-rank p95 the old `Enum.sort` + `ceil(0.95 * count)`
  # computed.
  defp rpm_stats_per_member(member_ids, from, to) do
    minute_buckets =
      RequestLog
      |> where([rl], rl.group_member_id in ^member_ids)
      |> maybe_from(from)
      |> maybe_to(to)
      |> group_by([rl], [rl.group_member_id, fragment("date_trunc('minute', ?)", rl.inserted_at)])
      |> select([rl], %{
        group_member_id: rl.group_member_id,
        rpm: count(rl.id)
      })
      |> subquery()

    stats =
      from(b in minute_buckets,
        group_by: b.group_member_id,
        select: %{
          group_member_id: b.group_member_id,
          bucket_count: count(b.rpm),
          peak_rpm: max(b.rpm),
          avg_rpm: fragment("AVG(?)", b.rpm),
          p95_rpm: fragment("percentile_disc(0.95) WITHIN GROUP (ORDER BY ?)", b.rpm)
        }
      )
      |> Repo.all(timeout: stats_timeout())

    stats
    |> Map.new(fn row ->
      avg_rpm =
        row.avg_rpm && row.avg_rpm |> Decimal.to_float() |> Float.round(1)

      # Same thin-sample rule as before: with <20 buckets the sample is too
      # sparse for a percentile — the peak is the honest figure.
      p95_rpm = if row.bucket_count < 20, do: row.peak_rpm, else: row.p95_rpm

      {row.group_member_id, %{peak_rpm: row.peak_rpm, avg_rpm: avg_rpm || 0.0, p95_rpm: p95_rpm}}
    end)
  end

  defp assign_scores_and_tiers(members) when members == [], do: []

  defp assign_scores_and_tiers(members) do
    # Compute max values for normalization
    max_tokens =
      members |> Enum.map(&(&1.prompt_tokens + &1.completion_tokens)) |> Enum.max(fn -> 1 end)

    max_cost = members |> Enum.map(&Decimal.to_float(&1.cost_usd)) |> Enum.max(fn -> 1.0 end)
    max_requests = members |> Enum.map(& &1.request_count) |> Enum.max(fn -> 1 end)
    max_active_days = members |> Enum.map(& &1.active_days) |> Enum.max(fn -> 1 end)
    max_peak_rpm = members |> Enum.map(& &1.peak_rpm) |> Enum.max(fn -> 1 end)
    max_p95_rpm = members |> Enum.map(& &1.p95_rpm) |> Enum.max(fn -> 1 end)

    members
    |> Enum.map(fn m ->
      total_tokens = m.prompt_tokens + m.completion_tokens
      cost_float = Decimal.to_float(m.cost_usd)

      # Weighted score 0-100
      score =
        round(
          0.25 * normalize(total_tokens, max_tokens) +
            0.20 * normalize(cost_float, max_cost) +
            0.15 * normalize(m.request_count, max_requests) +
            0.15 * normalize(m.active_days, max_active_days) +
            0.15 * normalize(m.peak_rpm, max_peak_rpm) +
            0.10 * normalize(m.p95_rpm, max_p95_rpm)
        )

      tier =
        cond do
          score >= 66 -> "alto"
          score >= 33 -> "regular"
          true -> "bajo"
        end

      Map.merge(m, %{score: score, tier: tier})
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp normalize(value, max) when max > 0, do: min(value / max * 100, 100.0)
  defp normalize(_value, _max), do: 0.0

  # -----------------------------------------------------------------------
  # top_errors/2
  # -----------------------------------------------------------------------

  @doc """
  Top códigos de error HTTP en el período (status_code >= 400, la
  convención de fallo del repo), ordenados por cantidad desc.

  Cada fila: `%{status_code: integer, error_count: integer}`.

  ## Options

    * `:from`  — `inserted_at >= from` (DateTime)
    * `:to`    — `inserted_at <= to` (DateTime)
    * `:limit` — default 5
    * `:member_ids` — restrict to logs of these group-member ids (scoping)
  """
  @spec top_errors(String.t() | nil, keyword()) :: [map()]
  def top_errors(group_id \\ nil, opts \\ []) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    limit = Keyword.get(opts, :limit, 5)

    RequestLog
    |> where([rl], rl.status_code >= 400)
    |> maybe_join_group(group_id)
    |> maybe_from(from)
    |> maybe_to(to)
    |> maybe_member_ids(Keyword.get(opts, :member_ids))
    |> group_by([rl], rl.status_code)
    |> order_by([rl], desc: count(rl.id), asc: rl.status_code)
    |> limit(^limit)
    |> select([rl], %{
      status_code: rl.status_code,
      error_count: count(rl.id)
    })
    |> Repo.all(timeout: stats_timeout())
  end

  # -----------------------------------------------------------------------
  # hourly_series_for_model/2
  # -----------------------------------------------------------------------

  @doc """
  Returns an hour-bucketed series for a specific model model, including
  token breakdown and cost. Used by the cost calculator to compare real
  spend vs estimated spend.

  Each row is:

      %{
        hour: DateTime,
        request_count: integer,
        prompt_tokens: integer,
        completion_tokens: integer,
        cache_read_tokens: integer,
        cache_creation_tokens: integer,
        cost_usd: Decimal   # real provider cost (included + pay_per_token)
      }

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:model_provider_id` — restrict to one lane (`request_logs.model_provider_id`)
    * `:credential_id` — restrict to one credential (`request_logs.credential_id`)
    * `:timezone` — IANA zone for local-hour bucketing; default `"Etc/UTC"`

  Without `:model_provider_id` / `:credential_id` the series covers every lane
  of the model, exactly as before those opts existed.
  """
  @spec hourly_series_for_model(String.t() | nil, keyword()) :: [map()]
  def hourly_series_for_model(model_id, opts \\ [])

  def hourly_series_for_model(nil, _opts), do: []

  def hourly_series_for_model(model_id, opts) when is_binary(model_id) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    bucketed =
      RequestLog
      |> where([rl], rl.model_id == ^model_id)
      |> maybe_model_provider_id(Keyword.get(opts, :model_provider_id))
      |> maybe_credential_id(Keyword.get(opts, :credential_id))
      |> maybe_from(from)
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
        provider_cost_usd: rl.provider_cost_usd,
        prompt_tokens: rl.prompt_tokens,
        completion_tokens: rl.completion_tokens,
        cache_read_tokens: rl.cache_read_tokens,
        cache_creation_tokens: rl.cache_creation_tokens
      })
      |> subquery()

    query =
      from(b in bucketed,
        group_by: b.bucket,
        order_by: b.bucket,
        select: %{
          hour: b.bucket,
          request_count: count(b.id),
          cost_usd: fragment("COALESCE(SUM(?), 0)", b.provider_cost_usd),
          prompt_tokens: coalesce(sum(b.prompt_tokens), 0),
          completion_tokens: coalesce(sum(b.completion_tokens), 0),
          cache_read_tokens: coalesce(sum(b.cache_read_tokens), 0),
          cache_creation_tokens: coalesce(sum(b.cache_creation_tokens), 0)
        }
      )

    Repo.all(query, timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        hour: to_utc_datetime(row.hour),
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        cache_read_tokens: row.cache_read_tokens,
        cache_creation_tokens: row.cache_creation_tokens
      }
    end)
  end

  # -----------------------------------------------------------------------
  # Rollup-backed reads (request_metrics_hourly)
  #
  # All of these are rollup-first with a request_logs fallback when the
  # rollup returns no rows for the range (fresh deploy before the initial
  # backfill, or genuinely no traffic — in both cases the fallback query
  # is cheap). Once `Metrics.RollupWorker` / the backfill has populated
  # the range, reads sum ≤ 24×days×dimensions rollup rows instead of
  # scanning every request log in range.
  # -----------------------------------------------------------------------

  @doc """
  Member-scoped hour-bucketed series, served from the
  `request_metrics_hourly` rollup with a `request_logs` fallback.

  Same row shape as `hourly_series/2`:

      %{hour: DateTime, request_count: integer, cost_usd: Decimal,
        prompt_tokens: integer, completion_tokens: integer,
        total_latency_ms: integer}

  `member_ids` of `[]` short-circuits to `[]` (same contract as the old
  DashboardLive implementation).

  ## Options

    * `:from` — DateTime (required)
    * `:to`   — DateTime (optional upper bound)
    * `:timezone` — IANA zone for local-hour bucketing; default `"Etc/UTC"`
  """
  @spec hourly_series_for_members([term()], keyword(), String.t()) :: [map()]
  def hourly_series_for_members(member_ids, opts \\ [], timezone \\ "Etc/UTC")
      when is_list(member_ids) do
    case hourly_series_from_rollup(
           Keyword.merge(opts, timezone: timezone, member_ids: member_ids)
         ) do
      [] when member_ids != [] ->
        request_logs_series_for_members(member_ids, opts, timezone)

      [] ->
        []

      rows ->
        rows
    end
  end

  @doc """
  Same as `hourly_series_for_members/3`, but scoped by **user id** — the
  durable identity (`request_logs.user_id`). Survives membership rotation:
  a log written under a since-deleted membership still counts for its user,
  both in the rollup half (`user_id` bucket dimension) and in the raw
  fallback.

  `[]` when `user_ids` is `[]`.
  """
  def hourly_series_for_users(user_ids, opts \\ [], timezone \\ "Etc/UTC")
      when is_list(user_ids) do
    case hourly_series_from_rollup(Keyword.merge(opts, timezone: timezone, user_ids: user_ids)) do
      [] when user_ids != [] ->
        request_logs_series_for_users(user_ids, opts, timezone)

      [] ->
        []

      rows ->
        rows
    end
  end

  @doc """
  Hour-bucketed series served directly from the `request_metrics_hourly`
  rollup table (no fallback). See `hourly_series_for_members/3`.

  ## Options

    * `:from` — DateTime (required)
    * `:to`   — DateTime (optional)
    * `:timezone` — IANA zone; default `"Etc/UTC"`
    * `:member_ids` — restrict to these group-member ids; `nil` = org-wide
  """
  @spec hourly_series_from_rollup(keyword()) :: [map()]
  def hourly_series_from_rollup(opts \\ []) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.get(opts, :to)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    member_ids = Keyword.get(opts, :member_ids)
    user_ids = Keyword.get(opts, :user_ids)

    bucketed =
      RequestMetricsHourly
      |> maybe_rollup_from(from)
      |> maybe_rollup_to(to)
      |> maybe_rollup_member_ids(member_ids)
      |> maybe_rollup_user_ids(user_ids)
      |> select([m], %{
        bucket:
          fragment(
            "date_trunc('hour', ? AT TIME ZONE 'Etc/UTC') AT TIME ZONE ?",
            m.hour_utc,
            ^timezone
          ),
        request_count: m.request_count,
        cost_micro: m.cost_micro,
        prompt_tokens: m.prompt_tokens,
        completion_tokens: m.completion_tokens,
        total_latency_ms: m.total_latency_ms
      })
      |> subquery()

    from(b in bucketed,
      group_by: b.bucket,
      order_by: b.bucket,
      select: %{
        hour: b.bucket,
        request_count: fragment("COALESCE(SUM(?), 0)::bigint", b.request_count),
        cost_usd: fragment("COALESCE(SUM(?), 0)::bigint", b.cost_micro),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", b.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", b.completion_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)::bigint", b.total_latency_ms)
      }
    )
    |> Repo.all(timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        hour: to_utc_datetime(row.hour),
        request_count: row.request_count,
        cost_usd: micro_to_decimal(row.cost_usd),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        total_latency_ms: row.total_latency_ms
      }
    end)
  end

  # request_logs fallback for hourly_series_for_members/3 — the exact query
  # DashboardLive used before the rollup existed. Kept here (not in the
  # LiveView) so the parity is testable in one place.
  defp request_logs_series_for_members(member_ids, opts, timezone) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.get(opts, :to)

    # Bucket by LOCAL hour (same subquery rationale as hourly_series/2:
    # Postgres rejects parametrized GROUP BY vs SELECT).
    bucketed =
      RequestLog
      |> where([rl], rl.group_member_id in ^member_ids and rl.inserted_at >= ^from)
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
        provider_cost_usd: rl.provider_cost_usd,
        prompt_tokens: rl.prompt_tokens,
        completion_tokens: rl.completion_tokens,
        latency_ms: rl.latency_ms
      })
      |> subquery()

    series_from_bucketed(bucketed)
  end

  # Raw fallback scoped by user id — same shape, durable identity. Logs whose
  # membership was rotated (group_member_id NULL) still match here.
  defp request_logs_series_for_users(user_ids, opts, timezone) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.get(opts, :to)

    bucketed =
      RequestLog
      |> where([rl], rl.user_id in ^user_ids and rl.inserted_at >= ^from)
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
        provider_cost_usd: rl.provider_cost_usd,
        prompt_tokens: rl.prompt_tokens,
        completion_tokens: rl.completion_tokens,
        latency_ms: rl.latency_ms
      })
      |> subquery()

    series_from_bucketed(bucketed)
  end

  defp series_from_bucketed(bucketed) do
    query =
      from(b in bucketed,
        group_by: b.bucket,
        order_by: b.bucket,
        select: %{
          hour: b.bucket,
          request_count: count(b.id),
          cost_usd: fragment("COALESCE(SUM(?), 0)", b.provider_cost_usd),
          prompt_tokens: coalesce(sum(b.prompt_tokens), 0),
          completion_tokens: coalesce(sum(b.completion_tokens), 0),
          total_latency_ms: coalesce(sum(b.latency_ms), 0)
        }
      )

    Repo.all(query, timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        hour: to_utc_datetime(row.hour),
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        total_latency_ms: row.total_latency_ms
      }
    end)
  end

  @doc """
  Member-scoped cost/token summary, rollup-first with a request_logs
  fallback. Same shape as `Logs.cost_summary_for_members/2` plus
  `:error_count`:

      %{total_cost_usd: Decimal, ..., request_count: integer, error_count: integer}

  ## Options

    * `:from` / `:to` — DateTime range (`:from` required)
    * `:member_ids` — `nil` = org-wide; `[]` returns zeroes without querying
  """
  @spec summary_for_members(keyword()) :: map()
  def summary_for_members(opts \\ []) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.get(opts, :to)
    member_ids = Keyword.get(opts, :member_ids)

    cond do
      member_ids == [] ->
        zero_summary()

      true ->
        summary = summary_from_rollup(from: from, to: to, member_ids: member_ids)

        if summary.request_count == 0 do
          # No rollup rows for the range (fresh deploy before the initial
          # backfill, or genuinely no traffic) — fall back to the
          # request_logs aggregation, same contract as before the rollup.
          fallback_summary_for_members(member_ids, from, to)
        else
          summary
        end
    end
  end

  defp fallback_summary_for_members(member_ids, from, to) do
    member_ids
    |> Logs.cost_summary_for_members(%{from: from, to: to})
    |> Map.merge(%{error_count: 0})
  end

  @doc """
  Summary served directly from the `request_metrics_hourly` rollup (no
  fallback). Costs are exact-integer micro-USD sums converted back to
  Decimal — bounded rounding error of 1 micro-dollar per
  hour-bucket-dimension, invisible at dashboard precision.

  ## Options

    * `:from` / `:to` — DateTime range
    * `:member_ids` — `nil` = org-wide
  """
  @spec summary_from_rollup(keyword()) :: map()
  def summary_from_rollup(opts \\ []) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.get(opts, :to)
    member_ids = Keyword.get(opts, :member_ids)
    user_ids = Keyword.get(opts, :user_ids)

    result =
      RequestMetricsHourly
      |> maybe_rollup_from(from)
      |> maybe_rollup_to(to)
      |> maybe_rollup_member_ids(member_ids)
      |> maybe_rollup_user_ids(user_ids)
      |> maybe_rollup_model_id(Keyword.get(opts, :model_id))
      |> maybe_rollup_provider_id(Keyword.get(opts, :provider_id))
      |> select([m], %{
        total_cost_micro: fragment("COALESCE(SUM(?), 0)::bigint", m.cost_micro),
        total_prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.prompt_tokens),
        total_completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.completion_tokens),
        total_cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.cache_read_tokens),
        total_cache_creation_tokens:
          fragment("COALESCE(SUM(?), 0)::bigint", m.cache_creation_tokens),
        request_count: fragment("COALESCE(SUM(?), 0)::bigint", m.request_count),
        error_count: fragment("COALESCE(SUM(?), 0)::bigint", m.error_count),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)::bigint", m.total_latency_ms),
        latency_count: fragment("COALESCE(SUM(?), 0)::bigint", m.latency_count)
      })
      |> Repo.one(timeout: stats_timeout())

    avg_latency_ms =
      if result.latency_count > 0,
        do: Float.round(result.total_latency_ms / result.latency_count, 1),
        else: nil

    %{
      total_cost_usd: micro_to_decimal(result.total_cost_micro),
      total_prompt_tokens: result.total_prompt_tokens,
      total_completion_tokens: result.total_completion_tokens,
      total_cache_read_tokens: result.total_cache_read_tokens,
      total_cache_creation_tokens: result.total_cache_creation_tokens,
      request_count: result.request_count,
      error_count: result.error_count,
      total_latency_ms: result.total_latency_ms,
      # Sample counts either side of a hybrid merge: see
      # `StatsQueries.merge_summaries/2`. The rollup has no TTFT column, so its
      # ttft sample count is a real zero (not a missing key).
      latency_count: result.latency_count,
      ttft_count: 0,
      avg_latency_ms: avg_latency_ms,
      avg_tps: compute_tps(result.total_completion_tokens, result.total_latency_ms),
      avg_ttft_ms: nil
    }
  end

  defp zero_summary do
    %{
      total_cost_usd: Decimal.new(0),
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_cache_read_tokens: 0,
      total_cache_creation_tokens: 0,
      request_count: 0,
      error_count: 0,
      total_latency_ms: 0,
      avg_latency_ms: nil,
      avg_tps: nil,
      avg_ttft_ms: nil
    }
  end

  # -----------------------------------------------------------------------
  # Rollup coverage (self-healing input)
  # -----------------------------------------------------------------------

  @doc """
  What the rollup currently covers: the newest aggregated bucket and the total
  bucket count.

  This is DATA coverage, not work coverage — an hour without traffic has no
  bucket, so an old newest bucket is not by itself a gap. `HourlyAggregate`
  compares it against the newest raw log hour (`HourlyAggregate.gap_hours/0`)
  to decide whether the rollup is behind and the readers are falling back to
  `request_logs` for hours the rollup should already own.
  """
  @spec coverage() :: %{last_hour_utc: DateTime.t() | nil, buckets: non_neg_integer()}
  def coverage do
    row =
      Repo.one(
        from(m in RequestMetricsHourly,
          select: %{last_hour_utc: max(m.hour_utc), buckets: count(m.id)}
        ),
        timeout: stats_timeout()
      )

    %{
      last_hour_utc:
        if(is_nil(row.last_hour_utc), do: nil, else: to_utc_datetime(row.last_hour_utc)),
      buckets: row.buckets
    }
  end

  @doc """
  Top HTTP error codes from the rollup — sums `error_count` grouped by
  nothing (the rollup has no `status_code` dimension), so this returns a
  single aggregate row instead of per-code rows.

  Kept deliberately: the dashboard only renders the total error count
  alongside the summary. Per-code error listings stay on
  `top_errors/2` (request_logs).
  """
  @spec total_errors_from_rollup(keyword()) :: non_neg_integer()
  def total_errors_from_rollup(opts \\ []) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.get(opts, :to)
    member_ids = Keyword.get(opts, :member_ids)

    RequestMetricsHourly
    |> maybe_rollup_from(from)
    |> maybe_rollup_to(to)
    |> maybe_rollup_member_ids(member_ids)
    |> select([m], fragment("COALESCE(SUM(?), 0)::bigint", m.error_count))
    |> Repo.one(timeout: stats_timeout())
  end

  # -----------------------------------------------------------------------
  # Rollup breakdowns (used by StatsQueries hybrid reads)
  # -----------------------------------------------------------------------

  @doc """
  Per-model breakdown straight from the rollup table. Same row shape as
  `breakdown_by_model/2` (minus `avg_tps` recomputed from summed latency).

  Options: `:from` (required), `:to`, `:member_ids`.
  """
  @spec breakdown_by_model_from_rollup(keyword()) :: [map()]
  def breakdown_by_model_from_rollup(opts \\ []) do
    query =
      RequestMetricsHourly
      |> maybe_rollup_from(Keyword.fetch!(opts, :from))
      |> maybe_rollup_to(Keyword.get(opts, :to))
      |> maybe_rollup_member_ids(Keyword.get(opts, :member_ids))
      |> maybe_rollup_user_ids(Keyword.get(opts, :user_ids))
      |> maybe_rollup_model_id(Keyword.get(opts, :model_id))
      |> maybe_rollup_provider_id(Keyword.get(opts, :provider_id))
      |> join(:left, [m], ma in Model, on: m.model_id == ma.id, as: :model)
      |> group_by([model: ma], ma.id)
      |> order_by([m], desc: fragment("COALESCE(SUM(?), 0)", m.cost_micro))
      |> select([m, model: ma], %{
        model_id: ma.id,
        model_name: ma.name,
        market_input_price_per_1m: ma.market_input_price_per_1m,
        market_output_price_per_1m: ma.market_output_price_per_1m,
        market_cache_price_per_1m: ma.market_cache_price_per_1m,
        request_count: fragment("COALESCE(SUM(?), 0)::bigint", m.request_count),
        error_count: fragment("COALESCE(SUM(?), 0)::bigint", m.error_count),
        cost_usd_raw: fragment("COALESCE(SUM(?), 0)::bigint", m.cost_micro),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.cache_read_tokens),
        cache_creation_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.cache_creation_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)::bigint", m.total_latency_ms)
      })

    query
    |> Repo.all(timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        model_id: row.model_id,
        model_name: row.model_name || "—",
        market_input_price_per_1m: row.market_input_price_per_1m,
        market_output_price_per_1m: row.market_output_price_per_1m,
        market_cache_price_per_1m: row.market_cache_price_per_1m,
        request_count: row.request_count,
        error_count: row.error_count,
        cost_usd: micro_to_decimal(row.cost_usd_raw),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        cache_read_tokens: row.cache_read_tokens,
        cache_creation_tokens: row.cache_creation_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  @doc """
  Per-member breakdown straight from the rollup table, with the same row
  shape as `breakdown_by_member/2`.

  Options: `:from` (required), `:to`, `:member_ids`.
  """
  @spec breakdown_by_member_from_rollup(keyword()) :: [map()]
  def breakdown_by_member_from_rollup(opts \\ []) do
    query =
      RequestMetricsHourly
      |> maybe_rollup_from(Keyword.fetch!(opts, :from))
      |> maybe_rollup_to(Keyword.get(opts, :to))
      |> maybe_rollup_member_ids(Keyword.get(opts, :member_ids))
      |> maybe_rollup_user_ids(Keyword.get(opts, :user_ids))
      |> maybe_rollup_model_id(Keyword.get(opts, :model_id))
      |> maybe_rollup_provider_id(Keyword.get(opts, :provider_id))
      |> join(:left, [m], tm in GroupMember, on: m.group_member_id == tm.id, as: :member)
      |> join(:left, [member: tm], t in assoc(tm, :group), as: :group)
      # Usuario por la columna DURABLE del bucket (m.user_id), no vía
      # membresía: un huérfano (membresía muerta) conserva su usuario.
      |> join(:left, [m], u in Tokengate.Accounts.User, on: m.user_id == u.id, as: :user)
      # Sólo buckets con usuario atribuible (los de servicio llevan
      # user_id nil): los rankings de miembros enlazan user_id/user_email.
      |> where([user: u], not is_nil(u.id))
      |> group_by([member: tm, group: t, user: u], [tm.id, t.id, u.id])
      |> order_by([m], desc: fragment("COALESCE(SUM(?), 0)", m.cost_micro))
      |> select([m, member: tm, group: t, user: u], %{
        group_member_id: tm.id,
        user_id: u.id,
        group_name: t.name,
        user_email: u.email,
        request_count: fragment("COALESCE(SUM(?), 0)::bigint", m.request_count),
        cost_usd_raw: fragment("COALESCE(SUM(?), 0)::bigint", m.cost_micro),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.cache_read_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)::bigint", m.total_latency_ms)
      })

    query
    |> Repo.all(timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        group_member_id: row.group_member_id,
        user_id: row.user_id,
        group_name: row.group_name,
        user_email: row.user_email,
        request_count: row.request_count,
        cost_usd: micro_to_decimal(row.cost_usd_raw),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        cache_read_tokens: row.cache_read_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  @doc """
  Per-group breakdown straight from the rollup table, with the same row
  shape as `breakdown_by_group/1`.

  Options: `:from` (required), `:to`, `:member_ids`.
  """
  @spec breakdown_by_group_from_rollup(keyword()) :: [map()]
  def breakdown_by_group_from_rollup(opts \\ []) do
    query =
      RequestMetricsHourly
      |> maybe_rollup_from(Keyword.fetch!(opts, :from))
      |> maybe_rollup_to(Keyword.get(opts, :to))
      |> maybe_rollup_member_ids(Keyword.get(opts, :member_ids))
      |> maybe_rollup_user_ids(Keyword.get(opts, :user_ids))
      |> maybe_rollup_model_id(Keyword.get(opts, :model_id))
      |> maybe_rollup_provider_id(Keyword.get(opts, :provider_id))
      |> join(:left, [m], tm in GroupMember, on: m.group_member_id == tm.id, as: :member)
      |> join(:left, [member: tm], t in assoc(tm, :group), as: :group)
      # Sólo filas con GRUPO atribuible: los huérfanos (membresía muerta) y
      # los buckets de servicio dejan group_id nil y revientan a los
      # consumidores que enlazan por ese id (tab Grupos de /stats). Ese
      # dinero se atribuye en las vistas por usuario, no aquí.
      |> where([group: t], not is_nil(t.id))
      |> group_by([group: t], t.id)
      |> order_by([m], desc: fragment("COALESCE(SUM(?), 0)", m.cost_micro))
      |> select([m, group: t], %{
        group_id: t.id,
        group_name: t.name,
        request_count: fragment("COALESCE(SUM(?), 0)::bigint", m.request_count),
        error_count: fragment("COALESCE(SUM(?), 0)::bigint", m.error_count),
        cost_usd_raw: fragment("COALESCE(SUM(?), 0)::bigint", m.cost_micro),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.cache_read_tokens),
        cache_creation_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.cache_creation_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)::bigint", m.total_latency_ms)
      })

    query
    |> Repo.all(timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        group_id: row.group_id,
        group_name: row.group_name,
        request_count: row.request_count,
        error_count: row.error_count,
        cost_usd: micro_to_decimal(row.cost_usd_raw),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        cache_read_tokens: row.cache_read_tokens,
        cache_creation_tokens: row.cache_creation_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  # Rollup-table filter helpers (day ranges are inclusive on `day`).
  #
  # Every rollup index is prefixed by `day` (the UTC date of `hour_utc`), so
  # a window filtered only on `hour_utc` cannot use the index prefix and
  # degenerates into a seq scan of the whole table. Bounding `day` as well
  # keeps the exact same rows (`day = hour_utc::date`, a superset of the hour
  # window) while giving PG the prefix it can range-scan.
  defp maybe_rollup_from(query, nil), do: query

  defp maybe_rollup_from(query, %DateTime{} = from) do
    query
    |> where([m], m.hour_utc >= ^from)
    |> where([m], m.day >= ^DateTime.to_date(from))
  end

  defp maybe_rollup_to(query, nil), do: query

  # Semántica exclusiva: un bucket de hora cubre [hour_utc, hour_utc + 1h),
  # así que sólo responde contenido ANTERIOR a `to`. Con `<=`, una ventana
  # que termina justo en un borde de hora (los períodos anteriores de los
  # deltas) se tragaba el bucket entero que arranca en `to` — hasta una hora
  # de tráfico fuera de la ventana en cada KPI.
  defp maybe_rollup_to(query, %DateTime{} = to) do
    query
    |> where([m], m.hour_utc < ^to)
    |> where([m], m.day <= ^DateTime.to_date(to))
  end

  defp maybe_rollup_member_ids(query, nil), do: query

  defp maybe_rollup_member_ids(query, member_ids) when is_list(member_ids) do
    where(query, [m], m.group_member_id in ^member_ids)
  end

  # Identidad durable: los buckets post-rotación llevan group_member_id NULL
  # pero user_id presente — el scoping por usuario SIEMPRE pasa por aquí,
  # nunca por member_ids, o pierde el histórico de membresías rotadas.
  defp maybe_rollup_user_ids(query, nil), do: query

  defp maybe_rollup_user_ids(query, user_ids) when is_list(user_ids) do
    where(query, [m], m.user_id in ^user_ids)
  end

  # `model_id` / `provider_id` are real rollup dimensions, so drilldowns on
  # them answer from the rollup. `service_id` is NOT a rollup dimension
  # (`request_metrics_hourly` has no such column) — service drilldowns stay
  # raw, see `breakdown_by_model/2`.
  defp maybe_rollup_model_id(query, nil), do: query

  defp maybe_rollup_model_id(query, model_id) when is_binary(model_id) do
    where(query, [m], m.model_id == ^model_id)
  end

  defp maybe_rollup_provider_id(query, nil), do: query

  defp maybe_rollup_provider_id(query, provider_id) when is_binary(provider_id) do
    where(query, [m], m.provider_id == ^provider_id)
  end

  # Integer micro-USD → Decimal USD (6dp), same convention as the Collector.
  defp micro_to_decimal(micro) when is_integer(micro) do
    micro
    |> Decimal.new()
    |> Decimal.div(Decimal.new(1_000_000))
  end

  # -----------------------------------------------------------------------
  # Internals
  # -----------------------------------------------------------------------

  defp maybe_member_group_filter(query, nil), do: query

  defp maybe_member_group_filter(query, group_id) when is_binary(group_id) do
    where(query, [rl, tm, t, u], tm.group_id == ^group_id)
  end

  defp maybe_from(query, nil), do: query
  defp maybe_from(query, from), do: where(query, [rl], rl.inserted_at >= ^from)

  defp maybe_api_key(query, nil), do: query
  defp maybe_api_key(query, api_key_id), do: where(query, [rl], rl.api_key_id == ^api_key_id)

  defp maybe_to(query, nil), do: query
  defp maybe_to(query, to), do: where(query, [rl], rl.inserted_at <= ^to)

  # Lane ("model × provider × credential") and credential filters: hard `where`
  # over the bucketed RequestLog, so the hourly series can be narrowed to a
  # single lane and still sum to `Logs.cost_summary/1` with the same filters.
  defp maybe_model_provider_id(query, nil), do: query

  defp maybe_model_provider_id(query, model_provider_id) when is_binary(model_provider_id) do
    where(query, [rl], rl.model_provider_id == ^model_provider_id)
  end

  defp maybe_credential_id(query, nil), do: query

  defp maybe_credential_id(query, credential_id) when is_binary(credential_id) do
    where(query, [rl], rl.credential_id == ^credential_id)
  end

  # ONE throughput formula for every surface: the shared implementation lives
  # in `Tokengate.Logs.compute_tps/2` (this module used to round here while
  # `StatsQueries`/`Logs` did not, so the same period could show 123.5 vs
  # 123.456 depending on which card asked).
  defp compute_tps(tokens, latency_ms), do: Logs.compute_tps(tokens, latency_ms)

  # Media de latencia por request con latencia registrada. nil cuando no hay
  # ninguna muestra — un 0 inventado se leería como "instantáneo".
  defp compute_avg_latency(_total_ms, 0), do: nil

  defp compute_avg_latency(total_ms, count) when is_integer(count) and count > 0 do
    Float.round(total_ms / count, 1)
  end

  defp compute_avg_latency(_total_ms, _count), do: nil

  defp to_utc_datetime(%DateTime{} = dt), do: dt

  defp to_utc_datetime(%NaiveDateTime{} = ndt) do
    # date_trunc returns a NaiveDateTime in Postgres; assume UTC.
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  defp maybe_join_group(query, nil), do: query

  defp maybe_join_group(query, group_id) when is_binary(group_id) do
    query
    |> join(:inner, [rl], tm in GroupMember, on: rl.group_member_id == tm.id)
    |> where([rl, tm], tm.group_id == ^group_id)
  end

  # Scoping filter: restrict rows to the given group-member ids. `nil` means
  # unrestricted (admin scope); an empty list matches nothing (user with no
  # memberships sees zero rows, never org-wide data).
  defp maybe_member_ids(query, nil), do: query

  defp maybe_member_ids(query, member_ids) when is_list(member_ids) do
    where(query, [rl], rl.group_member_id in ^member_ids)
  end

  # Scoping por usuario (identidad durable, `request_logs.user_id`): los logs
  # cuya membresía fue rotada (group_member_id NULL) siguen contando.
  defp maybe_user_ids(query, nil), do: query

  defp maybe_user_ids(query, user_ids) when is_list(user_ids) do
    where(query, [rl], rl.user_id in ^user_ids)
  end

  # Single service_id filter (used for service drill-down).
  defp maybe_service_id(query, nil), do: query

  defp maybe_service_id(query, service_id) when is_binary(service_id) do
    where(query, [rl], rl.service_id == ^service_id)
  end

  # Single provider_id filter (used by the provider drill-down: its models and
  # the users/services/groups that route through it).
  defp maybe_provider_id(query, nil), do: query

  defp maybe_provider_id(query, provider_id) when is_binary(provider_id) do
    where(query, [rl], rl.provider_id == ^provider_id)
  end

  # Single model_id filter: the raw half of the hybrid breakdowns must honour
  # the same drilldown the rollup half applies, or the merged result would
  # silently mix scoped rollup rows with org-wide tail rows.
  defp maybe_model_id(query, nil), do: query

  defp maybe_model_id(query, model_id) when is_binary(model_id) do
    where(query, [rl], rl.model_id == ^model_id)
  end

  # -----------------------------------------------------------------------
  # daily_series_by_provider_for_model/2
  # -----------------------------------------------------------------------
  # Daily request count per provider for a specific model model.
  # Used by the models drill-down sparkline chart.

  def daily_series_by_provider_for_model(model_id, opts \\ [])

  def daily_series_by_provider_for_model(nil, _opts), do: []

  def daily_series_by_provider_for_model(model_id, opts)
      when is_binary(model_id) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    bucketed =
      RequestLog
      |> where([rl], rl.model_id == ^model_id)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> join(:left, [rl], mp in Tokengate.Providers.ModelProvider,
        on: rl.model_provider_id == mp.id
      )
      |> join(:left, [rl, mp], c in Tokengate.Providers.Credential, on: mp.credential_id == c.id)
      |> join(:left, [rl, mp, c], p in Tokengate.Providers.Provider, on: c.provider_id == p.id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> select([rl, mp, c, p], %{
        bucket:
          fragment(
            "date_trunc('day', ? AT TIME ZONE ?) AT TIME ZONE ?",
            rl.inserted_at,
            ^timezone,
            ^timezone
          ),
        label: p.name,
        label_logo: p.logo_url,
        id: rl.id,
        spend: rl.provider_cost_usd
      })
      |> subquery()

    query =
      from(b in bucketed,
        group_by: [b.bucket, b.label, b.label_logo],
        order_by: [b.bucket, b.label],
        select: %{
          date: b.bucket,
          label: b.label,
          label_logo: b.label_logo,
          request_count: count(b.id),
          total_cost: fragment("COALESCE(SUM(?), 0)", b.spend)
        }
      )

    Repo.all(query, timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        date: to_utc_datetime(row.date),
        label: row.label || "—",
        label_logo: row.label_logo,
        request_count: row.request_count,
        total_cost_usd: Decimal.new(to_string(row.total_cost))
      }
    end)
  end

  # -----------------------------------------------------------------------
  # daily_series_by_model_for_group/2
  # -----------------------------------------------------------------------
  # Daily request count per model for a specific group.
  # Used by the groups drill-down sparkline chart.

  def daily_series_by_model_for_group(group_id, opts \\ [])

  def daily_series_by_model_for_group(nil, _opts), do: []

  def daily_series_by_model_for_group(group_id, opts)
      when is_binary(group_id) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    bucketed =
      RequestLog
      |> join(:inner, [rl], tm in GroupMember, on: rl.group_member_id == tm.id)
      |> where([rl, tm], tm.group_id == ^group_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> select([rl, tm], %{
        bucket:
          fragment(
            "date_trunc('day', ? AT TIME ZONE ?) AT TIME ZONE ?",
            rl.inserted_at,
            ^timezone,
            ^timezone
          ),
        label: rl.model_requested,
        id: rl.id,
        spend: rl.provider_cost_usd
      })
      |> subquery()

    query =
      from(b in bucketed,
        group_by: [b.bucket, b.label],
        order_by: [b.bucket, b.label],
        select: %{
          date: b.bucket,
          label: b.label,
          request_count: count(b.id),
          total_cost: fragment("COALESCE(SUM(?), 0)", b.spend)
        }
      )

    Repo.all(query, timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        date: to_utc_datetime(row.date),
        label: row.label || "—",
        request_count: row.request_count,
        total_cost_usd: Decimal.new(to_string(row.total_cost))
      }
    end)
  end

  # -----------------------------------------------------------------------
  # daily_series_by_model_for_service/2
  # -----------------------------------------------------------------------
  # Daily request count per model for a specific service (group_member_id).
  # Used by the services drill-down sparkline chart.

  def daily_series_by_model_for_service(service_id, opts \\ [])

  def daily_series_by_model_for_service(nil, _opts), do: []

  def daily_series_by_model_for_service(service_id, opts)
      when is_binary(service_id) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    bucketed =
      RequestLog
      |> where([rl], rl.service_id == ^service_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> select([rl], %{
        bucket:
          fragment(
            "date_trunc('day', ? AT TIME ZONE ?) AT TIME ZONE ?",
            rl.inserted_at,
            ^timezone,
            ^timezone
          ),
        label: rl.model_requested,
        id: rl.id
      })
      |> subquery()

    query =
      from(b in bucketed,
        group_by: [b.bucket, b.label],
        order_by: [b.bucket, b.label],
        select: %{
          date: b.bucket,
          label: b.label,
          request_count: count(b.id)
        }
      )

    Repo.all(query, timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        date: to_utc_datetime(row.date),
        label: row.label || "—",
        request_count: row.request_count
      }
    end)
  end

  # -----------------------------------------------------------------------
  # usage_series_by_model_for_service/2
  # -----------------------------------------------------------------------
  # serie de uso+gasto por modelo para el detalle de un servicio:
  #   * granularity: :hour  → buckets por hora (today / yesterday);
  #   * granularity: :day   → buckets por día (week / 30d).
  # Devuelve filas %{date, label, request_count, total_cost_usd} — la gráfica
  # "Spend & requests" del Overview del servicio apila por `label` con las
  # requests y muestra el costo en el tooltip.
  def usage_series_by_model_for_service(service_id, opts \\ [])

  def usage_series_by_model_for_service(nil, _opts), do: []

  def usage_series_by_model_for_service(service_id, opts)
      when is_binary(service_id) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    step = if Keyword.get(opts, :granularity, :day) == :hour, do: "hour", else: "day"
    api_key_id = Keyword.get(opts, :api_key_id)

    # Bucket por subquery: la expresión con placeholders (date_trunc + tz)
    # vive SOLO en el select interno; la query externa agrupa por la columna
    # del subquery, así Postgres puede casar ambas apariciones. El SUM del
    # costo se hace a nivel externo.
    bucketed =
      RequestLog
      |> where([rl], rl.service_id == ^service_id)
      |> maybe_api_key(api_key_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> select([rl], %{
        bucket:
          fragment(
            "date_trunc(?, ? AT TIME ZONE ?) AT TIME ZONE ?",
            ^step,
            rl.inserted_at,
            ^timezone,
            ^timezone
          ),
        label: rl.model_requested,
        count_id: rl.id,
        spend: rl.provider_cost_usd
      })
      |> subquery()

    query =
      from(b in bucketed,
        group_by: [b.bucket, b.label],
        order_by: [b.bucket, b.label],
        select: %{
          date: b.bucket,
          label: b.label,
          request_count: count(b.count_id),
          total_cost: fragment("COALESCE(SUM(?), 0)", b.spend)
        }
      )

    Repo.all(query, timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        date: to_utc_datetime(row.date),
        label: row.label || "—",
        request_count: row.request_count,
        total_cost_usd: Decimal.new(to_string(row.total_cost))
      }
    end)
  end

  # -----------------------------------------------------------------------
  # daily_series_by_provider/1 & daily_series_by_provider_from_rollup/1
  # -----------------------------------------------------------------------

  @doc """
  Serie diaria de uso, costo y tokens por proveedor en el período, en la
  hora local del usuario. Usada por Overview para responder "¿cuándo?" en
  ventanas de varios días (week / 30d).
  """
  @spec daily_series_by_provider(keyword()) :: [map()]
  def daily_series_by_provider(opts \\ []) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.get(opts, :to)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    bucketed =
      RequestLog
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> maybe_user_ids(Keyword.get(opts, :user_ids))
      |> select([rl], %{
        bucket:
          fragment(
            "date_trunc('day', ? AT TIME ZONE ?) AT TIME ZONE ?",
            rl.inserted_at,
            ^timezone,
            ^timezone
          ),
        provider_id: rl.provider_id,
        id: rl.id,
        spend: rl.provider_cost_usd,
        prompt_tokens: rl.prompt_tokens,
        completion_tokens: rl.completion_tokens,
        status_code: rl.status_code
      })
      |> subquery()

    rows =
      from(b in bucketed,
        group_by: [b.bucket, b.provider_id],
        order_by: [b.bucket],
        select: %{
          date: b.bucket,
          provider_id: b.provider_id,
          request_count: count(b.id),
          total_cost: fragment("COALESCE(SUM(?), 0)", b.spend),
          prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", b.prompt_tokens),
          completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", b.completion_tokens),
          error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", b.status_code)
        }
      )
      |> Repo.all(timeout: stats_timeout())

    attach_provider_labels(rows, :decimal)
  end

  @doc """
  Mitad rollup de `daily_series_by_provider/1`. Agrupa sobre `hour_utc` en
  buckets de día local y resuelve proveedores en una segunda query acotada.
  """
  @spec daily_series_by_provider_from_rollup(keyword()) :: [map()]
  def daily_series_by_provider_from_rollup(opts \\ []) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.get(opts, :to)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    bucketed =
      RequestMetricsHourly
      |> maybe_rollup_from(from)
      |> maybe_rollup_to(to)
      |> maybe_rollup_member_ids(Keyword.get(opts, :member_ids))
      |> maybe_rollup_user_ids(Keyword.get(opts, :user_ids))
      |> select([m], %{
        bucket:
          fragment(
            "date_trunc('day', (? AT TIME ZONE 'Etc/UTC') AT TIME ZONE ?) AT TIME ZONE ?",
            m.hour_utc,
            ^timezone,
            ^timezone
          ),
        provider_id: m.provider_id,
        request_count: m.request_count,
        cost_micro: m.cost_micro,
        prompt_tokens: m.prompt_tokens,
        completion_tokens: m.completion_tokens,
        error_count: m.error_count
      })
      |> subquery()

    rows =
      from(b in bucketed,
        group_by: [b.bucket, b.provider_id],
        order_by: [b.bucket],
        select: %{
          date: b.bucket,
          provider_id: b.provider_id,
          request_count: fragment("COALESCE(SUM(?), 0)::bigint", b.request_count),
          cost_micro: fragment("COALESCE(SUM(?), 0)::bigint", b.cost_micro),
          prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", b.prompt_tokens),
          completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", b.completion_tokens),
          error_count: fragment("COALESCE(SUM(?), 0)::bigint", b.error_count)
        }
      )
      |> Repo.all(timeout: stats_timeout())

    attach_provider_labels(rows, :micro)
  end

  defp attach_provider_labels([], _cost_kind), do: []

  defp attach_provider_labels(rows, cost_kind) do
    provider_ids = rows |> Enum.map(& &1.provider_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    identities =
      if provider_ids == [] do
        %{}
      else
        from(p in Provider, where: p.id in ^provider_ids, select: {p.id, p.name, p.logo_url})
        |> Repo.all(timeout: stats_timeout())
        |> Map.new(fn {id, name, logo} -> {id, {name, logo}} end)
      end

    Enum.map(rows, fn row ->
      {name, logo} = Map.get(identities, row.provider_id, {@no_provider, nil})

      cost =
        case cost_kind do
          :micro -> micro_to_decimal(row.cost_micro)
          :decimal -> Decimal.new(to_string(row.total_cost))
        end

      %{
        date: to_utc_datetime(row.date),
        provider_id: row.provider_id,
        label: name || @no_provider,
        label_logo: logo,
        request_count: row.request_count,
        total_cost_usd: cost,
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        error_count: row.error_count || 0
      }
    end)
  end

  # -----------------------------------------------------------------------
  # efficiency_summary/1 (Overview: por qué cuesta tanto)
  # -----------------------------------------------------------------------

  @doc """
  Single-pass economic & friction breakdown over `request_logs` (bounded by
  `Logs.ensure_window!/2`):

    * desperdicio en errores (`status_code >= 400`)
    * fallbacks recuperados (`status_code == 200` con `provider_status_code != 200`)
    * hits en caché local (`cache_hit == true`)
    * impacto de reasoning (`think == true` o `effort_applied IS NOT NULL`)
    * reparto humanos (`subject_type == "user"`) vs servicios (`"service"`)
  """
  @spec efficiency_summary(keyword()) :: map()
  def efficiency_summary(opts \\ []) do
    opts_map = Map.new(opts) |> Logs.ensure_window!("Rollup.efficiency_summary/1")
    from = Map.get(opts_map, :from)
    to = Map.get(opts_map, :to)

    row =
      RequestLog
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Map.get(opts_map, :member_ids))
      |> maybe_user_ids(Map.get(opts_map, :user_ids))
      |> maybe_model_id(Map.get(opts_map, :model_id))
      |> select([rl], %{
        total_requests: count(rl.id),
        total_cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        error_requests: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
        error_cost_usd:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE ? >= 400), 0)",
            rl.provider_cost_usd,
            rl.status_code
          ),
        fallback_recovered_count:
          fragment(
            "COUNT(*) FILTER (WHERE ? = 200 AND ? IS NOT NULL AND ? <> 200)",
            rl.status_code,
            rl.provider_status_code,
            rl.provider_status_code
          ),
        local_cache_hits: fragment("COUNT(*) FILTER (WHERE ? = true)", rl.cache_hit),
        think_requests:
          fragment(
            "COUNT(*) FILTER (WHERE ? = true OR ? IS NOT NULL)",
            rl.think,
            rl.effort_applied
          ),
        think_cost_usd:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE ? = true OR ? IS NOT NULL), 0)",
            rl.provider_cost_usd,
            rl.think,
            rl.effort_applied
          ),
        think_completion_tokens:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE ? = true OR ? IS NOT NULL), 0)::bigint",
            rl.completion_tokens,
            rl.think,
            rl.effort_applied
          ),
        human_requests: fragment("COUNT(*) FILTER (WHERE ? = 'user')", rl.subject_type),
        human_cost_usd:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE ? = 'user'), 0)",
            rl.provider_cost_usd,
            rl.subject_type
          ),
        service_requests: fragment("COUNT(*) FILTER (WHERE ? = 'service')", rl.subject_type),
        service_cost_usd:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE ? = 'service'), 0)",
            rl.provider_cost_usd,
            rl.subject_type
          )
      })
      |> Repo.one(timeout: stats_timeout())

    %{
      total_requests: row.total_requests || 0,
      total_cost_usd: Decimal.new(to_string(row.total_cost_usd || 0)),
      error_requests: row.error_requests || 0,
      error_cost_usd: Decimal.new(to_string(row.error_cost_usd || 0)),
      fallback_recovered_count: row.fallback_recovered_count || 0,
      local_cache_hits: row.local_cache_hits || 0,
      think_requests: row.think_requests || 0,
      think_cost_usd: Decimal.new(to_string(row.think_cost_usd || 0)),
      think_completion_tokens: row.think_completion_tokens || 0,
      human_requests: row.human_requests || 0,
      human_cost_usd: Decimal.new(to_string(row.human_cost_usd || 0)),
      service_requests: row.service_requests || 0,
      service_cost_usd: Decimal.new(to_string(row.service_cost_usd || 0))
    }
  end

  # -----------------------------------------------------------------------
  # FinOps — shared aggregates (global overview, series, breakdowns, per service)
  # -----------------------------------------------------------------------
  #
  # Every read here is ONE bounded pass over `request_logs`, bounded by
  # `Logs.ensure_window!/2`: a caller that forgets `:from` fails loudly instead
  # of receiving "whatever survived retention" presented as a total. The rows
  # are plain maps/lists (integers for counts/tokens, `Decimal` for money) so
  # the UI layers can render them without knowing the query shapes.
  #
  # ## `router_decision` rows
  #
  # `request_type = 'router_decision'` is the classifier's OWN billed call, not
  # served traffic (same rule as `SmartRouter.Analytics` and
  # `HourlyAggregate`). Served metrics exclude those rows entirely.
  #
  # The same money is recorded twice by design: the served row carries
  # `router_decision_cost_usd` (the decision step's price) and, when the
  # operator bills it to the subject, a separate `router_decision` row carries
  # it in `provider_cost_usd`. Adding both would report the routing cost twice,
  # so `:router_decision_cost_usd` is taken from ONE source per window: the
  # decision rows when any exist (they are the actual debit), the served column
  # otherwise (the absorbed-cost mode). `finops_overview_rows/1` is that single
  # choice, written once.

  @doc """
  FinOps overview of the window in a SINGLE pass: served traffic, money, and
  the economics that explain it, split three ways.

  Returns:

      %{
        overall:  total spent/served in the window,
        users:    the `subject_type == "user"` block    (+ :active_subjects),
        services: the `subject_type == "service"` block (+ :active_subjects)
      }

  Every block carries the same counters:

    * `:requests`, `:cost_usd`, `:prompt_tokens`, `:completion_tokens`
    * `:cache_read_tokens`, `:cache_creation_tokens`
    * `:error_requests` (status >= 400) and `:error_cost_usd` (what the errors
      cost — the waste, not the volume)
    * `:fallback_recovered_count` (200 after a non-200 upstream attempt)
    * `:think_requests`, `:think_cost_usd`, `:think_completion_tokens`
      (`think == true` OR an effort was applied)
    * `:local_cache_hits` (gateway cache, nothing reached an upstream)
    * `:router_decision_cost_usd` (the decision step's spend — see the section
      comment: counted once, never folded into `:cost_usd`)
    * `:prompt_tokens_saved_est` (prompt-saving knobs' estimate)
    * `:topup_requests`, `:topup_cost_usd` (served against a top-up debit)

  `:active_subjects` (users/services blocks only) is the count of DISTINCT
  subjects that actually served traffic — the denominator an ARPU/ARPC card
  needs and a `COUNT(*)` cannot give.

  ## Options

    * `:from` — REQUIRED; `inserted_at >= from`
    * `:to` — optional upper bound
    * `:service_id` / `:api_key_id` / `:model_id` — optional scope (the
      per-service summary reuses this function with `:service_id`); `"all"` and
      `nil` both mean "no filter"
  """
  @spec finops_overview(keyword()) :: %{overall: map(), users: map(), services: map()}
  def finops_overview(opts \\ []) do
    window = finops_window!(opts, "Rollup.finops_overview/1")

    rows =
      window
      |> finops_base_rows(opts)
      |> finops_overview_rows()
      |> Repo.all(timeout: stats_timeout())

    by_scope = Map.new(rows, fn row -> {finops_scope_key(row), row} end)

    %{
      overall: finops_subject_totals(Map.get(by_scope, :total)),
      users: finops_subject_totals(Map.get(by_scope, "user"), :users),
      services: finops_subject_totals(Map.get(by_scope, "service"), :services)
    }
  end

  @doc """
  Daily (`granularity: :day`, the default) or hourly (`:hour`, bucketed in
  `:timezone`) series of served traffic split by subject kind.

  Returns `[%{date: Date.t() | DateTime.t(), subject_type: "user" | "service",
  request_count: integer, cost_usd: Decimal.t(), error_cost_usd: Decimal.t(),
  think_cost_usd: Decimal.t()}]`, ordered by `{date, subject_type}`.

  `router_decision` rows are excluded (they are not served traffic), and only
  user/service rows are returned: a legacy row with no `subject_type` has no
  subject kind to chart.
  """
  @spec finops_subject_series(keyword()) :: [map()]
  def finops_subject_series(opts \\ []) do
    window = finops_window!(opts, "Rollup.finops_subject_series/1")
    granularity = finops_granularity(opts)

    window
    |> finops_series_rows(opts, granularity)
    |> Enum.filter(&(&1.subject_type in ["user", "service"]))
    |> Enum.map(&finops_series_entry(&1, granularity))
    |> Enum.sort_by(fn entry -> {finops_sort_key(entry.date), entry.subject_type} end)
  end

  @doc """
  Served traffic broken down by `request_type` (`router_decision` excluded),
  ordered by cost desc.

  Returns `[%{request_type: String.t(), request_count: integer,
  user_requests: integer, service_requests: integer, cost_usd: Decimal.t(),
  user_cost_usd: Decimal.t(), service_cost_usd: Decimal.t(),
  prompt_tokens: integer, completion_tokens: integer,
  cache_read_tokens: integer, error_count: integer, error_cost_usd: Decimal.t()}]`.

  Each row answers "what does this KIND of request cost, and who pays for it" —
  the `user_*`/`service_*` split is the same `subject_type` attribution the
  overview publishes, so the two always add up.
  """
  @spec finops_request_type_breakdown(keyword()) :: [map()]
  def finops_request_type_breakdown(opts \\ []) do
    window = finops_window!(opts, "Rollup.finops_request_type_breakdown/1")

    window
    |> finops_request_type_rows(opts)
    |> Repo.all(timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        request_type: row.request_type || "unknown",
        request_count: finops_int(row.request_count),
        user_requests: finops_int(row.user_requests),
        service_requests: finops_int(row.service_requests),
        cost_usd: finops_usd(row.cost_usd),
        user_cost_usd: finops_usd(row.user_cost_usd),
        service_cost_usd: finops_usd(row.service_cost_usd),
        prompt_tokens: finops_int(row.prompt_tokens),
        completion_tokens: finops_int(row.completion_tokens),
        cache_read_tokens: finops_int(row.cache_read_tokens),
        error_count: finops_int(row.error_count),
        error_cost_usd: finops_usd(row.error_cost_usd)
      }
    end)
  end

  @doc """
  One row per ACTIVE subject in the window (users and services), for the
  cost/volume scatter: who spends, how much, and how much of it was wasted.

  Returns `[%{subject_type: "user" | "service", subject_id: binary,
  label: String.t(), request_count: integer, cost_usd: Decimal.t(),
  prompt_tokens: integer, completion_tokens: integer,
  cache_read_tokens: integer, error_count: integer,
  error_cost_usd: Decimal.t(), think_cost_usd: Decimal.t(),
  topup_cost_usd: Decimal.t()}]`, ordered by cost desc.

  The names are joined in ONE statement (two dimension tables, no per-row
  lookup): `label` is the user's email, else the service's name, else `"—"`
  for a subject row whose account was deleted (the traffic is still real).
  """
  @spec finops_subject_scatter(keyword()) :: [map()]
  def finops_subject_scatter(opts \\ []) do
    window = finops_window!(opts, "Rollup.finops_subject_scatter/1")

    window
    |> finops_subject_scatter_rows(opts)
    |> Repo.all(timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        subject_type: row.subject_type,
        subject_id: row.user_id || row.service_id,
        label: row.user_email || row.user_name || row.service_name || "—",
        request_count: finops_int(row.request_count),
        cost_usd: finops_usd(row.cost_usd),
        prompt_tokens: finops_int(row.prompt_tokens),
        completion_tokens: finops_int(row.completion_tokens),
        cache_read_tokens: finops_int(row.cache_read_tokens),
        error_count: finops_int(row.error_count),
        error_cost_usd: finops_usd(row.error_cost_usd),
        think_cost_usd: finops_usd(row.think_cost_usd),
        topup_cost_usd: finops_usd(row.topup_cost_usd)
      }
    end)
    |> Enum.sort_by(& &1.cost_usd, &decimal_desc/2)
  end

  @doc """
  FinOps summary of ONE service: the same economics as `finops_overview/1`
  plus the three splits the service pages draw.

  Returns:

      %{
        overview:        the `finops_overview/1` `:overall` block,
        by_request_type: `finops_request_type_breakdown/1` scoped to the service,
        by_key:          [%{api_key_id, label, status, request_count, cost_usd,
                            prompt_tokens, completion_tokens, cache_read_tokens,
                            error_count, error_cost_usd, think_cost_usd}],
        by_model:        [%{model_name, request_count, cost_usd, prompt_tokens,
                            completion_tokens, cache_read_tokens, error_count,
                            error_cost_usd, think_cost_usd}]
      }

  `by_key` keeps a row for traffic whose `api_key_id` is NULL (logs written
  before the column existed, or before the key was known): `label` is `"—"` and
  `status` is `nil` for those, instead of hiding a real slice of the spend.

  ## Options

    * `:api_key_id` — `"all"` (default) or a key uuid
    * `:from` — REQUIRED; `:to` — optional
  """
  @spec service_finops_summary(binary(), keyword()) :: map()
  def service_finops_summary(service_id, opts \\ [])

  def service_finops_summary(nil, _opts) do
    %{
      overview: finops_zero_totals(),
      by_request_type: [],
      by_key: [],
      by_model: []
    }
  end

  def service_finops_summary(service_id, opts) when is_binary(service_id) do
    opts = Keyword.put(opts, :service_id, service_id)
    window = finops_window!(opts, "Rollup.service_finops_summary/2")

    by_key =
      window
      |> finops_service_key_rows(opts)
      |> Repo.all(timeout: stats_timeout())
      |> Enum.map(&finops_key_entry/1)

    by_model =
      window
      |> finops_service_model_rows(opts)
      |> Repo.all(timeout: stats_timeout())
      |> Enum.map(&finops_model_entry/1)

    %{
      overview: finops_overview(opts).overall,
      by_request_type: finops_request_type_breakdown(opts),
      by_key: by_key,
      by_model: by_model
    }
  end

  @doc """
  Daily (`:day`, default) or hourly (`:hour`, in `:timezone`) FinOps series for
  ONE service: `[%{date: Date.t() | DateTime.t(), request_count: integer,
  cost_usd: Decimal.t(), error_cost_usd: Decimal.t(),
  think_cost_usd: Decimal.t()}]`, ordered by `date`.

  Same `:api_key_id` option as `service_finops_summary/2` (`"all"` or a uuid),
  and `router_decision` rows are excluded like everywhere else in this section.
  """
  @spec service_finops_series(binary(), keyword()) :: [map()]
  def service_finops_series(service_id, opts \\ [])

  def service_finops_series(nil, _opts), do: []

  def service_finops_series(service_id, opts) when is_binary(service_id) do
    opts = Keyword.put(opts, :service_id, service_id)
    window = finops_window!(opts, "Rollup.service_finops_series/2")
    granularity = finops_granularity(opts)

    window
    |> finops_series_rows(opts, granularity)
    |> Enum.group_by(& &1.bucket)
    |> Enum.map(fn {bucket, rows} ->
      %{
        date: finops_bucket_date(bucket, granularity),
        request_count: rows |> Enum.map(& &1.request_count) |> Enum.sum(),
        cost_usd: rows |> Enum.map(& &1.cost_usd) |> Enum.reduce(Decimal.new(0), &Decimal.add/2),
        error_cost_usd:
          rows |> Enum.map(& &1.error_cost_usd) |> Enum.reduce(Decimal.new(0), &Decimal.add/2),
        think_cost_usd:
          rows |> Enum.map(& &1.think_cost_usd) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
      }
    end)
    |> Enum.sort_by(fn entry -> finops_sort_key(entry.date) end)
  end

  # --- FinOps: query building ---------------------------------------------

  # `Logs.ensure_window!/2` is the retention contract: no `:from` is a loud
  # failure in dev/test and a labelled clamp in production — never "everything".
  defp finops_window!(opts, fun) do
    opts
    |> Map.new()
    |> Logs.ensure_window!(fun)
    |> then(fn window -> %{from: Map.fetch!(window, :from), to: Map.get(window, :to)} end)
  end

  # The window's rows, TAGGED with everything the FinOps aggregates need:
  # `is_decision` classifies the classifier's own row once, so every aggregate
  # below can filter it with a boolean instead of repeating the request_type
  # predicate (and re-parsing it) a dozen times.
  #
  # Selecting into a subquery is deliberate: the aggregates then read a narrow,
  # already-bounded row set and the `GROUP BY` keys are plain columns.
  defp finops_base_rows(%{from: from, to: to}, opts) do
    RequestLog
    |> where([rl], rl.inserted_at >= ^from)
    |> maybe_to(to)
    |> finops_scope(opts)
    |> select([rl], %{
      inserted_at: rl.inserted_at,
      subject_type: rl.subject_type,
      is_decision: fragment("COALESCE(?, '') = 'router_decision'", rl.request_type),
      request_type: rl.request_type,
      user_id: rl.user_id,
      service_id: rl.service_id,
      model_id: rl.model_id,
      api_key_id: rl.api_key_id,
      status_code: rl.status_code,
      provider_status_code: rl.provider_status_code,
      provider_cost_usd: rl.provider_cost_usd,
      router_decision_cost_usd: rl.router_decision_cost_usd,
      prompt_tokens: rl.prompt_tokens,
      completion_tokens: rl.completion_tokens,
      cache_read_tokens: rl.cache_read_tokens,
      cache_creation_tokens: rl.cache_creation_tokens,
      prompt_tokens_saved_est: rl.prompt_tokens_saved_est,
      think: rl.think,
      effort_applied: rl.effort_applied,
      cache_hit: rl.cache_hit,
      credit_topup_id: rl.credit_topup_id
    })
    |> subquery()
  end

  defp finops_scope(query, opts) do
    query
    |> finops_where(:service_id, Keyword.get(opts, :service_id))
    |> finops_where(:api_key_id, Keyword.get(opts, :api_key_id))
    |> finops_where(:model_id, Keyword.get(opts, :model_id))
  end

  defp finops_where(query, _field, nil), do: query
  defp finops_where(query, _field, "all"), do: query
  defp finops_where(query, _field, :all), do: query

  defp finops_where(query, :service_id, id),
    do: where(query, [rl], rl.service_id == ^id)

  defp finops_where(query, :api_key_id, id),
    do: where(query, [rl], rl.api_key_id == ^id)

  defp finops_where(query, :model_id, id),
    do: where(query, [rl], rl.model_id == ^id)

  # ONE pass, three scopes: `GROUPING SETS ((subject_type), ())` returns one row
  # per subject kind PLUS the grand total, all from the same scan (the total is
  # computed by Postgres, so `:overall` can never disagree with its parts by a
  # rounding or a filter applied in Elixir).
  defp finops_overview_rows(base) do
    from(b in base,
      group_by: fragment("GROUPING SETS ((?), ())", b.subject_type),
      select: %{
        subject_type: b.subject_type,
        is_total: fragment("GROUPING(?)", b.subject_type),
        request_count: fragment("COUNT(*) FILTER (WHERE NOT ?)", b.is_decision),
        cost_usd:
          fragment("COALESCE(SUM(?) FILTER (WHERE NOT ?), 0)", b.provider_cost_usd, b.is_decision),
        prompt_tokens:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE NOT ?), 0)::bigint",
            b.prompt_tokens,
            b.is_decision
          ),
        completion_tokens:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE NOT ?), 0)::bigint",
            b.completion_tokens,
            b.is_decision
          ),
        cache_read_tokens:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE NOT ?), 0)::bigint",
            b.cache_read_tokens,
            b.is_decision
          ),
        cache_creation_tokens:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE NOT ?), 0)::bigint",
            b.cache_creation_tokens,
            b.is_decision
          ),
        error_requests:
          fragment("COUNT(*) FILTER (WHERE NOT ? AND ? >= 400)", b.is_decision, b.status_code),
        error_cost_usd:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE NOT ? AND ? >= 400), 0)",
            b.provider_cost_usd,
            b.is_decision,
            b.status_code
          ),
        fallback_recovered_count:
          fragment(
            "COUNT(*) FILTER (WHERE NOT ? AND ? = 200 AND ? IS NOT NULL AND ? <> 200)",
            b.is_decision,
            b.status_code,
            b.provider_status_code,
            b.provider_status_code
          ),
        think_requests:
          fragment(
            "COUNT(*) FILTER (WHERE NOT ? AND (? = true OR ? IS NOT NULL))",
            b.is_decision,
            b.think,
            b.effort_applied
          ),
        think_cost_usd:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE NOT ? AND (? = true OR ? IS NOT NULL)), 0)",
            b.provider_cost_usd,
            b.is_decision,
            b.think,
            b.effort_applied
          ),
        think_completion_tokens:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE NOT ? AND (? = true OR ? IS NOT NULL)), 0)::bigint",
            b.completion_tokens,
            b.is_decision,
            b.think,
            b.effort_applied
          ),
        local_cache_hits:
          fragment("COUNT(*) FILTER (WHERE NOT ? AND ? = true)", b.is_decision, b.cache_hit),
        router_decision_cost_usd:
          fragment(
            "CASE WHEN COUNT(*) FILTER (WHERE ?) > 0 THEN COALESCE(SUM(?) FILTER (WHERE ?), 0) ELSE COALESCE(SUM(?) FILTER (WHERE NOT ?), 0) END",
            b.is_decision,
            b.provider_cost_usd,
            b.is_decision,
            b.router_decision_cost_usd,
            b.is_decision
          ),
        prompt_tokens_saved_est:
          fragment(
            "COALESCE(SUM(COALESCE(?, 0)) FILTER (WHERE NOT ?), 0)::bigint",
            b.prompt_tokens_saved_est,
            b.is_decision
          ),
        topup_requests:
          fragment(
            "COUNT(*) FILTER (WHERE NOT ? AND ? IS NOT NULL)",
            b.is_decision,
            b.credit_topup_id
          ),
        topup_cost_usd:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE NOT ? AND ? IS NOT NULL), 0)",
            b.provider_cost_usd,
            b.is_decision,
            b.credit_topup_id
          ),
        active_users:
          fragment("COUNT(DISTINCT ?) FILTER (WHERE NOT ?)", b.user_id, b.is_decision),
        active_services:
          fragment("COUNT(DISTINCT ?) FILTER (WHERE NOT ?)", b.service_id, b.is_decision)
      }
    )
  end

  # Hour/day buckets of served traffic per subject kind. ONE shape for both
  # series readers: `finops_subject_series/1` charts it as-is and
  # `service_finops_series/2` folds the (single) service's rows together.
  defp finops_series_rows(%{from: from, to: to}, opts, granularity) do
    timezone = finops_timezone(opts)

    base =
      RequestLog
      |> where([rl], rl.inserted_at >= ^from)
      |> maybe_to(to)
      |> finops_scope(opts)
      |> where([rl], fragment("COALESCE(?, '') <> 'router_decision'", rl.request_type))

    case granularity do
      :hour ->
        # `GROUP BY 1, 2` (positions) instead of repeating the bucket fragment:
        # Ecto binds `$n` per occurrence, so the same expression written twice
        # is not the SAME expression to Postgres (param 1 vs param 5) and the
        # planner rejects it as "must appear in GROUP BY".
        from(rl in base,
          group_by: [fragment("1"), fragment("2")],
          select: %{
            bucket:
              fragment(
                "date_trunc('hour', (? AT TIME ZONE 'Etc/UTC') AT TIME ZONE ?) AT TIME ZONE ?",
                rl.inserted_at,
                ^timezone,
                ^timezone
              ),
            subject_type: rl.subject_type,
            request_count: count(rl.id),
            cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
            error_cost_usd:
              fragment(
                "COALESCE(SUM(?) FILTER (WHERE ? >= 400), 0)",
                rl.provider_cost_usd,
                rl.status_code
              ),
            think_cost_usd:
              fragment(
                "COALESCE(SUM(?) FILTER (WHERE ? = true OR ? IS NOT NULL), 0)",
                rl.provider_cost_usd,
                rl.think,
                rl.effort_applied
              )
          }
        )
        |> Repo.all(timeout: stats_timeout())
        |> Enum.map(&finops_series_row/1)

      _ ->
        from(rl in base,
          group_by: [fragment("1"), fragment("2")],
          select: %{
            bucket:
              fragment(
                "((? AT TIME ZONE 'Etc/UTC') AT TIME ZONE ?)::date",
                rl.inserted_at,
                ^timezone
              ),
            subject_type: rl.subject_type,
            request_count: count(rl.id),
            cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
            error_cost_usd:
              fragment(
                "COALESCE(SUM(?) FILTER (WHERE ? >= 400), 0)",
                rl.provider_cost_usd,
                rl.status_code
              ),
            think_cost_usd:
              fragment(
                "COALESCE(SUM(?) FILTER (WHERE ? = true OR ? IS NOT NULL), 0)",
                rl.provider_cost_usd,
                rl.think,
                rl.effort_applied
              )
          }
        )
        |> Repo.all(timeout: stats_timeout())
        |> Enum.map(&finops_series_row/1)
    end
  end

  defp finops_series_row(row) do
    %{
      bucket: row.bucket,
      subject_type: row.subject_type,
      request_count: finops_int(row.request_count),
      cost_usd: finops_usd(row.cost_usd),
      error_cost_usd: finops_usd(row.error_cost_usd),
      think_cost_usd: finops_usd(row.think_cost_usd)
    }
  end

  defp finops_request_type_rows(%{from: from, to: to}, opts) do
    base =
      RequestLog
      |> where([rl], rl.inserted_at >= ^from)
      |> maybe_to(to)
      |> finops_scope(opts)
      |> where([rl], fragment("COALESCE(?, '') <> 'router_decision'", rl.request_type))

    from(rl in base,
      group_by: rl.request_type,
      order_by: [desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)],
      select: %{
        request_type: rl.request_type,
        request_count: count(rl.id),
        user_requests: fragment("COUNT(*) FILTER (WHERE ? = 'user')", rl.subject_type),
        service_requests: fragment("COUNT(*) FILTER (WHERE ? = 'service')", rl.subject_type),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        user_cost_usd:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE ? = 'user'), 0)",
            rl.provider_cost_usd,
            rl.subject_type
          ),
        service_cost_usd:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE ? = 'service'), 0)",
            rl.provider_cost_usd,
            rl.subject_type
          ),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_read_tokens),
        error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
        error_cost_usd:
          fragment(
            "COALESCE(SUM(?) FILTER (WHERE ? >= 400), 0)",
            rl.provider_cost_usd,
            rl.status_code
          )
      }
    )
  end

  # Names joined onto the AGGREGATE (two dimension tables, one statement):
  # joining them into the aggregate itself would hash-join the whole window
  # before reducing it, the exact shape this module avoids elsewhere.
  defp finops_subject_scatter_rows(%{from: from, to: to}, opts) do
    base =
      RequestLog
      |> where([rl], rl.inserted_at >= ^from)
      |> maybe_to(to)
      |> finops_scope(opts)
      |> where([rl], fragment("COALESCE(?, '') <> 'router_decision'", rl.request_type))
      |> where([rl], rl.subject_type in ["user", "service"])

    buckets =
      from(rl in base,
        group_by: [rl.subject_type, rl.user_id, rl.service_id],
        select: %{
          subject_type: rl.subject_type,
          user_id: rl.user_id,
          service_id: rl.service_id,
          request_count: count(rl.id),
          cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
          prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.prompt_tokens),
          completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.completion_tokens),
          cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_read_tokens),
          error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
          error_cost_usd:
            fragment(
              "COALESCE(SUM(?) FILTER (WHERE ? >= 400), 0)",
              rl.provider_cost_usd,
              rl.status_code
            ),
          think_cost_usd:
            fragment(
              "COALESCE(SUM(?) FILTER (WHERE ? = true OR ? IS NOT NULL), 0)",
              rl.provider_cost_usd,
              rl.think,
              rl.effort_applied
            ),
          topup_cost_usd:
            fragment(
              "COALESCE(SUM(?) FILTER (WHERE ? IS NOT NULL), 0)",
              rl.provider_cost_usd,
              rl.credit_topup_id
            )
        }
      )
      |> subquery()

    from(b in buckets,
      left_join: u in User,
      on: b.user_id == u.id,
      left_join: s in Service,
      on: b.service_id == s.id,
      select: %{
        subject_type: b.subject_type,
        user_id: b.user_id,
        service_id: b.service_id,
        user_email: u.email,
        user_name: u.name,
        service_name: s.name,
        request_count: b.request_count,
        cost_usd: b.cost_usd,
        prompt_tokens: b.prompt_tokens,
        completion_tokens: b.completion_tokens,
        cache_read_tokens: b.cache_read_tokens,
        error_count: b.error_count,
        error_cost_usd: b.error_cost_usd,
        think_cost_usd: b.think_cost_usd,
        topup_cost_usd: b.topup_cost_usd
      }
    )
  end

  defp finops_service_key_rows(%{from: from, to: to}, opts) do
    base =
      RequestLog
      |> where([rl], rl.inserted_at >= ^from)
      |> maybe_to(to)
      |> finops_scope(opts)
      |> where([rl], fragment("COALESCE(?, '') <> 'router_decision'", rl.request_type))

    buckets =
      from(rl in base,
        group_by: rl.api_key_id,
        select: %{
          api_key_id: rl.api_key_id,
          request_count: count(rl.id),
          cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
          prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.prompt_tokens),
          completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.completion_tokens),
          cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_read_tokens),
          error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
          error_cost_usd:
            fragment(
              "COALESCE(SUM(?) FILTER (WHERE ? >= 400), 0)",
              rl.provider_cost_usd,
              rl.status_code
            ),
          think_cost_usd:
            fragment(
              "COALESCE(SUM(?) FILTER (WHERE ? = true OR ? IS NOT NULL), 0)",
              rl.provider_cost_usd,
              rl.think,
              rl.effort_applied
            )
        }
      )
      |> subquery()

    from(b in buckets,
      left_join: k in ApiKey,
      on: b.api_key_id == k.id,
      order_by: [desc: b.cost_usd],
      select: %{
        api_key_id: b.api_key_id,
        label: k.label,
        key_prefix: k.key_prefix,
        status: k.status,
        request_count: b.request_count,
        cost_usd: b.cost_usd,
        prompt_tokens: b.prompt_tokens,
        completion_tokens: b.completion_tokens,
        cache_read_tokens: b.cache_read_tokens,
        error_count: b.error_count,
        error_cost_usd: b.error_cost_usd,
        think_cost_usd: b.think_cost_usd
      }
    )
  end

  defp finops_key_entry(row) do
    %{
      api_key_id: row.api_key_id,
      label: row.label || row.key_prefix || "—",
      status: row.status,
      request_count: finops_int(row.request_count),
      cost_usd: finops_usd(row.cost_usd),
      prompt_tokens: finops_int(row.prompt_tokens),
      completion_tokens: finops_int(row.completion_tokens),
      cache_read_tokens: finops_int(row.cache_read_tokens),
      error_count: finops_int(row.error_count),
      error_cost_usd: finops_usd(row.error_cost_usd),
      think_cost_usd: finops_usd(row.think_cost_usd)
    }
  end

  defp finops_service_model_rows(%{from: from, to: to}, opts) do
    base =
      RequestLog
      |> where([rl], rl.inserted_at >= ^from)
      |> maybe_to(to)
      |> finops_scope(opts)
      |> where([rl], fragment("COALESCE(?, '') <> 'router_decision'", rl.request_type))

    buckets =
      from(rl in base,
        group_by: rl.model_id,
        select: %{
          model_id: rl.model_id,
          request_count: count(rl.id),
          cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
          prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.prompt_tokens),
          completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.completion_tokens),
          cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_read_tokens),
          error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
          error_cost_usd:
            fragment(
              "COALESCE(SUM(?) FILTER (WHERE ? >= 400), 0)",
              rl.provider_cost_usd,
              rl.status_code
            ),
          think_cost_usd:
            fragment(
              "COALESCE(SUM(?) FILTER (WHERE ? = true OR ? IS NOT NULL), 0)",
              rl.provider_cost_usd,
              rl.think,
              rl.effort_applied
            )
        }
      )
      |> subquery()

    from(b in buckets,
      left_join: ma in Model,
      on: b.model_id == ma.id,
      order_by: [desc: b.cost_usd],
      select: %{
        model_name: ma.name,
        model_requested: b.model_id,
        request_count: b.request_count,
        cost_usd: b.cost_usd,
        prompt_tokens: b.prompt_tokens,
        completion_tokens: b.completion_tokens,
        cache_read_tokens: b.cache_read_tokens,
        error_count: b.error_count,
        error_cost_usd: b.error_cost_usd,
        think_cost_usd: b.think_cost_usd
      }
    )
  end

  defp finops_model_entry(row) do
    %{
      model_name: row.model_name || "—",
      request_count: finops_int(row.request_count),
      cost_usd: finops_usd(row.cost_usd),
      prompt_tokens: finops_int(row.prompt_tokens),
      completion_tokens: finops_int(row.completion_tokens),
      cache_read_tokens: finops_int(row.cache_read_tokens),
      error_count: finops_int(row.error_count),
      error_cost_usd: finops_usd(row.error_cost_usd),
      think_cost_usd: finops_usd(row.think_cost_usd)
    }
  end

  # --- FinOps: mapping ----------------------------------------------------

  defp finops_scope_key(row) do
    cond do
      row.is_total == 1 -> :total
      row.subject_type in ["user", "service"] -> row.subject_type
      true -> :other
    end
  end

  defp finops_subject_totals(nil, _scope),
    do: finops_zero_totals() |> Map.put(:active_subjects, 0)

  defp finops_subject_totals(row, :users),
    do: row |> finops_totals() |> Map.put(:active_subjects, finops_int(row.active_users))

  defp finops_subject_totals(row, :services),
    do: row |> finops_totals() |> Map.put(:active_subjects, finops_int(row.active_services))

  defp finops_subject_totals(nil), do: finops_zero_totals()

  defp finops_subject_totals(row), do: finops_totals(row)

  defp finops_totals(row) do
    %{
      requests: finops_int(row.request_count),
      cost_usd: finops_usd(row.cost_usd),
      prompt_tokens: finops_int(row.prompt_tokens),
      completion_tokens: finops_int(row.completion_tokens),
      cache_read_tokens: finops_int(row.cache_read_tokens),
      cache_creation_tokens: finops_int(row.cache_creation_tokens),
      error_requests: finops_int(row.error_requests),
      error_cost_usd: finops_usd(row.error_cost_usd),
      fallback_recovered_count: finops_int(row.fallback_recovered_count),
      think_requests: finops_int(row.think_requests),
      think_cost_usd: finops_usd(row.think_cost_usd),
      think_completion_tokens: finops_int(row.think_completion_tokens),
      local_cache_hits: finops_int(row.local_cache_hits),
      router_decision_cost_usd: finops_usd(row.router_decision_cost_usd),
      prompt_tokens_saved_est: finops_int(row.prompt_tokens_saved_est),
      topup_requests: finops_int(row.topup_requests),
      topup_cost_usd: finops_usd(row.topup_cost_usd)
    }
  end

  defp finops_zero_totals do
    %{
      requests: 0,
      cost_usd: Decimal.new(0),
      prompt_tokens: 0,
      completion_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      error_requests: 0,
      error_cost_usd: Decimal.new(0),
      fallback_recovered_count: 0,
      think_requests: 0,
      think_cost_usd: Decimal.new(0),
      think_completion_tokens: 0,
      local_cache_hits: 0,
      router_decision_cost_usd: Decimal.new(0),
      prompt_tokens_saved_est: 0,
      topup_requests: 0,
      topup_cost_usd: Decimal.new(0)
    }
  end

  defp finops_series_entry(row, granularity) do
    %{
      date: finops_bucket_date(row.bucket, granularity),
      subject_type: row.subject_type,
      request_count: row.request_count,
      cost_usd: row.cost_usd,
      error_cost_usd: row.error_cost_usd,
      think_cost_usd: row.think_cost_usd
    }
  end

  defp finops_bucket_date(%Date{} = date, _granularity), do: date
  defp finops_bucket_date(%DateTime{} = dt, :day), do: DateTime.to_date(dt)
  defp finops_bucket_date(%NaiveDateTime{} = ndt, :day), do: NaiveDateTime.to_date(ndt)
  defp finops_bucket_date(%DateTime{} = dt, _), do: dt
  defp finops_bucket_date(%NaiveDateTime{} = ndt, _), do: to_utc_datetime(ndt)

  # One comparable key for both granularities (`Date` for :day, `DateTime` for
  # :hour) so a series is ordered by instant regardless of the shape.
  defp finops_sort_key(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp finops_sort_key(%DateTime{} = dt), do: dt

  defp finops_granularity(opts) do
    case Keyword.get(opts, :granularity, :day) do
      :hour -> :hour
      "hour" -> :hour
      :day -> :day
      "day" -> :day
      other -> raise ArgumentError, "unknown :granularity #{inspect(other)} (use :day or :hour)"
    end
  end

  defp finops_timezone(opts), do: Keyword.get(opts, :timezone, "Etc/UTC")

  defp finops_int(nil), do: 0
  defp finops_int(n) when is_integer(n), do: n
  defp finops_int(%Decimal{} = d), do: d |> Decimal.round(0) |> Decimal.to_integer()

  defp finops_usd(nil), do: Decimal.new(0)
  defp finops_usd(%Decimal{} = d), do: d
  defp finops_usd(n) when is_integer(n) or is_float(n), do: Decimal.new(to_string(n))

  defp decimal_desc(a, b) do
    case Decimal.compare(a, b) do
      :gt -> true
      _ -> false
    end
  end

  # -----------------------------------------------------------------------
  # Model detail extras: services & agents using a model
  # -----------------------------------------------------------------------

  @doc "Per-service aggregate metrics for a specific model, ranked by cost desc."
  @spec breakdown_by_service_for_model(String.t() | nil, keyword()) :: [map()]
  def breakdown_by_service_for_model(model_id, opts \\ [])
  def breakdown_by_service_for_model(nil, _opts), do: []

  def breakdown_by_service_for_model(model_id, opts) when is_binary(model_id) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    RequestLog
    |> where([rl], rl.model_id == ^model_id)
    |> join(:inner, [rl], s in Tokengate.Accounts.Service, on: rl.service_id == s.id)
    |> maybe_from(from)
    |> maybe_to(to)
    |> group_by([rl, s], s.id)
    |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
    |> select([rl, s], %{
      service_id: s.id,
      service_name: s.name,
      request_count: count(rl.id),
      error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
      cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
      prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
      completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
      cache_read_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_read_tokens),
      total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
    })
    |> Repo.all(timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        service_id: row.service_id,
        service_name: row.service_name,
        request_count: row.request_count,
        error_count: row.error_count || 0,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        cache_read_tokens: row.cache_read_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  @doc "Per-agent breakdown for a specific model (normalized in read via `Tokengate.Agents`)."
  @spec breakdown_by_agent_for_model(String.t() | nil, keyword()) :: [map()]
  def breakdown_by_agent_for_model(model_id, opts \\ [])
  def breakdown_by_agent_for_model(nil, _opts), do: []

  def breakdown_by_agent_for_model(model_id, opts) when is_binary(model_id) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    RequestLog
    |> where([rl], rl.model_id == ^model_id)
    |> maybe_from(from)
    |> maybe_to(to)
    |> maybe_member_ids(Keyword.get(opts, :member_ids))
    |> group_by([rl], [rl.agent_type, rl.client_agent])
    |> select([rl], %{
      agent_type: rl.agent_type,
      client_agent: rl.client_agent,
      request_count: count(rl.id),
      error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
      cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
      prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.prompt_tokens),
      completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.completion_tokens),
      cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_read_tokens)
    })
    |> Repo.all(timeout: stats_timeout())
    |> merge_normalized_agent_rows()
  end

  defp merge_normalized_agent_rows(raw_rows) do
    raw_rows
    |> Enum.group_by(fn b -> Tokengate.Agents.identify(b.client_agent, b.agent_type).key end)
    |> Enum.map(fn {_key, [first | _] = buckets} ->
      id = Tokengate.Agents.identify(first.client_agent, first.agent_type)

      %{
        key: id.key,
        label: id.label,
        family: id.family,
        logo: id.logo,
        icon: id.icon,
        request_count: Enum.reduce(buckets, 0, &(&1.request_count + &2)),
        error_count: Enum.reduce(buckets, 0, &((&1.error_count || 0) + &2)),
        cost_usd:
          Enum.reduce(buckets, Decimal.new(0), fn b, acc ->
            Decimal.add(acc, Decimal.new(to_string(b.cost_usd || 0)))
          end),
        prompt_tokens: Enum.reduce(buckets, 0, &(&1.prompt_tokens + &2)),
        completion_tokens: Enum.reduce(buckets, 0, &(&1.completion_tokens + &2)),
        cache_read_tokens: Enum.reduce(buckets, 0, &((&1.cache_read_tokens || 0) + &2))
      }
    end)
    |> Enum.sort(fn a, b ->
      case Decimal.compare(a.cost_usd, b.cost_usd) do
        :eq -> a.request_count >= b.request_count
        :gt -> true
        :lt -> false
      end
    end)
  end

  # -----------------------------------------------------------------------
  # Provider detail daily series
  # -----------------------------------------------------------------------

  @doc "Daily request & cost series by model for a single provider."
  @spec daily_series_by_model_for_provider(String.t() | nil, keyword()) :: [map()]
  def daily_series_by_model_for_provider(provider_id, opts \\ [])
  def daily_series_by_model_for_provider(nil, _opts), do: []

  def daily_series_by_model_for_provider(provider_id, opts) when is_binary(provider_id) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    bucketed =
      RequestLog
      |> where([rl], rl.provider_id == ^provider_id)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> maybe_from(from)
      |> maybe_to(to)
      |> select([rl], %{
        bucket:
          fragment(
            "date_trunc('day', ? AT TIME ZONE ?) AT TIME ZONE ?",
            rl.inserted_at,
            ^timezone,
            ^timezone
          ),
        label: rl.model_requested,
        id: rl.id,
        spend: rl.provider_cost_usd
      })
      |> subquery()

    from(b in bucketed,
      group_by: [b.bucket, b.label],
      order_by: [b.bucket, b.label],
      select: %{
        date: b.bucket,
        label: b.label,
        request_count: count(b.id),
        total_cost: fragment("COALESCE(SUM(?), 0)", b.spend)
      }
    )
    |> Repo.all(timeout: stats_timeout())
    |> Enum.map(fn row ->
      %{
        date: to_utc_datetime(row.date),
        label: row.label || "—",
        request_count: row.request_count,
        total_cost_usd: Decimal.new(to_string(row.total_cost))
      }
    end)
  end

  # -----------------------------------------------------------------------
  # Agent detail bundle (/stats/agents/:key)
  # -----------------------------------------------------------------------

  @doc """
  Detailed analytics for a single canonical coding agent (`Tokengate.Agents.identify/2`
  key) in the bounded period: summary + effort split, models used, consumers
  (users & services) and daily series.
  """
  @spec agent_detail(String.t() | nil, keyword()) :: map() | nil
  def agent_detail(nil, _opts), do: nil

  def agent_detail(agent_key, opts) when is_binary(agent_key) do
    opts_map = Map.new(opts) |> Logs.ensure_window!("Rollup.agent_detail/2")
    from = Map.get(opts_map, :from)
    to = Map.get(opts_map, :to)
    member_ids = Map.get(opts_map, :member_ids)
    timezone = Map.get(opts_map, :timezone, "Etc/UTC")

    base =
      RequestLog
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(member_ids)

    # 1) Raw identity × effort buckets → filter by agent_key → KPIs + effort breakdown
    identity_effort_rows =
      base
      |> group_by([rl], [rl.client_agent, rl.agent_type, rl.effort_applied, rl.think])
      |> select([rl], %{
        client_agent: rl.client_agent,
        agent_type: rl.agent_type,
        effort_applied: rl.effort_applied,
        think: rl.think,
        request_count: count(rl.id),
        error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_read_tokens),
        cache_creation_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_creation_tokens),
        latency_sum_ms: fragment("COALESCE(SUM(?), 0)::bigint", rl.latency_ms),
        latency_count: fragment("COUNT(?)", rl.latency_ms)
      })
      |> Repo.all(timeout: stats_timeout())
      |> Enum.filter(fn r ->
        Tokengate.Agents.identify(r.client_agent, r.agent_type).key == agent_key
      end)

    case identity_effort_rows do
      [] ->
        nil

      [first | _] ->
        identity = Tokengate.Agents.identify(first.client_agent, first.agent_type)
        summary = summarize_agent_rows(identity_effort_rows)
        effort_breakdown = build_agent_effort_breakdown(identity_effort_rows)

        # 2) Models used by this agent
        model_rows =
          base
          |> group_by([rl], [rl.client_agent, rl.agent_type, rl.model_id])
          |> select([rl], %{
            client_agent: rl.client_agent,
            agent_type: rl.agent_type,
            model_id: rl.model_id,
            request_count: count(rl.id),
            error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
            cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
            prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.prompt_tokens),
            completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.completion_tokens),
            cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_read_tokens)
          })
          |> Repo.all(timeout: stats_timeout())
          |> Enum.filter(fn r ->
            Tokengate.Agents.identify(r.client_agent, r.agent_type).key == agent_key
          end)
          |> resolve_agent_models()

        # 3) Consumers (users + services) running this agent
        consumer_rows =
          base
          |> group_by([rl], [
            rl.client_agent,
            rl.agent_type,
            rl.subject_type,
            rl.user_id,
            rl.service_id
          ])
          |> select([rl], %{
            client_agent: rl.client_agent,
            agent_type: rl.agent_type,
            subject_type: rl.subject_type,
            user_id: rl.user_id,
            service_id: rl.service_id,
            request_count: count(rl.id),
            error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
            cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
            prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.prompt_tokens),
            completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.completion_tokens),
            cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", rl.cache_read_tokens)
          })
          |> Repo.all(timeout: stats_timeout())
          |> Enum.filter(fn r ->
            Tokengate.Agents.identify(r.client_agent, r.agent_type).key == agent_key
          end)
          |> resolve_agent_consumers()

        # 4) Daily series by model for this agent
        bucketed =
          base
          |> select([rl], %{
            bucket:
              fragment(
                "date_trunc('day', ? AT TIME ZONE ?) AT TIME ZONE ?",
                rl.inserted_at,
                ^timezone,
                ^timezone
              ),
            client_agent: rl.client_agent,
            agent_type: rl.agent_type,
            model_requested: rl.model_requested,
            id: rl.id,
            spend: rl.provider_cost_usd
          })
          |> subquery()

        daily_series =
          from(b in bucketed,
            group_by: [b.bucket, b.client_agent, b.agent_type, b.model_requested],
            order_by: [b.bucket],
            select: %{
              date: b.bucket,
              client_agent: b.client_agent,
              agent_type: b.agent_type,
              label: b.model_requested,
              request_count: count(b.id),
              total_cost: fragment("COALESCE(SUM(?), 0)", b.spend)
            }
          )
          |> Repo.all(timeout: stats_timeout())
          |> Enum.filter(fn r ->
            Tokengate.Agents.identify(r.client_agent, r.agent_type).key == agent_key
          end)
          |> Enum.group_by(&{&1.date, &1.label || "—"})
          |> Enum.map(fn {{date, label}, rows} ->
            %{
              date: to_utc_datetime(date),
              label: label,
              request_count: Enum.reduce(rows, 0, &(&1.request_count + &2)),
              total_cost_usd:
                Enum.reduce(rows, Decimal.new(0), fn r, acc ->
                  Decimal.add(acc, Decimal.new(to_string(r.total_cost || 0)))
                end)
            }
          end)
          |> Enum.sort_by(&{&1.date, &1.label})

        %{
          identity: identity,
          summary: summary,
          effort_breakdown: effort_breakdown,
          models: model_rows,
          consumers: consumer_rows,
          daily_series: daily_series
        }
    end
  end

  defp summarize_agent_rows(rows) do
    reqs = Enum.reduce(rows, 0, &(&1.request_count + &2))
    errs = Enum.reduce(rows, 0, &((&1.error_count || 0) + &2))
    lat_sum = Enum.reduce(rows, 0, &((&1.latency_sum_ms || 0) + &2))
    lat_cnt = Enum.reduce(rows, 0, &((&1.latency_count || 0) + &2))
    prompt = Enum.reduce(rows, 0, &(&1.prompt_tokens + &2))
    completion = Enum.reduce(rows, 0, &(&1.completion_tokens + &2))
    cache_read = Enum.reduce(rows, 0, &(&1.cache_read_tokens + &2))
    cache_creation = Enum.reduce(rows, 0, &(&1.cache_creation_tokens + &2))

    cost =
      Enum.reduce(rows, Decimal.new(0), fn r, acc ->
        Decimal.add(acc, Decimal.new(to_string(r.cost_usd || 0)))
      end)

    %{
      request_count: reqs,
      error_count: errs,
      error_rate: if(reqs > 0, do: Float.round(errs / reqs, 4), else: 0.0),
      cost_usd: cost,
      prompt_tokens: prompt,
      completion_tokens: completion,
      cache_read_tokens: cache_read,
      cache_creation_tokens: cache_creation,
      avg_latency_ms: if(lat_cnt > 0, do: round(lat_sum / lat_cnt), else: nil),
      avg_tps: compute_tps(completion, lat_sum)
    }
  end

  defp build_agent_effort_breakdown(rows) do
    rows
    |> Enum.group_by(fn r ->
      cond do
        is_binary(r.effort_applied) and r.effort_applied != "" -> r.effort_applied
        r.think -> "think"
        true -> "standard"
      end
    end)
    |> Enum.map(fn {bucket, b_rows} ->
      %{
        effort: bucket,
        request_count: Enum.reduce(b_rows, 0, &(&1.request_count + &2)),
        completion_tokens: Enum.reduce(b_rows, 0, &(&1.completion_tokens + &2)),
        cost_usd:
          Enum.reduce(b_rows, Decimal.new(0), fn r, acc ->
            Decimal.add(acc, Decimal.new(to_string(r.cost_usd || 0)))
          end)
      }
    end)
    |> Enum.sort(fn a, b -> Decimal.compare(a.cost_usd, b.cost_usd) != :lt end)
  end

  defp resolve_agent_models(rows) do
    model_ids = rows |> Enum.map(& &1.model_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    names =
      if model_ids == [] do
        %{}
      else
        from(m in Model, where: m.id in ^model_ids, select: {m.id, m.name})
        |> Repo.all(timeout: stats_timeout())
        |> Map.new()
      end

    rows
    |> Enum.group_by(& &1.model_id)
    |> Enum.map(fn {model_id, m_rows} ->
      %{
        model_id: model_id,
        model_name: Map.get(names, model_id) || "—",
        request_count: Enum.reduce(m_rows, 0, &(&1.request_count + &2)),
        error_count: Enum.reduce(m_rows, 0, &((&1.error_count || 0) + &2)),
        cost_usd:
          Enum.reduce(m_rows, Decimal.new(0), fn r, acc ->
            Decimal.add(acc, Decimal.new(to_string(r.cost_usd || 0)))
          end),
        prompt_tokens: Enum.reduce(m_rows, 0, &(&1.prompt_tokens + &2)),
        completion_tokens: Enum.reduce(m_rows, 0, &(&1.completion_tokens + &2)),
        cache_read_tokens: Enum.reduce(m_rows, 0, &(&1.cache_read_tokens + &2))
      }
    end)
    |> Enum.sort(fn a, b -> Decimal.compare(a.cost_usd, b.cost_usd) != :lt end)
  end

  defp resolve_agent_consumers(rows) do
    user_ids = rows |> Enum.map(& &1.user_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    service_ids = rows |> Enum.map(& &1.service_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    users =
      if user_ids == [] do
        %{}
      else
        from(u in Tokengate.Accounts.User,
          where: u.id in ^user_ids,
          select: {u.id, u.email, u.name}
        )
        |> Repo.all(timeout: stats_timeout())
        |> Map.new(fn {id, email, name} -> {id, %{email: email, name: name}} end)
      end

    services =
      if service_ids == [] do
        %{}
      else
        from(s in Tokengate.Accounts.Service, where: s.id in ^service_ids, select: {s.id, s.name})
        |> Repo.all(timeout: stats_timeout())
        |> Map.new()
      end

    rows
    |> Enum.group_by(fn r ->
      cond do
        r.subject_type == "service" and r.service_id -> {:service, r.service_id}
        r.user_id -> {:user, r.user_id}
        true -> {:unknown, nil}
      end
    end)
    |> Enum.map(fn {{kind, id}, c_rows} ->
      label =
        case kind do
          :service -> Map.get(services, id, "—")
          :user -> ((u = Map.get(users, id)) && (u.name || u.email)) || "—"
          _ -> "—"
        end

      sublabel =
        case kind do
          :user -> (u = Map.get(users, id)) && u.email
          _ -> nil
        end

      %{
        subject_type: Atom.to_string(kind),
        subject_id: id,
        label: label,
        sublabel: sublabel,
        request_count: Enum.reduce(c_rows, 0, &(&1.request_count + &2)),
        error_count: Enum.reduce(c_rows, 0, &((&1.error_count || 0) + &2)),
        cost_usd:
          Enum.reduce(c_rows, Decimal.new(0), fn r, acc ->
            Decimal.add(acc, Decimal.new(to_string(r.cost_usd || 0)))
          end),
        prompt_tokens: Enum.reduce(c_rows, 0, &(&1.prompt_tokens + &2)),
        completion_tokens: Enum.reduce(c_rows, 0, &(&1.completion_tokens + &2)),
        cache_read_tokens: Enum.reduce(c_rows, 0, &(&1.cache_read_tokens + &2))
      }
    end)
    |> Enum.sort(fn a, b -> Decimal.compare(a.cost_usd, b.cost_usd) != :lt end)
  end
end
