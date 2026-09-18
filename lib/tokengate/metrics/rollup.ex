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
  alias Tokengate.Accounts.GroupMember
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

    Repo.all(query)
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

    Repo.all(query)
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

    Repo.all(query)
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

    Repo.all(query)
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
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_read_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })

    Repo.all(query)
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

    Repo.all(query)
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

    Repo.all(query)
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
    query =
      RequestLog
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
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })

    # Resolve group names outside the aggregate so the index-driven join
    # stays a single pass (a join to groups in the GROUP BY would force a
    # second sort over the whole range scan). El par id+nombre viaja junto:
    # el id es lo único que permite enlazar el perfil de límites desde el listado, y
    # resolver el nombre antes de perder el id dejaba el perfil de límites como texto
    # muerto (el campo se llamaba `group_names` pero traía ids).
    group_names_by_id = Tokengate.Accounts.group_names_by_id()

    Repo.all(query)
    |> Enum.map(fn row ->
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
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
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
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_read_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms),
        latency_count: fragment("COUNT(?)", rl.latency_ms)
      })

    Repo.all(query)
    |> Enum.map(fn row ->
      %{
        service_id: row.service_id,
        service_name: row.service_name,
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        cache_read_tokens: row.cache_read_tokens,
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

    Repo.all(query)
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
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_read_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })

    Repo.all(query)
    |> Enum.map(fn row ->
      %{
        group_id: row.group_id,
        group_name: row.group_name,
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
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)", rl.cache_read_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })

    Repo.all(query)
    |> Enum.map(fn row ->
      %{
        model_provider_id: row.model_provider_id,
        provider_id: row.provider_id,
        provider_name: row.provider_name || "—",
        provider_logo_url: row.provider_logo_url,
        provider_model: row.provider_model,
        credential_name: row.credential_name,
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

    Repo.all(query)
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

    Repo.all(query)
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

    rows =
      RequestLog
      |> where([rl], not is_nil(rl.provider_id))
      |> join(:inner, [rl], p in Tokengate.Providers.Provider, on: rl.provider_id == p.id)
      |> maybe_join_group(group_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> group_by([rl, p], [rl.provider_id, p.name, p.key, p.logo_url, p.doc_url])
      |> select([rl, p], %{
        provider_id: rl.provider_id,
        provider_name: p.name,
        # Identidad del catálogo: viaja con la fila para que la tabla y el
        # detalle puedan pintar el logo y los datos del proveedor sin una
        # segunda query por fila.
        provider_key: p.key,
        provider_logo_url: p.logo_url,
        provider_doc_url: p.doc_url,
        request_count: count(rl.id),
        error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
        avg_latency_ms: fragment("AVG(?)", rl.latency_ms),
        p95_latency_ms:
          fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", rl.latency_ms),
        avg_ttft_ms: fragment("AVG(?)", rl.ttft_ms)
      })
      |> Repo.all()

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
        Map.merge(base, %{
          provider_id: row.provider_id,
          provider_name: row.provider_name,
          provider_key: Map.get(row, :provider_key),
          provider_logo_url: Map.get(row, :provider_logo_url),
          provider_doc_url: Map.get(row, :provider_doc_url)
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

    rows =
      RequestLog
      |> where([rl], not is_nil(rl.model_id))
      |> join(:inner, [rl], ma in Model, on: rl.model_id == ma.id)
      |> maybe_join_group(group_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> group_by([rl, ma], [ma.id, ma.name])
      |> select([rl, ma], %{
        model_id: ma.id,
        model_name: ma.name,
        request_count: count(rl.id),
        error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
        avg_latency_ms: fragment("AVG(?)", rl.latency_ms),
        p95_latency_ms:
          fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", rl.latency_ms),
        avg_ttft_ms: fragment("AVG(?)", rl.ttft_ms)
      })
      |> Repo.all()

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
      |> Repo.all()
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
      |> Repo.all()

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
        |> Repo.all()
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
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    rows =
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
      |> join(:left, [rl, ma, mp, c], p in Tokengate.Providers.Provider,
        on: c.provider_id == p.id
      )
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
      |> Repo.all()
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

    # Agrupar por modelo
    rows
    |> Enum.group_by(& &1.model_id)
    |> Enum.map(fn {_model_id, entries} ->
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

      %{
        model_name: model_name,
        total_requests: total_requests,
        providers: providers
      }
    end)
    |> Enum.sort_by(& &1.total_requests, :desc)
    |> Enum.take(10)
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

  # El unit va como bind param (`^unit`); el bucket se materializa en una
  # subquery para que GROUP BY/ORDER BY/SELECT compartan la misma columna
  # (Postgres rechaza expresiones parametrizadas formalmente distintas).
  defp busiest_buckets(group_id, unit, opts) when unit in ["hour", "minute"] do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    limit = Keyword.get(opts, :limit, 5)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    bucketed =
      RequestLog
      |> maybe_join_group(group_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> select([rl], %{
        bucket:
          fragment(
            "date_trunc(?, ? AT TIME ZONE ?) AT TIME ZONE ?",
            ^unit,
            rl.inserted_at,
            ^timezone,
            ^timezone
          ),
        id: rl.id
      })
      |> subquery()

    from(b in bucketed,
      group_by: b.bucket,
      order_by: [desc: count(b.id), asc: b.bucket],
      limit: ^limit,
      select: %{
        bucket: b.bucket,
        request_count: count(b.id)
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      %{bucket: to_utc_datetime(row.bucket), request_count: row.request_count}
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
    |> Repo.one()
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
      |> Repo.all()
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

  defp rpm_stats_per_member(member_ids, from, to) do
    # Bucket requests by minute per member
    minute_buckets =
      RequestLog
      |> where([rl], rl.group_member_id in ^member_ids)
      |> maybe_from(from)
      |> maybe_to(to)
      |> select([rl], %{
        group_member_id: rl.group_member_id,
        minute: fragment("date_trunc('minute', ?)", rl.inserted_at)
      })
      |> subquery()

    query =
      from(m in minute_buckets,
        group_by: [m.group_member_id, m.minute],
        select: %{
          group_member_id: m.group_member_id,
          minute: m.minute,
          rpm: count()
        }
      )

    rows = Repo.all(query)

    rows
    |> Enum.group_by(& &1.group_member_id)
    |> Map.new(fn {member_id, member_rows} ->
      rpms = Enum.map(member_rows, & &1.rpm)
      count = length(rpms)

      peak = Enum.max(rpms, fn -> 0 end)
      avg = if count > 0, do: Float.round(Enum.sum(rpms) / count, 1), else: 0.0

      # Nearest-rank p95
      sorted = Enum.sort(rpms)

      p95 =
        if count < 20 do
          peak
        else
          rank = ceil(0.95 * count)
          index = max(rank - 1, 0)
          Enum.at(sorted, index)
        end

      {member_id, %{peak_rpm: peak, avg_rpm: avg, p95_rpm: p95}}
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
    |> Repo.all()
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
    * `:timezone` — IANA zone for local-hour bucketing; default `"Etc/UTC"`
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

    Repo.all(query)
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
    |> Repo.all()
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

    Repo.all(query)
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
      |> Repo.one()

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
    |> Repo.one()
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
      |> join(:left, [m], ma in Model, on: m.model_id == ma.id, as: :model)
      |> group_by([model: ma], ma.id)
      |> order_by([m], desc: fragment("COALESCE(SUM(?), 0)", m.cost_micro))
      |> select([m, model: ma], %{
        model_id: ma.id,
        model_name: ma.name,
        request_count: fragment("COALESCE(SUM(?), 0)::bigint", m.request_count),
        cost_usd_raw: fragment("COALESCE(SUM(?), 0)::bigint", m.cost_micro),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.cache_read_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)::bigint", m.total_latency_ms)
      })

    query
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        model_id: row.model_id,
        model_name: row.model_name || "—",
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
    |> Repo.all()
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
        cost_usd_raw: fragment("COALESCE(SUM(?), 0)::bigint", m.cost_micro),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.completion_tokens),
        cache_read_tokens: fragment("COALESCE(SUM(?), 0)::bigint", m.cache_read_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)::bigint", m.total_latency_ms)
      })

    query
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        group_id: row.group_id,
        group_name: row.group_name,
        request_count: row.request_count,
        cost_usd: micro_to_decimal(row.cost_usd_raw),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        cache_read_tokens: row.cache_read_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  # Rollup-table filter helpers (day ranges are inclusive on `day`).
  defp maybe_rollup_from(query, nil), do: query

  defp maybe_rollup_from(query, %DateTime{} = from) do
    where(query, [m], m.hour_utc >= ^from)
  end

  defp maybe_rollup_to(query, nil), do: query

  # Semántica exclusiva: un bucket de hora cubre [hour_utc, hour_utc + 1h),
  # así que sólo responde contenido ANTERIOR a `to`. Con `<=`, una ventana
  # que termina justo en un borde de hora (los períodos anteriores de los
  # deltas) se tragaba el bucket entero que arranca en `to` — hasta una hora
  # de tráfico fuera de la ventana en cada KPI.
  defp maybe_rollup_to(query, %DateTime{} = to) do
    where(query, [m], m.hour_utc < ^to)
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

  defp maybe_to(query, nil), do: query
  defp maybe_to(query, to), do: where(query, [rl], rl.inserted_at <= ^to)

  defp compute_tps(_tokens, 0), do: nil
  defp compute_tps(0, _latency), do: 0.0

  defp compute_tps(tokens, latency_ms) when is_integer(tokens) and is_integer(latency_ms) do
    Float.round(tokens / (latency_ms / 1000), 1)
  end

  defp compute_tps(_, _), do: nil

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
        id: rl.id
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
          request_count: count(b.id)
        }
      )

    Repo.all(query)
    |> Enum.map(fn row ->
      %{
        date: to_utc_datetime(row.date),
        label: row.label || "—",
        label_logo: row.label_logo,
        request_count: row.request_count
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

    Repo.all(query)
    |> Enum.map(fn row ->
      %{
        date: to_utc_datetime(row.date),
        label: row.label || "—",
        request_count: row.request_count
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

    Repo.all(query)
    |> Enum.map(fn row ->
      %{
        date: to_utc_datetime(row.date),
        label: row.label || "—",
        request_count: row.request_count
      }
    end)
  end
end
