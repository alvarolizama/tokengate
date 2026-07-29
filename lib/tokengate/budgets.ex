defmodule Tokengate.Budgets do
  @moduledoc """
  Budget visibility: per-member spend vs effective limits.

  The enforcement hot path lives in `Tokengate.Budgets.Manager` (ETS
  counters). This context is the read side for dashboards: it combines
  `Tokengate.Accounts.effective_limits/1` with the manager's spend
  counters into a single `member_budget` map per team member.

  A member is **exhausted** when their daily or monthly spend reached the
  effective limit — the proxy already rejects their requests with 402.
  """

  import Ecto.Query

  alias Tokengate.{Accounts, Repo}
  alias Tokengate.Accounts.TeamMember
  alias Tokengate.Budgets.Manager

  @type member_budget :: %{
          member: TeamMember.t(),
          daily_spend_usd: Decimal.t(),
          monthly_spend_usd: Decimal.t(),
          daily_limit_usd: Decimal.t() | nil,
          monthly_limit_usd: Decimal.t() | nil,
          daily_pct: float() | nil,
          monthly_pct: float() | nil,
          daily_exhausted?: boolean(),
          monthly_exhausted?: boolean(),
          exhausted?: boolean()
        }

  @doc """
  Lists a `member_budget` map for every team member (user and team
  preloaded on `:member`), ordered by most recently created first.
  """
  @spec list_member_budgets() :: [member_budget()]
  def list_member_budgets do
    TeamMember
    |> preload([:user, :team])
    |> order_by([tm], desc: tm.inserted_at)
    |> Repo.all()
    |> Enum.map(&member_budget/1)
  end

  @doc "Lists only the member budgets that hit a daily or monthly limit."
  @spec list_exhausted_member_budgets() :: [member_budget()]
  def list_exhausted_member_budgets do
    list_member_budgets() |> Enum.filter(& &1.exhausted?)
  end

  @doc "Number of members currently blocked by a budget limit."
  @spec count_exhausted() :: non_neg_integer()
  def count_exhausted do
    list_exhausted_member_budgets() |> length()
  end

  @typedoc """
  Team-level budget rollup: the daily cap is the SUM of each member's
  effective daily limit (tope diario × miembros), and the spend is the
  SUM of each member's daily spend (real). Members without a daily
  limit don't add to the cap and set `has_unlimited?`.
  """
  @type team_budget :: %{
          team: Tokengate.Accounts.Team.t(),
          member_count: non_neg_integer(),
          daily_limit_usd: Decimal.t() | nil,
          daily_spend_usd: Decimal.t(),
          daily_pct: float() | nil,
          has_unlimited?: boolean()
        }

  @doc """
  Rolls `list_member_budgets/0` up to the team level. Teams without
  members don't appear. Ordered by highest monthly spend first.
  """
  @spec list_team_budgets() :: [team_budget()]
  def list_team_budgets do
    list_member_budgets()
    |> Enum.group_by(fn mb -> mb.member.team_id end)
    |> Enum.map(fn {_team_id, budgets} ->
      limits = Enum.map(budgets, & &1.monthly_limit_usd)

      monthly_limit_usd =
        if Enum.all?(limits, &is_nil/1) do
          nil
        else
          limits |> Enum.reject(&is_nil/1) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
        end

      monthly_spend_usd =
        Enum.reduce(budgets, Decimal.new(0), &Decimal.add(&1.monthly_spend_usd, &2))

      %{
        team: hd(budgets).member.team,
        member_count: length(budgets),
        monthly_limit_usd: monthly_limit_usd,
        monthly_spend_usd: monthly_spend_usd,
        monthly_pct: pct(monthly_spend_usd, monthly_limit_usd),
        has_unlimited?: Enum.any?(limits, &is_nil/1)
      }
    end)
    |> Enum.sort_by(fn row -> Decimal.to_float(row.monthly_spend_usd) end, :desc)
  end

  @doc """
  Lists `member_budget` maps for every team membership of a single user —
  the per-user read behind the personal topbar chip (each user sees only
  their own data). Ordered by most recently created first.
  """
  @spec list_member_budgets_for_user(term()) :: [member_budget()]
  def list_member_budgets_for_user(user_id) do
    TeamMember
    |> where([tm], tm.user_id == ^user_id)
    |> preload([:user, :team])
    |> order_by([tm], desc: tm.inserted_at)
    |> Repo.all()
    |> Enum.map(&member_budget/1)
  end

  @doc """
  Per-user spend rollup across all their team memberships.

  Returns `%{user_id => %{daily_usd: Decimal, monthly_usd: Decimal,
  exhausted?: boolean}}` — used by the admin users page.
  """
  @spec spend_by_user() :: %{
          term() => %{
            monthly_usd: Decimal.t(),
            exhausted?: boolean()
          }
        }
  def spend_by_user do
    list_member_budgets()
    |> Enum.group_by(fn mb -> mb.member.user_id end)
    |> Map.new(fn {user_id, budgets} ->
      {user_id,
       %{
         monthly_usd:
           Enum.reduce(budgets, Decimal.new(0), &Decimal.add(&1.monthly_spend_usd, &2)),
         exhausted?: Enum.any?(budgets, & &1.exhausted?)
       }}
    end)
  end

  @doc "Builds the budget status map for a single team member."
  @spec member_budget(TeamMember.t()) :: member_budget()
  def member_budget(%TeamMember{} = member) do
    limits = Accounts.effective_limits(member)
    spend = Manager.spend(member.id)

    monthly_pct = pct(spend.monthly_usd, limits.monthly_budget_usd)

    %{
      member: member,
      daily_spend_usd: spend.daily_usd,
      monthly_spend_usd: spend.monthly_usd,
      daily_limit_usd: nil,
      monthly_limit_usd: limits.monthly_budget_usd,
      daily_pct: nil,
      monthly_pct: monthly_pct,
      daily_exhausted?: false,
      monthly_exhausted?: exhausted?(monthly_pct),
      exhausted?: exhausted?(monthly_pct)
    }
  end

  # Percentage of the limit consumed. `nil` limit = unlimited (no bar).
  # A zero (or negative) limit blocks every request, so it reads as 100%.
  defp pct(_spend, nil), do: nil

  defp pct(spend, limit) do
    if Decimal.compare(limit, Decimal.new(0)) == :gt do
      spend
      |> Decimal.div(limit)
      |> Decimal.mult(Decimal.new(100))
      |> Decimal.to_float()
      |> Float.round(1)
    else
      100.0
    end
  end

  defp exhausted?(nil), do: false
  defp exhausted?(pct), do: pct >= 100.0
end
