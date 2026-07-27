defmodule Tokengate.BudgetsTest do
  @moduledoc """
  Tests for Tokengate.Budgets — the read side that combines effective
  limits with the manager's spend counters into member_budget maps.

  `async: false` because the ETS table `:tokengate_budgets` is a named
  (singleton) table; concurrent tests would clobber each other's counters.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.{Accounts, Budgets}
  alias Tokengate.Budgets.Manager

  # ---------------------------------------------------------------------------
  # Fixtures — create FK parents via the REAL Accounts context.
  # ---------------------------------------------------------------------------

  defp team_fixture(attrs \\ %{}) do
    {:ok, team} =
      Accounts.create_team(
        Map.merge(
          %{
            "name" => "Team #{System.unique_integer([:positive])}",
            "default_daily_budget_usd" => "100.00",
            "default_monthly_budget_usd" => "1000.00"
          },
          attrs
        )
      )

    team
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "user#{System.unique_integer([:positive])}@example.com",
        "name" => "Test User",
        "password" => "ValidPassword123"
      })

    user
  end

  defp member_fixture(team \\ nil, user \\ nil, attrs \\ %{}) do
    team = team || team_fixture()
    user = user || user_fixture()

    {:ok, member} =
      Accounts.create_team_member(Map.merge(%{"user_id" => user.id, "team_id" => team.id}, attrs))

    member
  end

  setup do
    pid = Process.whereis(Manager) || start_supervised!(Manager)
    _ = :sys.get_state(pid)
    :ok
  end

  describe "member_budget/1" do
    test "combines effective limits with zero spend" do
      member = member_fixture()

      budget = Budgets.member_budget(member)

      assert Decimal.eq?(budget.daily_spend_usd, Decimal.new("0"))
      assert Decimal.eq?(budget.monthly_spend_usd, Decimal.new("0"))
      assert Decimal.eq?(budget.daily_limit_usd, Decimal.new("100.00"))
      assert Decimal.eq?(budget.monthly_limit_usd, Decimal.new("1000.00"))
      assert budget.daily_pct == 0.0
      assert budget.monthly_pct == 0.0
      refute budget.exhausted?
      refute budget.daily_exhausted?
      refute budget.monthly_exhausted?
    end

    test "member extra stacks on team default" do
      member = member_fixture(nil, nil, %{"extra_daily_budget_usd" => "50.00"})

      budget = Budgets.member_budget(member)

      assert Decimal.eq?(budget.daily_limit_usd, Decimal.new("150.00"))
    end

    test "unlimited periods report nil pct and never exhaust" do
      team = team_fixture(%{"default_daily_budget_usd" => nil})
      member = member_fixture(team)

      budget = Budgets.member_budget(member)

      assert is_nil(budget.daily_limit_usd)
      assert is_nil(budget.daily_pct)
      refute budget.daily_exhausted?
    end

    test "spend at the limit is exhausted" do
      member = member_fixture()
      assert :ok = Manager.record_spend(member.id, Decimal.new("100.00"))

      budget = Budgets.member_budget(member)

      assert budget.daily_pct == 100.0
      assert budget.daily_exhausted?
      assert budget.exhausted?
      refute budget.monthly_exhausted?
    end

    test "spend above the limit is exhausted" do
      member = member_fixture()
      assert :ok = Manager.record_spend(member.id, Decimal.new("250.00"))

      budget = Budgets.member_budget(member)

      assert budget.daily_pct == 250.0
      assert budget.exhausted?
    end

    test "zero limit exhausts immediately" do
      team = team_fixture(%{"default_daily_budget_usd" => "0"})
      member = member_fixture(team)

      budget = Budgets.member_budget(member)

      assert budget.daily_pct == 100.0
      assert budget.daily_exhausted?
    end

    test "pct is rounded to one decimal" do
      member = member_fixture()
      assert :ok = Manager.record_spend(member.id, Decimal.new("33.33"))

      budget = Budgets.member_budget(member)

      assert budget.daily_pct == 33.3
    end
  end

  describe "list_member_budgets/0" do
    test "includes every member with user and team preloaded" do
      member = member_fixture()

      budgets = Budgets.list_member_budgets()
      budget = Enum.find(budgets, &(&1.member.id == member.id))

      assert budget
      assert budget.member.user.email == Accounts.get_user!(member.user_id).email
      assert %Accounts.Team{} = budget.member.team
    end
  end

  describe "list_exhausted_member_budgets/0 and count_exhausted/0" do
    test "only returns members that hit a limit" do
      ok_member = member_fixture()
      broke_member = member_fixture()

      assert :ok = Manager.record_spend(ok_member.id, Decimal.new("10.00"))
      assert :ok = Manager.record_spend(broke_member.id, Decimal.new("1000.00"))

      exhausted = Budgets.list_exhausted_member_budgets()
      ids = Enum.map(exhausted, & &1.member.id)

      assert broke_member.id in ids
      refute ok_member.id in ids
      assert Budgets.count_exhausted() == length(exhausted)
    end
  end

  describe "spend_by_user/0" do
    test "rolls up spend across all memberships of a user" do
      user = user_fixture()
      member_a = member_fixture(nil, user)
      member_b = member_fixture(nil, user)

      assert :ok = Manager.record_spend(member_a.id, Decimal.new("10.00"))
      assert :ok = Manager.record_spend(member_b.id, Decimal.new("1000.00"))

      spend = Budgets.spend_by_user()
      user_spend = Map.fetch!(spend, user.id)

      # member_a: $10/day, $10/month. member_b: $1000/day (daily cap is $100
      # but record_spend doesn't enforce), so daily = 1010, monthly = 1010.
      assert Decimal.eq?(user_spend.daily_usd, Decimal.new("1010.00"))
      assert Decimal.eq?(user_spend.monthly_usd, Decimal.new("1010.00"))
      # member_b exhausted both limits -> the user is flagged
      assert user_spend.exhausted?
    end

    test "users without memberships are absent from the map" do
      user = user_fixture()
      _member = member_fixture()

      spend = Budgets.spend_by_user()

      refute Map.has_key?(spend, user.id)
    end
  end
end
