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
  """

  import Ecto.Query, warn: false

  alias Tokengate.Logs.RequestLog
  alias Tokengate.Accounts.TeamMember
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
        cost_usd: fragment("COALESCE(SUM(cost_usd), 0)"),
        savings_usd: fragment("COALESCE(SUM(savings_usd), 0)")
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
      |> order_by([rl], desc: fragment("COALESCE(SUM(cost_usd), 0)"))
      |> limit(^limit)
      |> select([rl], %{
        team_member_id: rl.team_member_id,
        request_count: count(rl.id),
        cost_usd: fragment("COALESCE(SUM(cost_usd), 0)")
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
        cost_usd: fragment("COALESCE(SUM(cost_usd), 0)")
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
        cost_usd: fragment("COALESCE(SUM(cost_usd), 0)")
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
  # Internals
  # -----------------------------------------------------------------------

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
