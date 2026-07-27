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

  @doc """
  Per-user spend rollup across all their team memberships.

  Returns `%{user_id => %{daily_usd: Decimal, monthly_usd: Decimal,
  exhausted?: boolean}}` — used by the admin users page.
  """
  @spec spend_by_user() :: %{
          term() => %{
            daily_usd: Decimal.t(),
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
         daily_usd: Enum.reduce(budgets, Decimal.new(0), &Decimal.add(&1.daily_spend_usd, &2)),
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

    daily_pct = pct(spend.daily_usd, limits.daily_budget_usd)
    monthly_pct = pct(spend.monthly_usd, limits.monthly_budget_usd)

    %{
      member: member,
      daily_spend_usd: spend.daily_usd,
      monthly_spend_usd: spend.monthly_usd,
      daily_limit_usd: limits.daily_budget_usd,
      monthly_limit_usd: limits.monthly_budget_usd,
      daily_pct: daily_pct,
      monthly_pct: monthly_pct,
      daily_exhausted?: exhausted?(daily_pct),
      monthly_exhausted?: exhausted?(monthly_pct),
      exhausted?: exhausted?(daily_pct) or exhausted?(monthly_pct)
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
