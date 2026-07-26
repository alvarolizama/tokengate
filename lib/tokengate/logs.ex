defmodule Tokengate.Logs do
  @moduledoc """
  The Logs context: append-only request log entries.

  This context only **inserts** and **queries** request logs — never updates
  or deletes. The `request_logs` table is a native Postgres RANGE-partitioned
  table on `inserted_at` (daily granularity).

  ## Privacy

  This table **never** stores prompt or completion content — only metadata
  (token counts, costs, latency, status). No PII or request/response bodies
  are persisted here.
  """

  import Ecto.Query, warn: false

  alias Tokengate.Repo
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Accounts.TeamMember

  @default_limit 50
  @max_limit 500

  # ---------------------------------------------------------------------------
  # Insert
  # ---------------------------------------------------------------------------

  @doc """
  Inserts a request log entry. Generates `id` and `inserted_at` (defaults to
  `DateTime.utc_now() |> DateTime.truncate(:second)`) if not provided in attrs.

  Returns `{:ok, request_log}` or `{:error, changeset}`.
  """
  def log_request(attrs) do
    inserted_at =
      Map.get(attrs, :inserted_at) ||
        Map.get(attrs, "inserted_at") ||
        DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      attrs
      |> ensure_atom_key(:inserted_at, inserted_at)

    %RequestLog{}
    |> RequestLog.changeset(attrs)
    |> Repo.insert()
  end

  defp ensure_atom_key(map, key, value) when is_map(map) do
    # Accept both atom and string-keyed maps; normalize to atom key.
    map
    |> Map.delete(to_string(key))
    |> Map.put(key, value)
  end

  # ---------------------------------------------------------------------------
  # Query
  # ---------------------------------------------------------------------------

  @doc """
  Lists request logs with optional filters.

  ## Filters (all optional)
    * `:team_member_id` — exact match
    * `:provider_id` — exact match
    * `:model_alias_id` — exact match
    * `:agent_type` — exact match
    * `:status_code` — exact match
    * `:streaming` — boolean
    * `:from` — `inserted_at >= from` (DateTime)
    * `:to` — `inserted_at <= to` (DateTime)
    * `:limit` — default 50, max 500
  """
  def list_logs(filters \\ %{}) do
    limit = clamp_limit(Map.get(filters, :limit) || Map.get(filters, "limit"))

    RequestLog
    |> apply_log_filters(filters)
    |> order_by([rl], desc: rl.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Lists request logs for a specific team, joining through `team_members`.

  Filters are the same as `list_logs/1`.
  """
  def list_logs_for_team(team_id, filters \\ %{}) do
    limit = clamp_limit(Map.get(filters, :limit) || Map.get(filters, "limit"))

    RequestLog
    |> join(:inner, [rl], tm in TeamMember, on: rl.team_member_id == tm.id)
    |> where([rl, tm], tm.team_id == ^team_id)
    |> apply_log_filters(filters)
    |> order_by([rl], desc: rl.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp apply_log_filters(query, filters) do
    query
    |> maybe_where(:team_member_id, filters)
    |> maybe_where(:provider_id, filters)
    |> maybe_where(:model_alias_id, filters)
    |> maybe_where(:agent_type, filters)
    |> maybe_where(:status_code, filters)
    |> maybe_where(:streaming, filters)
    |> maybe_from(filters)
    |> maybe_to(filters)
  end

  defp maybe_where(query, field, filters) do
    value = Map.get(filters, field) || Map.get(filters, to_string(field))

    if is_nil(value), do: query, else: where(query, [rl], field(rl, ^field) == ^value)
  end

  defp maybe_from(query, filters) do
    case Map.get(filters, :from) || Map.get(filters, "from") do
      nil -> query
      from -> where(query, [rl], rl.inserted_at >= ^from)
    end
  end

  defp maybe_to(query, filters) do
    case Map.get(filters, :to) || Map.get(filters, "to") do
      nil -> query
      to -> where(query, [rl], rl.inserted_at <= ^to)
    end
  end

  defp clamp_limit(nil), do: @default_limit
  defp clamp_limit(limit) when is_integer(limit) and limit > 0 do
    min(limit, @max_limit)
  end

  defp clamp_limit(_), do: @default_limit

  # ---------------------------------------------------------------------------
  # Aggregates
  # ---------------------------------------------------------------------------

  @doc """
  Computes a cost summary over request logs matching the given filters.

  Returns a map with:
    * `:total_cost_usd`
    * `:total_provider_cost_usd`
    * `:total_savings_usd`
    * `:total_estimated_cost_usd`
    * `:total_prompt_tokens`
    * `:total_completion_tokens`
    * `:request_count`

  All sums are Decimal-safe (use `COALESCE` + `SUM` in SQL). Token sums
  default to 0 when no rows match.
  """
  def cost_summary(filters \\ %{}) do
    result =
      RequestLog
      |> apply_log_filters(filters)
      |> select([rl], %{
        total_cost_usd: fragment("COALESCE(SUM(cost_usd), 0)"),
        total_provider_cost_usd: fragment("COALESCE(SUM(provider_cost_usd), 0)"),
        total_savings_usd: fragment("COALESCE(SUM(savings_usd), 0)"),
        total_estimated_cost_usd: fragment("COALESCE(SUM(estimated_cost_usd), 0)"),
        total_prompt_tokens: coalesce(sum(rl.prompt_tokens), 0),
        total_completion_tokens: coalesce(sum(rl.completion_tokens), 0),
        request_count: count(rl.id)
      })
      |> Repo.one()

    %{
      total_cost_usd: Decimal.new(to_string(result.total_cost_usd)),
      total_provider_cost_usd: Decimal.new(to_string(result.total_provider_cost_usd)),
      total_savings_usd: Decimal.new(to_string(result.total_savings_usd)),
      total_estimated_cost_usd: Decimal.new(to_string(result.total_estimated_cost_usd)),
      total_prompt_tokens: result.total_prompt_tokens,
      total_completion_tokens: result.total_completion_tokens,
      request_count: result.request_count
    }
  end
end
