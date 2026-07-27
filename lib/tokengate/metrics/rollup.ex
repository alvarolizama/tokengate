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
        model_provider_id: row.model_provider_id,
        provider_name: row.provider_name || "—",
        provider_model: row.provider_model,
        credential_name: row.credential_name,
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

  defp score_ranking_row(row, min_latency) do
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

    %{
      provider_id: row.provider_id,
      provider_name: row.provider_name,
      request_count: row.request_count,
      error_count: row.error_count,
      error_rate: Float.round(error_rate, 4),
      avg_latency_ms: avg_latency && round(avg_latency),
      p95_latency_ms: row.p95_latency_ms && round(to_float!(row.p95_latency_ms)),
      avg_ttft_ms: row.avg_ttft_ms && round(to_float!(row.avg_ttft_ms)),
      score: score,
      tier: tier
    }
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
