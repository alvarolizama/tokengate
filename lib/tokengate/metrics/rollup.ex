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
        hour: DateTime,          # truncated to the hour (UTC)
        request_count: integer,
        cost_usd: Decimal,
        savings_usd: Decimal
      }

  Buckets `inserted_at` using Postgres `date_trunc("hour", inserted_at)`.
  `nil` `team_id` is org-wide (no team join). When `team_id` is given,
  filters to logs whose team_member belongs to that team.

  `hours` defaults to 24 and is clamped to the last `hours` from now.
  """
  @spec hourly_series(String.t() | nil, pos_integer()) :: [map()]
  def hourly_series(team_id \\ nil, hours \\ 24)

  def hourly_series(team_id, hours) when is_integer(hours) and hours > 0 do
    from_ts =
      DateTime.utc_now()
      |> DateTime.add(-hours * 3600, :second)
      |> DateTime.truncate(:second)

    query =
      RequestLog
      |> where([rl], rl.inserted_at >= ^from_ts)
      |> maybe_join_team(team_id)
      |> group_by([rl], fragment("date_trunc('hour', ?)", rl.inserted_at))
      |> order_by([rl], fragment("date_trunc('hour', ?)", rl.inserted_at))
      |> select([rl], %{
        hour: fragment("date_trunc('hour', ?)", rl.inserted_at),
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.cost_usd),
        savings_usd: fragment("COALESCE(SUM(?), 0)", rl.savings_usd)
      })

    Repo.all(query)
    |> Enum.map(fn row ->
      %{
        # date_trunc returns a NaiveDateTime in Postgres; convert to UTC
        # DateTime so consumers can compare apples-to-apples.
        hour: to_utc_datetime(row.hour),
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        savings_usd: Decimal.new(to_string(row.savings_usd))
      }
    end)
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
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.cost_usd))
      |> limit(^limit)
      |> select([rl], %{
        team_member_id: rl.team_member_id,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.cost_usd)
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
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.cost_usd)
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
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.cost_usd)
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
        cost_usd: Decimal,            # what the provider charged (cost_usd)
        provider_cost_usd: Decimal,  # what was actually paid
        estimated_cost_usd: Decimal, # market estimate
        savings_usd: Decimal,
        prompt_tokens: integer,
        completion_tokens: integer,
        avg_tps: float | nil
      }

  `team_id` of `nil` is org-wide. When given, filters to logs whose
  team_member belongs to that team.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
  """
  @spec breakdown_by_model(String.t() | nil, keyword()) :: [map()]
  def breakdown_by_model(team_id \\ nil, opts \\ [])

  def breakdown_by_model(team_id, opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    query =
      RequestLog
      |> maybe_join_team(team_id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> join(:left, [rl], ma in ModelAlias, on: rl.model_alias_id == ma.id, as: :model_alias)
      |> group_by([model_alias: ma], ma.id)
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.cost_usd))
      |> select([rl, model_alias: ma], %{
        model_id: ma.id,
        model_name: ma.name,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.cost_usd),
        provider_cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        estimated_cost_usd: fragment("COALESCE(SUM(?), 0)", rl.estimated_cost_usd),
        savings_usd: fragment("COALESCE(SUM(?), 0)", rl.savings_usd),
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
        provider_cost_usd: Decimal.new(to_string(row.provider_cost_usd)),
        estimated_cost_usd: Decimal.new(to_string(row.estimated_cost_usd)),
        savings_usd: Decimal.new(to_string(row.savings_usd)),
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
  Returns per-team-member aggregate metrics ranked by total cost (descending).

  Each row is:

      %{
        team_member_id: binary,
        team_name: String.t(),
        user_email: String.t(),
        request_count: integer,
        cost_usd: Decimal,
        provider_cost_usd: Decimal,
        estimated_cost_usd: Decimal,
        savings_usd: Decimal,
        prompt_tokens: integer,
        completion_tokens: integer,
        avg_tps: float | nil
      }

  `team_id` of `nil` is org-wide. When given, filters to logs whose
  team_member belongs to that team.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
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
      |> group_by([rl, tm, t, u], [tm.id, t.id, u.id])
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.cost_usd))
      |> select([rl, tm, t, u], %{
        team_member_id: tm.id,
        team_name: t.name,
        user_email: u.email,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.cost_usd),
        provider_cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        estimated_cost_usd: fragment("COALESCE(SUM(?), 0)", rl.estimated_cost_usd),
        savings_usd: fragment("COALESCE(SUM(?), 0)", rl.savings_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })

    Repo.all(query)
    |> Enum.map(fn row ->
      %{
        team_member_id: row.team_member_id,
        team_name: row.team_name,
        user_email: row.user_email,
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        provider_cost_usd: Decimal.new(to_string(row.provider_cost_usd)),
        estimated_cost_usd: Decimal.new(to_string(row.estimated_cost_usd)),
        savings_usd: Decimal.new(to_string(row.savings_usd)),
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
        cost_usd: Decimal,
        provider_cost_usd: Decimal,
        estimated_cost_usd: Decimal,
        savings_usd: Decimal,
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
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.cost_usd))
      |> select([rl, _, t], %{
        team_id: t.id,
        team_name: t.name,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.cost_usd),
        provider_cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        estimated_cost_usd: fragment("COALESCE(SUM(?), 0)", rl.estimated_cost_usd),
        savings_usd: fragment("COALESCE(SUM(?), 0)", rl.savings_usd),
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
        provider_cost_usd: Decimal.new(to_string(row.provider_cost_usd)),
        estimated_cost_usd: Decimal.new(to_string(row.estimated_cost_usd)),
        savings_usd: Decimal.new(to_string(row.savings_usd)),
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
  Returns per-provider aggregate metrics for a specific model alias,
  ranked by total provider cost (descending).

  Each row is:

      %{
        provider_id: binary | nil,
        provider_name: String.t(),
        request_count: integer,
        cost_usd: Decimal,            # what the provider charges
        provider_cost_usd: Decimal,  # what was actually paid
        estimated_cost_usd: Decimal, # market estimate
        savings_usd: Decimal,
        prompt_tokens: integer,
        completion_tokens: integer,
        avg_tps: float | nil
      }

  `model_alias_id` of `nil` returns an empty list.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
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
      |> join(:left, [rl], p in Tokengate.Providers.Provider, on: rl.provider_id == p.id)
      |> maybe_from(from)
      |> maybe_to(to)
      |> group_by([rl, p], p.id)
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, p], %{
        provider_id: p.id,
        provider_name: p.name,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.cost_usd),
        provider_cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        estimated_cost_usd: fragment("COALESCE(SUM(?), 0)", rl.estimated_cost_usd),
        savings_usd: fragment("COALESCE(SUM(?), 0)", rl.savings_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })

    Repo.all(query)
    |> Enum.map(fn row ->
      %{
        provider_id: row.provider_id,
        provider_name: row.provider_name || "—",
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        provider_cost_usd: Decimal.new(to_string(row.provider_cost_usd)),
        estimated_cost_usd: Decimal.new(to_string(row.estimated_cost_usd)),
        savings_usd: Decimal.new(to_string(row.savings_usd)),
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
        cost_usd: Decimal,
        provider_cost_usd: Decimal,
        estimated_cost_usd: Decimal,
        savings_usd: Decimal,
        prompt_tokens: integer,
        completion_tokens: integer,
        avg_tps: float | nil
      }

  `model_alias_id` of `nil` returns an empty list.

  ## Options

    * `:from` — `inserted_at >= from` (DateTime)
    * `:to`   — `inserted_at <= to` (DateTime)
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
      |> group_by([rl, tm, t, u], [tm.id, t.id, u.id])
      |> order_by([rl], desc: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))
      |> select([rl, tm, t, u], %{
        team_member_id: tm.id,
        team_name: t.name,
        user_email: u.email,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.cost_usd),
        provider_cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        estimated_cost_usd: fragment("COALESCE(SUM(?), 0)", rl.estimated_cost_usd),
        savings_usd: fragment("COALESCE(SUM(?), 0)", rl.savings_usd),
        prompt_tokens: fragment("COALESCE(SUM(?), 0)", rl.prompt_tokens),
        completion_tokens: fragment("COALESCE(SUM(?), 0)", rl.completion_tokens),
        total_latency_ms: fragment("COALESCE(SUM(?), 0)", rl.latency_ms)
      })

    Repo.all(query)
    |> Enum.map(fn row ->
      %{
        team_member_id: row.team_member_id,
        team_name: row.team_name,
        user_email: row.user_email,
        request_count: row.request_count,
        cost_usd: Decimal.new(to_string(row.cost_usd)),
        provider_cost_usd: Decimal.new(to_string(row.provider_cost_usd)),
        estimated_cost_usd: Decimal.new(to_string(row.estimated_cost_usd)),
        savings_usd: Decimal.new(to_string(row.savings_usd)),
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
        cost_usd: Decimal,
        provider_cost_usd: Decimal,
        estimated_cost_usd: Decimal,
        savings_usd: Decimal,
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
        cost_usd: fragment("COALESCE(SUM(?), 0)", rl.cost_usd),
        provider_cost_usd: fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
        estimated_cost_usd: fragment("COALESCE(SUM(?), 0)", rl.estimated_cost_usd),
        savings_usd: fragment("COALESCE(SUM(?), 0)", rl.savings_usd),
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
        provider_cost_usd: Decimal.new(to_string(row.provider_cost_usd)),
        estimated_cost_usd: Decimal.new(to_string(row.estimated_cost_usd)),
        savings_usd: Decimal.new(to_string(row.savings_usd)),
        prompt_tokens: row.prompt_tokens,
        completion_tokens: row.completion_tokens,
        avg_tps: compute_tps(row.completion_tokens, row.total_latency_ms)
      }
    end)
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
end
