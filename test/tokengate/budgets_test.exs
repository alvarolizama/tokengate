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
  alias Tokengate.Logs
  alias Tokengate.Periods

  # ---------------------------------------------------------------------------
  # Fixtures — create FK parents via the REAL Accounts context.
  # ---------------------------------------------------------------------------

  defp group_fixture(attrs \\ %{}) do
    {:ok, group} =
      Accounts.create_group(
        Map.merge(
          %{
            "name" => "Group #{System.unique_integer([:positive])}",
            "monthly_budget_per_user_usd" => "100.00"
          },
          attrs
        )
      )

    group
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

  defp member_fixture(group \\ nil, user \\ nil, attrs \\ %{}) do
    group = group || group_fixture()
    user = user || user_fixture()

    {:ok, member} =
      Accounts.create_group_member(
        Map.merge(%{"user_id" => user.id, "group_id" => group.id}, attrs)
      )

    member
  end

  setup do
    pid = Process.whereis(Manager) || start_supervised!(Manager)
    _ = :sys.get_state(pid)
    :ok
  end

  defp log_request(member_id, inserted_at, cost) do
    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member_id,
        model_requested: "gpt-4",
        inserted_at: inserted_at,
        provider_cost_usd: Decimal.new(cost)
      })
  end

  # Simulates a completed request (zero-hold settle) so tests can put spend on
  # the books without going through the full reserve → settle dance.
  defp record(subject_id, cost_usd) do
    Manager.settle(
      subject_id,
      %{monthly_micro: 0, global_micro: 0, exempt_global?: false},
      cost_usd
    )
  end

  describe "member_budget/1" do
    test "reports zero spend with no monthly limit (budget is credit now)" do
      member = member_fixture()

      budget = Budgets.member_budget(member)

      assert Decimal.eq?(budget.monthly_spend_usd, Decimal.new("0"))
      assert is_nil(budget.monthly_limit_usd)
      assert is_nil(budget.monthly_pct)
      refute budget.exhausted?
      refute budget.monthly_exhausted?
    end

    test "reports spend recorded in the ETS counter" do
      member = member_fixture()
      assert :ok = record(member.id, Decimal.new("33.33"))

      budget = Budgets.member_budget(member)

      assert Decimal.eq?(budget.monthly_spend_usd, Decimal.new("33.33"))
      assert is_nil(budget.monthly_limit_usd)
    end
  end

  describe "list_member_budgets/0" do
    test "includes every member with user and group preloaded" do
      member = member_fixture()

      budgets = Budgets.list_member_budgets()
      budget = Enum.find(budgets, &(&1.member.id == member.id))

      assert budget
      assert budget.member.user.email == Accounts.get_user!(member.user_id).email
      assert %Accounts.Group{} = budget.member.group
    end
  end

  describe "list_exhausted_member_budgets/0 and count_exhausted/0" do
    test "only returns members that hit a limit" do
      ok_member = member_fixture()
      broke_member = member_fixture()

      assert :ok = record(ok_member.id, Decimal.new("10.00"))
      assert :ok = record(broke_member.id, Decimal.new("1000.00"))

      exhausted = Budgets.list_exhausted_member_budgets()

      # No monthly limit anymore → nobody is flagged by it (budget is credit).
      assert exhausted == []
      assert Budgets.count_exhausted() == 0
    end
  end

  describe "spend_by_user/0" do
    test "rolls up spend across all memberships of a user" do
      user = user_fixture()
      member_a = member_fixture(nil, user)
      member_b = member_fixture(nil, user)

      assert :ok = record(member_a.id, Decimal.new("10.00"))
      assert :ok = record(member_b.id, Decimal.new("1000.00"))

      spend = Budgets.spend_by_user()
      user_spend = Map.fetch!(spend, user.id)

      assert Decimal.eq?(user_spend.monthly_usd, Decimal.new("1010.00"))
      assert is_nil(user_spend.monthly_limit_usd)
      refute user_spend.exhausted?
    end

    test "users without memberships are absent from the map" do
      user = user_fixture()
      _member = member_fixture()

      spend = Budgets.spend_by_user()
      refute Map.has_key?(spend, user.id)
    end
  end

  describe "list_group_budgets/0" do
    test "agrupa por grupo: sin tope mensual, gasto = suma de spend" do
      group = group_fixture()
      member_a = member_fixture(group)
      member_b = member_fixture(group)
      # Otro grupo que no debe mezclarse
      _other = member_fixture()

      assert :ok = record(member_a.id, Decimal.new("100.00"))
      assert :ok = record(member_b.id, Decimal.new("50.00"))

      groups = Budgets.list_group_budgets()
      row = Enum.find(groups, &(&1.group.id == group.id))

      assert row.member_count == 2
      assert is_nil(row.monthly_limit_usd)
      assert is_nil(row.monthly_pct)
      assert row.has_unlimited?
      # gasto real = 100 + 50
      assert Decimal.eq?(row.monthly_spend_usd, Decimal.new("150.00"))
    end

    test "spot check on group budget values" do
      _member = member_fixture()
      group = group_fixture()
      _member = member_fixture()

      groups = Budgets.list_group_budgets()
      refute Enum.find(groups, &(&1.group.id == group.id))
    end
  end

  describe "timezone-aware local spend" do
    test "spend_by_member_ids usa boundaries locales (America/Mexico_City)" do
      member = member_fixture()
      tz = "America/Mexico_City"
      today_start = Periods.start_of_day_utc(tz)
      month_start = Periods.start_of_month_utc(tz)

      # Ayer local (23:00 del día anterior) → NO cuenta hoy
      log_request(member.id, DateTime.add(today_start, -3600, :second), "1.50")
      # Hoy local (01:00) → cuenta hoy
      log_request(member.id, DateTime.add(today_start, 3600, :second), "2.50")
      # Mes anterior (23:00 del último día del mes anterior) → NO cuenta mes
      log_request(member.id, DateTime.add(month_start, -3600, :second), "8.00")

      spend = Budgets.spend_by_member_ids([member.id], tz)

      assert Decimal.eq?(spend.daily[member.id], Decimal.new("2.50"))

      # El monthly depende de si "ayer local" cayó en el mismo mes (día 1 == borde)
      today = Periods.local_today(tz)
      yesterday_same_month? = Date.add(today, -1).month == today.month

      expected_monthly =
        if yesterday_same_month?,
          do: Decimal.new("4.00"),
          else: Decimal.new("2.50")

      assert Decimal.eq?(spend.monthly[member.id], expected_monthly)
    end

    test "list_member_budgets con timezone lee Postgres local" do
      member = member_fixture()
      tz = "America/Mexico_City"
      today_start = Periods.start_of_day_utc(tz)

      # 23:00 del día anterior local → daily 0, monthly > 0 (mismo mes salvo día 1)
      log_request(member.id, DateTime.add(today_start, -3600, :second), "5.00")

      budgets = Budgets.list_member_budgets(tz)
      budget = Enum.find(budgets, &(&1.member.id == member.id))

      assert Decimal.eq?(budget.daily_spend_usd, Decimal.new("0"))

      # Si "ayer local" es el último día del mes anterior (hoy == día 1), no cuenta en monthly
      today = Periods.local_today(tz)

      expected_monthly =
        if Date.add(today, -1).month == today.month,
          do: Decimal.new("5.00"),
          else: Decimal.new("0")

      assert Decimal.eq?(budget.monthly_spend_usd, expected_monthly)
    end

    test "list_member_budgets_for_user con timezone" do
      group = group_fixture()
      user = user_fixture()
      member = member_fixture(group, user)
      tz = "America/Mexico_City"
      today_start = Periods.start_of_day_utc(tz)

      log_request(member.id, DateTime.add(today_start, 3600, :second), "3.25")

      [budget] = Budgets.list_member_budgets_for_user(user.id, tz)

      assert Decimal.eq?(budget.daily_spend_usd, Decimal.new("3.25"))
      assert Decimal.eq?(budget.monthly_spend_usd, Decimal.new("3.25"))
    end

    test "monthly_spend_for_member / daily_spend_for_member" do
      member = member_fixture()
      tz = "America/Mexico_City"
      today_start = Periods.start_of_day_utc(tz)

      log_request(member.id, DateTime.add(today_start, 3600, :second), "1.00")

      assert Decimal.eq?(Budgets.monthly_spend_for_member(member.id, tz), Decimal.new("1.00"))
      assert Decimal.eq?(Budgets.daily_spend_for_member(member.id, tz), Decimal.new("1.00"))
    end

    test "list_member_budgets(tz) con 0 miembros no revienta" do
      assert Budgets.spend_by_member_ids([], "America/Mexico_City") == %{daily: %{}, monthly: %{}}
    end
  end
end
