defmodule Tokengate.Metrics.Rollup do
  @moduledoc """
  Durable metrics rollups over `Tokengate.Logs` (the `request_logs` table).

  This is a **pure query module** — no GenServer, no new tables. It reads
  directly from Postgres via Ecto fragments so the numbers stay consistent
  with the durable source of truth. Use `Tokengate.Metrics.Collector` for
  in-memory real-time counters.

  ## Functions

    * `hourly_series/2`     — bucketed request/cost/savings per hour
    * `top_consumers/2`     — per team-member aggregates, ranked by cost
    * `agent_breakdown/1`   — per agent_type aggregates
    * `breakdown_by_model/2` — per-model aggregates (requests, costs, tokens, tps)
    * `breakdown_by_member/2` — per-member aggregates (requests, costs, tokens, tps)
    * `breakdown_by_team/1`   — per-team aggregates (requests, costs, tokens, tps)
    * `provider_ranking/2`    — provider ranking by failures + latency, tier S/A/B/C/D
    * `usage_by_hour_of_day/2` — 24h UTC distribution (recurring usage patterns)
    * `busiest_hours/2` / `busiest_minutes/2` — top-N busiest hour/minute buckets
    * `peak_concurrency/2`    — estimated max in-flight requests (sweep line)
    * `top_errors/2`          — top HTTP error codes (>= 400) by count
  """

  import Ecto.Query, warn: false

  alias Tokengate.Logs.RequestLog
  alias Tokengate.Accounts.TeamMember
  alias Tokengate.Providers.ModelAlias
  alias Tokengate.Repo

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
  hour** for the requested timezone (UTC by default). `nil` `team_id` is
  org-wide (no team join). When `team_id` is given, filters to logs whose
  team_member belongs to that team.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime); defaults to 24h ago
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:timezone` — IANA zone for local-hour bucketing; default `"Etc/UTC"`
  """
  @spec hourly_series(String.t() | nil, keyword()) :: [map()]
  def hourly_series(team_id \\ nil, opts \\ []) when is_list(opts) do
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
      |> maybe_join_team(team_id)
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
  Returns per team-member aggregates ranked by total cost (descending).

  Each row is:

      %{
        team_member_id: binary,
        request_count: integer,
        cost_usd: Decimal
      }

  Joins `request_logs` to `team_members` filtered by `team_id`. `limit`
  defaults to 10.
  """
  @spec top_consumers(String.t(), pos_integer()) :: [map()]
  def top_consumers(team_id, limit \\ 10)

  def top_consumers(team_id, limit)
      when is_binary(team_id) and is_integer(limit) and limit > 0 do
    query =
      RequestLog
      |> join(:inner, [rl], tm in TeamMember, on: rl.team_member_id == tm.id)
      |> where([rl, tm], tm.team_id == ^team_id)
      |> group_by([rl, tm], rl.team_member_id)
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> limit(^limit)
      |> select([rl], %{
        team_member_id: rl.team_member_id,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)
      })

    Repo.all(query)
    |> Enum.map(fn row ->
      %{
        team_member_id: row.team_member_id,
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

  `nil` `team_id` is org-wide. When `team_id` is given, filters to logs
  whose team_member belongs to that team.
  """
  @spec agent_breakdown(String.t() | nil) :: map()
  def agent_breakdown(team_id \\ nil)

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

  def agent_breakdown(team_id) when is_binary(team_id) do
    query =
      RequestLog
      |> join(:inner, [rl], tm in TeamMember, on: rl.team_member_id == tm.id)
      |> where([rl, tm], tm.team_id == ^team_id and not is_nil(rl.agent_type))
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

  `team_id` of `nil` is org-wide. When given, filters to logs whose
  team_member belongs to that team.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:member_ids` — restrict to logs of these team-member ids (scoping)
  """
  @spec breakdown_by_model(String.t() | nil, keyword()) :: [map()]
  def breakdown_by_model(team_id \\ nil, opts \\ [])

  def breakdown_by_model(team_id, opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    query =
      RequestLog
      |> maybe_join_team(team_id)
      |> maybe_team_member_id(Keyword.get(opts, :team_member_id))
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> join(:left, [rl], ma in ModelAlias, on: rl.model_alias_id == ma.id, as: :model_alias)
      |> group_by([model_alias: ma], ma.id)
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, model_alias: ma], %{
        model_id: ma.id,
        model_name: ma.name,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
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
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  # -----------------------------------------------------------------------
  # breakdown_by_member/2
  # -----------------------------------------------------------------------

  @doc """
  Breakdown de modelos usados por un miembro específico (por team_member_id).
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
      |> where([rl], rl.team_member_id == ^member_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> join(:left, [rl], ma in ModelAlias, on: rl.model_alias_id == ma.id, as: :model_alias)
      |> group_by([model_alias: ma], ma.id)
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, model_alias: ma], %{
        model_id: ma.id,
        model_name: ma.name,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
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
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  @doc """
  Returns per-team-member aggregate metrics ranked by total cost (descending).

  Each row is:

      %{
        team_member_id: binary,
        team_name: String.t(),
        user_email: String.t(),
        request_count: integer,
        cost_usd: Decimal,  # what the upstream charged for the request
        provider_
        estimated_
        prompt_tokens: integer,
        completion_tokens: integer,
        avg_tps: float | nil
      }

  `team_id` of `nil` is org-wide. When given, filters to logs whose
  team_member belongs to that team.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:member_ids` — restrict to logs of these team-member ids (scoping)
  """
  @spec breakdown_by_member(String.t() | nil, keyword()) :: [map()]
  def breakdown_by_member(team_id \\ nil, opts \\ [])

  def breakdown_by_member(team_id, opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    query =
      RequestLog
      |> join(:inner, [rl], tm in TeamMember, on: rl.team_member_id == tm.id)
      |> join(:inner, [_, tm], t in assoc(tm, :team))
      |> join(:inner, [_, tm], u in assoc(tm, :user))
      |> maybe_member_team_filter(team_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> group_by([rl, tm, t, u], [tm.id, t.id, u.id])
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, tm, t, u], %{
        team_member_id: tm.id,
        user_id: u.id,
        team_name: t.name,
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
        team_member_id: row.team_member_id,
        user_id: row.user_id,
        team_name: row.team_name,
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
  # breakdown_by_service/1
  # -----------------------------------------------------------------------

  @doc """
  Returns per-service aggregate metrics ranked by total cost (descending).

  Services are virtual team members (service.id = team_member_id in logs).

  Each row is:

      %{
        service_id: binary,
        service_name: String.t(),
        request_count: integer,
        cost_usd: Decimal,
        prompt_tokens: integer,
        completion_tokens: integer,
        avg_tps: float | nil
      }

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
  """
  @spec breakdown_by_service(keyword()) :: [map()]
  def breakdown_by_service(opts \\ [])

  def breakdown_by_service(opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    # Services are virtual team members with team_id = nil and user_id = nil
    # Their logs have team_member_id = service.id
    query =
      RequestLog
      |> join(:inner, [rl], s in Tokengate.Accounts.Service, on: rl.team_member_id == s.id)
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
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
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
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  # -----------------------------------------------------------------------
  # breakdown_by_team/1
  # -----------------------------------------------------------------------

  @doc """
  Returns per-team aggregate metrics ranked by total cost (descending).

  Each row is:

      %{
        team_id: binary,
        team_name: String.t(),
        request_count: integer,
        cost_usd: Decimal,  # what the upstream charged for the request
        provider_
        estimated_
        prompt_tokens: integer,
        completion_tokens: integer,
        avg_tps: float | nil
      }

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
  """
  @spec breakdown_by_team(keyword()) :: [map()]
  def breakdown_by_team(opts \\ [])

  def breakdown_by_team(opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    query =
      RequestLog
      |> join(:inner, [rl], tm in TeamMember, on: rl.team_member_id == tm.id)
      |> join(:inner, [_, tm], t in assoc(tm, :team))
      |> maybe_from(from)
      |> maybe_to(to)
      |> group_by([rl, _, t], t.id)
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, _, t], %{
        team_id: t.id,
        team_name: t.name,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })

    Repo.all(query)
    |> Enum.map(fn row ->
      %{
        team_id: row.team_id,
        team_name: row.team_name,
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  # -----------------------------------------------------------------------
  # breakdown_by_provider_for_model/2
  # -----------------------------------------------------------------------

  @doc """
  Returns per-model-provider aggregate metrics for a specific model alias,
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
        credential_name: String.t() | nil,  # API key alias
        request_count: integer,
        cost_usd: Decimal,  # what the upstream charged for the request
        prompt_tokens: integer,
        completion_tokens: integer,
        avg_tps: float | nil
      }

  `model_alias_id` of `nil` returns an empty list.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:member_ids` — restrict to logs of these team-member ids (scoping)
  """
  @spec breakdown_by_provider_for_model(String.t() | nil, keyword()) :: [map()]
  def breakdown_by_provider_for_model(model_alias_id, opts \\ [])

  def breakdown_by_provider_for_model(nil, _opts), do: []

  def breakdown_by_provider_for_model(model_alias_id, opts)
      when is_binary(model_alias_id) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    query =
      RequestLog
      |> where([rl], rl.model_alias_id == ^model_alias_id)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> join(:left, [rl], mp in Tokengate.Providers.ModelProvider,
        on: rl.model_provider_id == mp.id
      )
      |> join(:left, [rl, mp], c in Tokengate.Providers.Credential, on: mp.credential_id == c.id)
      |> join(:left, [rl, mp, c], p in Tokengate.Providers.Provider, on: c.provider_id == p.id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> group_by([rl, mp, c, p], [rl.model_provider_id, p.name, mp.provider_model, c.name])
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, mp, c, p], %{
        model_provider_id: rl.model_provider_id,
        provider_name: p.name,
        provider_model: mp.provider_model,
        credential_name: c.name,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })

    Repo.all(query)
    |> Enum.map(fn row ->
      %{
        model_provider_id: row.model_provider_id,
        provider_name: row.provider_name || "—",
        provider_model: row.provider_model,
        credential_name: row.credential_name,
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
  end

  # -----------------------------------------------------------------------
  # breakdown_by_member_for_model/2
  # -----------------------------------------------------------------------

  @doc """
  Returns per-member aggregate metrics for a specific model alias,
  ranked by total provider cost (descending).

  Each row is:

      %{
        team_member_id: binary,
        team_name: String.t(),
        user_email: String.t(),
        request_count: integer,
        cost_usd: Decimal,  # what the upstream charged for the request
        provider_
        estimated_
        prompt_tokens: integer,
        completion_tokens: integer,
        avg_tps: float | nil
      }

  `model_alias_id` of `nil` returns an empty list.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:member_ids` — restrict to logs of these team-member ids (scoping)
  """
  @spec breakdown_by_member_for_model(String.t() | nil, keyword()) :: [map()]
  def breakdown_by_member_for_model(model_alias_id, opts \\ [])

  def breakdown_by_member_for_model(nil, _opts), do: []

  def breakdown_by_member_for_model(model_alias_id, opts)
      when is_binary(model_alias_id) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    query =
      RequestLog
      |> where([rl], rl.model_alias_id == ^model_alias_id)
      |> join(:inner, [rl], tm in TeamMember, on: rl.team_member_id == tm.id)
      |> join(:inner, [_, tm], t in assoc(tm, :team))
      |> join(:inner, [_, tm], u in assoc(tm, :user))
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> group_by([rl, tm, t, u], [tm.id, t.id, u.id])
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, tm, t, u], %{
        team_member_id: tm.id,
        user_id: u.id,
        team_name: t.name,
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
        team_member_id: row.team_member_id,
        user_id: row.user_id,
        team_name: row.team_name,
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
  # breakdown_by_team_for_model/2
  # -----------------------------------------------------------------------

  @doc """
  Returns per-team aggregate metrics for a specific model alias,
  ranked by total provider cost (descending).

  Each row is:

      %{
        team_id: binary,
        team_name: String.t(),
        request_count: integer,
        cost_usd: Decimal,  # what the upstream charged for the request
        provider_
        estimated_
        prompt_tokens: integer,
        completion_tokens: integer,
        avg_tps: float | nil
      }

  `model_alias_id` of `nil` returns an empty list.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
  """
  @spec breakdown_by_team_for_model(String.t() | nil, keyword()) :: [map()]
  def breakdown_by_team_for_model(model_alias_id, opts \\ [])

  def breakdown_by_team_for_model(nil, _opts), do: []

  def breakdown_by_team_for_model(model_alias_id, opts)
      when is_binary(model_alias_id) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    query =
      RequestLog
      |> where([rl], rl.model_alias_id == ^model_alias_id)
      |> join(:inner, [rl], tm in TeamMember, on: rl.team_member_id == tm.id)
      |> join(:inner, [_, tm], t in assoc(tm, :team))
      |> maybe_from(from)
      |> maybe_to(to)
      |> group_by([rl, _, t], t.id)
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, _, t], %{
        team_id: t.id,
        team_name: t.name,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })

    Repo.all(query)
    |> Enum.map(fn row ->
      %{
        team_id: row.team_id,
        team_name: row.team_name,
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
  def provider_ranking(team_id \\ nil, opts \\ [])

  def provider_ranking(team_id, opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    rows =
      RequestLog
      |> where([rl], not is_nil(rl.provider_id))
      |> join(:inner, [rl], p in Tokengate.Providers.Provider, on: rl.provider_id == p.id)
      |> maybe_join_team(team_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> group_by([rl, p], [rl.provider_id, p.name])
      |> select([rl, p], %{
        provider_id: rl.provider_id,
        provider_name: p.name,
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
          provider_name: row.provider_name
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
  Ranking de modelos por confiabilidad (fallos) y velocidad (latencia).

  Igual que `provider_ranking/2` pero agrupado por `ModelAlias` en vez de
  por proveedor. Devuelve filas con la misma forma para reutilizar el
  rendering del tier y score.

  ## Options
    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:member_ids` — restrict to logs of these team-member ids (scoping)
  """
  @spec model_ranking(String.t() | nil, keyword()) :: [map()]
  def model_ranking(team_id \\ nil, opts \\ [])

  def model_ranking(team_id, opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    rows =
      RequestLog
      |> where([rl], not is_nil(rl.model_alias_id))
      |> join(:inner, [rl], ma in ModelAlias, on: rl.model_alias_id == ma.id)
      |> maybe_join_team(team_id)
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
  # minute_series_by_model/1
  # -----------------------------------------------------------------------

  @doc """
  Returns per-minute request counts grouped by `model_alias_id`, for
  the Monitor's 60-minute rolling sparklines.

  Each row is a 3-tuple:

      {model_alias_id :: binary, minute :: DateTime, count :: integer}

  The `minute` is `date_trunc('minute', inserted_at)` truncated to UTC.
  Only rows with non-nil `model_alias_id` are included (gate errors with
  no alias are excluded — they don't belong in the per-model sparklines).
  """
  @spec minute_series_by_model(DateTime.t()) :: [{binary, DateTime.t(), non_neg_integer()}]
  def minute_series_by_model(from) do
    bucketed =
      RequestLog
      |> where([rl], not is_nil(rl.model_alias_id) and rl.inserted_at >= ^from)
      |> select([rl], %{
        bucket: fragment("date_trunc('minute', ?)", rl.inserted_at),
        alias_id: rl.model_alias_id,
        id: rl.id
      })
      |> subquery()

    from(b in bucketed,
      group_by: [b.alias_id, b.bucket],
      select: %{alias_id: b.alias_id, minute: b.bucket, count: count(b.id)}
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      {row.alias_id, to_utc_datetime(row.minute), row.count}
    end)
  end

  # -----------------------------------------------------------------------
  # minute_series_by_credential/1
  # -----------------------------------------------------------------------

  @doc """
  Returns per-minute request counts grouped by `credential_name`, for
  the Monitor's per-API-key 60-minute rolling sparklines.

  Each row is a 3-tuple:

      {credential_name :: String.t(), minute :: DateTime, count :: integer}

  Only rows with non-nil `credential_name` are included.
  """
  @spec minute_series_by_credential(DateTime.t()) :: [{binary, DateTime.t(), non_neg_integer()}]
  def minute_series_by_credential(from) do
    bucketed =
      RequestLog
      |> where([rl], not is_nil(rl.credential_name) and rl.inserted_at >= ^from)
      |> select([rl], %{
        bucket: fragment("date_trunc('minute', ?)", rl.inserted_at),
        credential_name: rl.credential_name,
        id: rl.id
      })
      |> subquery()

    from(b in bucketed,
      group_by: [b.credential_name, b.bucket],
      select: %{credential_name: b.credential_name, minute: b.bucket, count: count(b.id)}
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      {row.credential_name, to_utc_datetime(row.minute), row.count}
    end)
  end

  # -----------------------------------------------------------------------
  # breakdown_by_credential/1
  # -----------------------------------------------------------------------

  @doc """
  Returns per-credential aggregate metrics for a specific model alias,
  ranked by request count (descending).

  Groups by `credential_name` (the API key alias stored in the log), so
  the Monitor drill-down shows which provider API keys are serving the
  model and their health.

  Each row:

      %{
        credential_name: String.t() | nil,
        provider_name: String.t() | nil,
        request_count: integer,
        error_count: integer,
        error_rate: float,
        avg_latency_ms: float | nil,
        p95_latency_ms: float | nil,
        cost_usd: Decimal,
        status: String.t() | nil
      }

  `status` comes from the `provider_credentials` table (active / disabled /
  error) via a left join on `credential_name` → `Credential.name`. May be
  nil when the credential no longer exists (e.g. logs from a deleted key).

  `model_alias_id` of `nil` returns an empty list.
  """
  @spec breakdown_by_credential(String.t() | nil, keyword()) :: [map()]
  def breakdown_by_credential(model_alias_id, opts \\ [])

  def breakdown_by_credential(nil, _opts), do: []

  def breakdown_by_credential(model_alias_id, opts) when is_binary(model_alias_id) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    rows =
      RequestLog
      |> where([rl], rl.model_alias_id == ^model_alias_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> group_by([rl], [rl.credential_name, rl.provider_id])
      |> select([rl], %{
        credential_name: rl.credential_name,
        provider_id: rl.provider_id,
        provider_key_prefix: fragment("MAX(?)", rl.provider_key_prefix),
        request_count: count(rl.id),
        error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
        avg_latency_ms: fragment("AVG(?)", rl.latency_ms),
        p95_latency_ms:
          fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", rl.latency_ms),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)
      })
      |> Repo.all()

    # Resolve provider ids → names
    provider_names =
      rows
      |> Enum.map(& &1.provider_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> then(fn ids ->
        if ids == [] do
          %{}
        else
          Tokengate.Providers.Provider
          |> where([p], p.id in ^ids)
          |> select([p], {p.id, p.name})
          |> Repo.all()
          |> Map.new()
        end
      end)

    # Resolve credential statuses by name
    cred_names =
      rows
      |> Enum.map(& &1.credential_name)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    cred_statuses =
      if cred_names == [] do
        %{}
      else
        Tokengate.Providers.Credential
        |> where([c], c.name in ^cred_names)
        |> select([c], {c.name, %{status: c.status, id: c.id}})
        |> Repo.all()
        |> Map.new()
      end

    # Members per credential: group by (credential_name, provider_id, team_member_id)
    # and join users for names.
    member_rows =
      RequestLog
      |> where([rl], rl.model_alias_id == ^model_alias_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> join(:inner, [rl], tm in Tokengate.Accounts.TeamMember, on: tm.id == rl.team_member_id)
      |> join(:left, [rl, tm], u in Tokengate.Accounts.User, on: u.id == tm.user_id)
      |> group_by([rl, tm, u], [
        rl.credential_name,
        rl.provider_id,
        rl.team_member_id,
        u.name,
        u.email
      ])
      |> select([rl, tm, u], %{
        credential_name: rl.credential_name,
        provider_id: rl.provider_id,
        member_name: u.name,
        member_email: u.email,
        request_count: count(rl.id)
      })
      |> Repo.all()

    members_by_cred =
      member_rows
      |> Enum.group_by(fn r -> {r.credential_name, r.provider_id} end)
      |> Enum.map(fn {key, rows} ->
        {key,
         rows
         |> Enum.map(fn r ->
           %{name: r.member_name || r.member_email || "—", request_count: r.request_count}
         end)
         |> Enum.sort_by(& &1.request_count, :desc)
         |> Enum.take(5)}
      end)
      |> Map.new()

    rows
    |> Enum.map(fn row ->
      req = row.request_count
      errs = row.error_count
      err_rate = if req > 0, do: errs / req * 1.0, else: 0.0

      avg_lat = row.avg_latency_ms && to_float!(row.avg_latency_ms)
      p95 = row.p95_latency_ms && to_float!(row.p95_latency_ms)

      %{
        credential_name: row.credential_name || "—",
        provider_name: Map.get(provider_names, row.provider_id, "—"),
        request_count: req,
        error_count: errs,
        error_rate: Float.round(err_rate, 4),
        avg_latency_ms: avg_lat && round(avg_lat),
        p95_latency_ms: p95 && round(p95),
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        status: Map.get(cred_statuses, row.credential_name, %{}) |> Map.get(:status),
        credential_id: Map.get(cred_statuses, row.credential_name, %{}) |> Map.get(:id),
        provider_key_prefix: row.provider_key_prefix,
        members: Map.get(members_by_cred, {row.credential_name, row.provider_id}, [])
      }
    end)
    |> Enum.sort_by(& &1.request_count, :desc)
  end

  # -----------------------------------------------------------------------
  # breakdown_by_model_for_credential/2
  # -----------------------------------------------------------------------

  @doc """
  Per-model aggregate metrics for a specific credential (API key),
  ranked by request count (descending).

  Mirrors `breakdown_by_credential/2` but instead of showing which
  credentials serve a model, it shows which models are served by a
  credential — the drill-down for the "Por API key" Monitor tab.

  Each row:

      %{
        model_name: String.t(),
        request_count: integer,
        error_count: integer,
        error_rate: float,
        avg_latency_ms: integer | nil,
        p95_latency_ms: integer | nil,
        cost_usd: Decimal,
        status: String.t() | nil,
        members: [%{name: String.t(), request_count: integer}]
      }
  """
  @spec breakdown_by_model_for_credential(String.t() | nil, keyword()) :: [map()]
  def breakdown_by_model_for_credential(nil, _opts), do: []

  def breakdown_by_model_for_credential(credential_name, opts) when is_binary(credential_name) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    rows =
      RequestLog
      |> where([rl], rl.credential_name == ^credential_name)
      |> maybe_from(from)
      |> maybe_to(to)
      |> group_by([rl], [rl.model_alias_id])
      |> select([rl], %{
        model_alias_id: rl.model_alias_id,
        provider_key_prefix: fragment("MAX(?)", rl.provider_key_prefix),
        request_count: count(rl.id),
        error_count: fragment("COUNT(*) FILTER (WHERE ? >= 400)", rl.status_code),
        avg_latency_ms: fragment("AVG(?)", rl.latency_ms),
        p95_latency_ms:
          fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", rl.latency_ms),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)
      })
      |> Repo.all()

    # Resolve credential_id from credential_name
    credential =
      Tokengate.Providers.Credential
      |> where([c], c.name == ^credential_name)
      |> select([c], %{id: c.id, status: c.status})
      |> Repo.one()

    # Resolve model_alias_id → name
    alias_ids =
      rows
      |> Enum.map(& &1.model_alias_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    alias_names =
      if alias_ids == [] do
        %{}
      else
        Tokengate.Providers.ModelAlias
        |> where([ma], ma.id in ^alias_ids)
        |> select([ma], {ma.id, ma.name})
        |> Repo.all()
        |> Map.new()
      end

    # Members per model
    member_rows =
      RequestLog
      |> where([rl], rl.credential_name == ^credential_name)
      |> maybe_from(from)
      |> maybe_to(to)
      |> join(:inner, [rl], tm in Tokengate.Accounts.TeamMember, on: tm.id == rl.team_member_id)
      |> join(:left, [rl, tm], u in Tokengate.Accounts.User, on: u.id == tm.user_id)
      |> group_by([rl, tm, u], [rl.model_alias_id, rl.team_member_id, u.name, u.email])
      |> select([rl, tm, u], %{
        model_alias_id: rl.model_alias_id,
        member_name: u.name,
        member_email: u.email,
        request_count: count(rl.id)
      })
      |> Repo.all()

    members_by_model =
      member_rows
      |> Enum.group_by(& &1.model_alias_id)
      |> Enum.map(fn {alias_id, m_rows} ->
        {alias_id,
         m_rows
         |> Enum.map(fn r ->
           %{name: r.member_name || r.member_email || "—", request_count: r.request_count}
         end)
         |> Enum.sort_by(& &1.request_count, :desc)
         |> Enum.take(5)}
      end)
      |> Map.new()

    rows
    |> Enum.map(fn row ->
      req = row.request_count
      errs = row.error_count
      err_rate = if req > 0, do: errs / req * 1.0, else: 0.0

      avg_lat = row.avg_latency_ms && to_float!(row.avg_latency_ms)
      p95 = row.p95_latency_ms && to_float!(row.p95_latency_ms)

      %{
        model_name: Map.get(alias_names, row.model_alias_id, row.model_alias_id || "—"),
        request_count: req,
        error_count: errs,
        error_rate: Float.round(err_rate, 4),
        avg_latency_ms: avg_lat && round(avg_lat),
        p95_latency_ms: p95 && round(p95),
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        status: nil,
        credential_id: credential && credential.id,
        provider_key_prefix: row.provider_key_prefix,
        members: Map.get(members_by_model, row.model_alias_id, [])
      }
    end)
    |> Enum.sort_by(& &1.request_count, :desc)
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
    * `:member_ids` — restrict to logs of these team-member ids (scoping)
    * `:timezone` — IANA zone for the hour-of-day extraction; default `"Etc/UTC"`
  """
  @spec usage_by_hour_of_day(String.t() | nil, keyword()) :: [map()]
  def usage_by_hour_of_day(team_id \\ nil, opts \\ []) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    counts =
      RequestLog
      |> maybe_join_team(team_id)
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
  # cost_by_hour_of_day_stacked/2
  # -----------------------------------------------------------------------

  @doc """
  Uso total por hora del día, con desglose por modelo.

  Incluye TODOS los modelos (pay_per_token e included). Para cada hora:

      %{
        hour: 0..23,
        total_requests: integer,
        total_cost_usd: Decimal,      # solo pay_per_token tiene costo > 0
        models: [
          %{
            model: String.t(),
            requests: integer,
            cost_usd: Decimal,        # 0 para included
            billing_mode: String.t()
          }
        ]
      }

  La barra muestra `total_requests` (todos los modelos). El segmento
  destacado es la proporción de requests de modelos pay_per_token.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:member_ids` — restrict to logs of these team-member ids (scoping)
    * `:timezone` — IANA zone for the hour-of-day extraction; default `"Etc/UTC"`
  """
  @spec usage_by_hour_of_day_stacked(String.t() | nil, keyword()) :: [map()]
  def usage_by_hour_of_day_stacked(team_id \\ nil, opts \\ []) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    rows =
      RequestLog
      |> join(:left, [rl], mp in Tokengate.Providers.ModelProvider,
        on: rl.model_provider_id == mp.id
      )
      |> maybe_join_team(team_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))
      |> join(:left, [rl], ma in ModelAlias, on: rl.model_alias_id == ma.id)
      |> select([rl, mp, ma], %{
        hour:
          fragment(
            "CAST(EXTRACT(hour FROM (? AT TIME ZONE 'Etc/UTC') AT TIME ZONE ?) AS integer)",
            rl.inserted_at,
            ^timezone
          ),
        model: fragment("COALESCE(?, ?)", ma.name, rl.model_requested),
        billing_mode: fragment("COALESCE(?, 'unknown')", mp.billing_mode),
        cost_usd: rl.provider_cost_usd,
        id: rl.id
      })
      |> subquery()
      |> then(fn subq ->
        from(r in subq,
          group_by: [r.hour, r.model, r.billing_mode],
          select: %{
            hour: r.hour,
            model: r.model,
            billing_mode: r.billing_mode,
            cost_usd: fragment("COALESCE(SUM(?), 0)", r.cost_usd),
            request_count: count(r.id)
          }
        )
      end)
      |> Repo.all()

    by_hour =
      rows
      |> Enum.group_by(& &1.hour)

    for hour <- 0..23 do
      hour_rows = Map.get(by_hour, hour, [])

      # Agrupar por (model, billing_mode) — un mismo model alias puede tener
      # providers incluidos y pay_per_token simultáneamente.
      by_model_billing =
        hour_rows
        |> Enum.group_by(&{&1.model, &1.billing_mode})
        |> Enum.map(fn {{model, billing_mode}, entries} ->
          requests = Enum.reduce(entries, 0, &(&1.request_count + &2))

          cost =
            Enum.reduce(entries, Decimal.new(0), fn e, acc -> Decimal.add(acc, e.cost_usd) end)

          %{
            model: model,
            requests: requests,
            cost_usd: cost,
            billing_mode: billing_mode
          }
        end)
        |> Enum.sort_by(& &1.requests, :desc)

      total_requests = Enum.reduce(by_model_billing, 0, &(&1.requests + &2))

      # Totales por billing_mode desde los rows agrupados del SQL (no del
      # by_model aplanado) para no perder requests cuando un modelo tiene
      # providers mixtos. Los NULL/unknown se tratan como pay_per_token
      # (el default del schema) para no perderlos en la visualización.
      included_requests =
        hour_rows
        |> Enum.filter(&(&1.billing_mode == "included"))
        |> Enum.reduce(0, &(&1.request_count + &2))

      pay_per_token_requests =
        hour_rows
        |> Enum.filter(&(&1.billing_mode != "included"))
        |> Enum.reduce(0, &(&1.request_count + &2))

      total_cost =
        hour_rows
        |> Enum.filter(&(&1.billing_mode != "included"))
        |> Enum.reduce(Decimal.new(0), fn e, acc -> Decimal.add(acc, e.cost_usd) end)

      %{
        hour: hour,
        total_requests: total_requests,
        included_requests: included_requests,
        pay_per_token_requests: pay_per_token_requests,
        total_cost_usd: total_cost,
        models: by_model_billing
      }
    end
  end

  # -----------------------------------------------------------------------
  # usage_by_model_provider_stacked/2
  # -----------------------------------------------------------------------

  @doc """
  Requests agrupados por model alias, con desglose por proveedor (ModelProvider).

  Devuelve una lista de modelos, cada uno con su total de requests y la lista
  de proveedores que lo sirvieron (con requests, billing_mode y costo).

  Las barras horizontales de la gráfica de stats usan esta data: una barra
  por modelo, segmentos apilados por proveedor.

  ## Opciones

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
    * `:member_ids` — restrict to logs of these team-member ids (scoping)
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
      |> join(:left, [rl], ma in ModelAlias, on: rl.model_alias_id == ma.id)
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
        [ma.id, ma.name, mp.id, p.name, mp.billing_mode]
      )
      |> select(
        [rl, ma, mp, c, p],
        %{
          model_id: ma.id,
          model_name: ma.name,
          provider_id: mp.id,
          provider_name: p.name,
          billing_mode: fragment("COALESCE(?, 'pay_per_token')", mp.billing_mode),
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
          provider_name: row.provider_name || "—",
          billing_mode: row.billing_mode || "pay_per_token",
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

          billing_mode = List.first(p_entries).billing_mode

          %{
            provider_name: provider_name,
            requests: requests,
            cost_usd: cost,
            billing_mode: billing_mode
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
  def busiest_hours(team_id \\ nil, opts \\ []),
    do: busiest_buckets(team_id, "hour", opts)

  @doc """
  Top N minutos (buckets `date_trunc('minute')`) con más requests en el
  período, ordenados desc. Cada fila: `%{bucket: DateTime, request_count}`.
  """
  @spec busiest_minutes(String.t() | nil, keyword()) :: [map()]
  def busiest_minutes(team_id \\ nil, opts \\ []),
    do: busiest_buckets(team_id, "minute", opts)

  # El unit va como bind param (`^unit`); el bucket se materializa en una
  # subquery para que GROUP BY/ORDER BY/SELECT compartan la misma columna
  # (Postgres rechaza expresiones parametrizadas formalmente distintas).
  defp busiest_buckets(team_id, unit, opts) when unit in ["hour", "minute"] do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    limit = Keyword.get(opts, :limit, 5)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    bucketed =
      RequestLog
      |> maybe_join_team(team_id)
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

  Nota: carga `(inserted_at, latency_ms)` del período en memoria — es una
  estimación para dashboards, no para hot paths.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
  """
  @spec peak_concurrency(String.t() | nil, keyword()) :: map()
  def peak_concurrency(team_id \\ nil, opts \\ []) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    events =
      RequestLog
      |> maybe_join_team(team_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> select([rl], %{inserted_at: rl.inserted_at, latency_ms: rl.latency_ms})
      |> Repo.all()
      |> Enum.flat_map(fn row ->
        latency = row.latency_ms || 0
        start_at = DateTime.add(row.inserted_at, -latency, :millisecond)
        # En empate de timestamp, los finales (-1) van antes que los
        # inicios (+1): un request que termina justo cuando otro empieza
        # no cuenta como concurrente.
        [{start_at, 1}, {row.inserted_at, -1}]
      end)
      |> Enum.sort(fn {ts_a, delta_a}, {ts_b, delta_b} ->
        case DateTime.compare(ts_a, ts_b) do
          :lt -> true
          :gt -> false
          :eq -> delta_a <= delta_b
        end
      end)

    {max_concurrent, at, _current} =
      Enum.reduce(events, {0, nil, 0}, fn {ts, delta}, {max, max_at, current} ->
        current = current + delta

        if current > max do
          {current, ts, current}
        else
          {max, max_at, current}
        end
      end)

    %{max_concurrent: max_concurrent, at: at}
  end

  # -----------------------------------------------------------------------
  # member_usage_tiers/2
  # -----------------------------------------------------------------------

  @doc """
  Clasifica a los miembros de un equipo en 3 tiers de uso: alto, regular, bajo.

  Combina volumen (tokens, costo, requests), frecuencia (días activos),
  y concurrencia (pico de requests simultáneos por minuto) en un score
  compuesto 0-100. Después aplica terciles para dividir en 3 grupos.

  ## Clasificación

    * `"alto"`   — score ≥ 66 (tercil superior)
    * `"regular"` — score 33-65 (tercil medio)
    * `"bajo"`   — score < 33 (tercil inferior) o sin actividad

  ## Métricas por miembro

      %{
        team_member_id: binary,
        team_name: String.t(),
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
    * `:member_ids` — restrict to logs of these team-member ids (scoping)
  """
  @spec member_usage_tiers(String.t() | nil, keyword()) :: [map()]
  def member_usage_tiers(team_id \\ nil, opts \\ []) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    base_query =
      RequestLog
      |> join(:inner, [rl], tm in TeamMember, on: rl.team_member_id == tm.id)
      |> join(:inner, [_, tm], t in assoc(tm, :team))
      |> join(:inner, [_, tm], u in assoc(tm, :user))
      |> maybe_member_team_filter(team_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> maybe_member_ids(Keyword.get(opts, :member_ids))

    # Base aggregates per member
    members =
      base_query
      |> group_by([rl, tm, t, u], [tm.id, t.name, u.email, u.name])
      |> select([rl, tm, t, u], %{
        team_member_id: tm.id,
        team_name: t.name,
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

    member_ids = Enum.map(members, & &1.team_member_id)

    # RPM stats per member (peak, avg, p95)
    rpm_stats = rpm_stats_per_member(member_ids, from, to)

    # Merge and compute score + tier
    members
    |> Enum.map(fn member ->
      stats = Map.get(rpm_stats, member.team_member_id, %{})

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
      |> where([rl], rl.team_member_id in ^member_ids)
      |> maybe_from(from)
      |> maybe_to(to)
      |> select([rl], %{
        team_member_id: rl.team_member_id,
        minute: fragment("date_trunc('minute', ?)", rl.inserted_at)
      })
      |> subquery()

    query =
      from(m in minute_buckets,
        group_by: [m.team_member_id, m.minute],
        select: %{
          team_member_id: m.team_member_id,
          minute: m.minute,
          rpm: count()
        }
      )

    rows = Repo.all(query)

    rows
    |> Enum.group_by(& &1.team_member_id)
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
    * `:member_ids` — restrict to logs of these team-member ids (scoping)
  """
  @spec top_errors(String.t() | nil, keyword()) :: [map()]
  def top_errors(team_id \\ nil, opts \\ []) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    limit = Keyword.get(opts, :limit, 5)

    RequestLog
    |> where([rl], rl.status_code >= 400)
    |> maybe_join_team(team_id)
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
  # Internals
  # -----------------------------------------------------------------------

  defp maybe_member_team_filter(query, nil), do: query

  defp maybe_member_team_filter(query, team_id) when is_binary(team_id) do
    where(query, [rl, tm, t, u], tm.team_id == ^team_id)
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

  defp to_utc_datetime(%DateTime{} = dt), do: dt

  defp to_utc_datetime(%NaiveDateTime{} = ndt) do
    # date_trunc returns a NaiveDateTime in Postgres; assume UTC.
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  defp maybe_join_team(query, nil), do: query

  defp maybe_join_team(query, team_id) when is_binary(team_id) do
    query
    |> join(:inner, [rl], tm in TeamMember, on: rl.team_member_id == tm.id)
    |> where([rl, tm], tm.team_id == ^team_id)
  end

  # Scoping filter: restrict rows to the given team-member ids. `nil` means
  # unrestricted (admin scope); an empty list matches nothing (user with no
  # memberships sees zero rows, never org-wide data).
  defp maybe_member_ids(query, nil), do: query

  defp maybe_member_ids(query, member_ids) when is_list(member_ids) do
    where(query, [rl], rl.team_member_id in ^member_ids)
  end

  # Single team_member_id filter (used for service drill-down).
  defp maybe_team_member_id(query, nil), do: query

  defp maybe_team_member_id(query, team_member_id) when is_binary(team_member_id) do
    where(query, [rl], rl.team_member_id == ^team_member_id)
  end
end
