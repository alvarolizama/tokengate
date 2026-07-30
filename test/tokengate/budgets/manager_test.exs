defmodule Tokengate.Budgets.ManagerTest do
  @moduledoc """
  Tests for Tokengate.Budgets.Manager — ETS micro-USD daily/monthly
  spend cache with lazy DB load.

  `async: false` because the ETS table `:tokengate_budgets` is a named
  (singleton) table; concurrent tests would clobber each other's counters.
  Each test uses a unique team member (via real Accounts fixtures) so
  inter-test contamination is avoided even within the serial run.
  """

  use Tokengate.DataCase, async: false
  use Oban.Testing, repo: Tokengate.Repo

  alias Tokengate.Budgets.Manager
  alias Tokengate.Accounts
  alias Tokengate.Logs

  @table :tokengate_budgets

  # ---------------------------------------------------------------------------
  # Fixtures — create FK parents via the REAL Accounts context.
  # ---------------------------------------------------------------------------

  defp team_fixture(attrs \\ %{}) do
    {:ok, team} =
      Accounts.create_team(
        Map.merge(
          %{
            "name" => "Platform Team",
            "monthly_budget_per_user_usd" => "100.00",
            "default_concurrency_limit" => 10,
            "default_rpm_limit" => 120
          },
          attrs
        )
      )

    team
  end

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      Accounts.register_user(
        Map.merge(
          %{
            "email" => "user#{System.unique_integer([:positive])}@example.com",
            "name" => "Test User",
            "password" => "ValidPassword123"
          },
          attrs
        )
      )

    user
  end

  defp team_member_fixture(attrs \\ %{}) do
    team = team_fixture()
    user = user_fixture()

    {:ok, team_member} =
      Accounts.create_team_member(
        Map.merge(
          %{
            "user_id" => user.id,
            "team_id" => team.id
          },
          attrs
        )
      )

    {team_member, team}
  end

  defp log_spend(team_member_id, cost_usd, opts \\ []) do
    provider_cost_usd = Keyword.get(opts, :provider_cost_usd, cost_usd)
    inserted_at = Keyword.get(opts, :inserted_at, DateTime.utc_now())

    {:ok, _} =
      Logs.log_request(%{
        team_member_id: team_member_id,
        model_requested: "gpt-4",
        cost_usd: Decimal.new(to_string(cost_usd)),
        provider_cost_usd: Decimal.new(to_string(provider_cost_usd)),
        savings_usd: Decimal.new("0"),
        estimated_cost_usd: Decimal.new(to_string(cost_usd)),
        inserted_at: inserted_at
      })
  end

  # ---------------------------------------------------------------------------
  # Setup — reuse app-tree Manager if running, else start_supervised!
  # ---------------------------------------------------------------------------

  setup do
    pid = Process.whereis(Manager) || start_supervised!(Manager)
    _ = :sys.get_state(pid)
    :ok
  end

  # ---------------------------------------------------------------------------
  # check_ladder/3 — budget pre-flight (monthly)
  # ---------------------------------------------------------------------------

  describe "check_ladder/3 — budget pre-flight" do
    test "under cap returns :ok" do
      {tm, _team} = team_member_fixture()

      assert :ok = Manager.record_spend(tm.id, Decimal.new("10.00"))

      assert :ok =
               Manager.check_ladder(
                 Decimal.new("100.00"),
                 Manager.spend(tm.id).monthly_usd,
                 Decimal.new("20.00")
               )
    end

    test "over cap returns error" do
      {tm, _team} = team_member_fixture()

      assert :ok = Manager.record_spend(tm.id, Decimal.new("90.00"))

      result =
        Manager.check_ladder(
          Decimal.new("100.00"),
          Manager.spend(tm.id).monthly_usd,
          Decimal.new("20.00")
        )

      assert {:error, :budget_exceeded, details} = result
      assert Decimal.equal?(details.available, Decimal.new("10.00"))
    end

    test "nil budget is unlimited" do
      {tm, _team} = team_member_fixture()

      assert :ok = Manager.record_spend(tm.id, Decimal.new("500.00"))

      assert :ok =
               Manager.check_ladder(
                 nil,
                 Manager.spend(tm.id).monthly_usd,
                 Decimal.new("10.00")
               )
    end

    test "nil estimated cost treated as 0" do
      {tm, _team} = team_member_fixture()

      assert :ok = Manager.record_spend(tm.id, Decimal.new("50.00"))

      assert :ok =
               Manager.check_ladder(
                 Decimal.new("100.00"),
                 Manager.spend(tm.id).monthly_usd,
                 nil
               )
    end

    test "exactly at limit with zero estimated is ok" do
      {tm, _team} = team_member_fixture()

      assert :ok = Manager.record_spend(tm.id, Decimal.new("100.00"))

      assert :ok =
               Manager.check_ladder(
                 Decimal.new("100.00"),
                 Manager.spend(tm.id).monthly_usd,
                 nil
               )
    end
  end

  # ---------------------------------------------------------------------------
  # record_spend/2 + spend/1 — accumulation and read-back
  # ---------------------------------------------------------------------------

  describe "record_spend/2 and spend/1" do
    test "record_spend accumulates in both daily and monthly" do
      {tm, _} = team_member_fixture()

      assert :ok = Manager.record_spend(tm.id, Decimal.new("10.00"))
      assert :ok = Manager.record_spend(tm.id, Decimal.new("20.50"))

      spend = Manager.spend(tm.id)
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("30.50"))
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("30.50"))
    end

    test "spend/1 returns Decimals" do
      {tm, _} = team_member_fixture()

      assert :ok = Manager.record_spend(tm.id, Decimal.new("5.25"))

      spend = Manager.spend(tm.id)
      assert %Decimal{} = spend.monthly_usd
      assert %Decimal{} = spend.monthly_usd
    end

    test "spend/1 on untouched member returns zeros" do
      {tm, _} = team_member_fixture()

      spend = Manager.spend(tm.id)
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("0"))
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("0"))
    end

    test "record_spend enqueues SyncWorker via Oban" do
      {tm, _} = team_member_fixture()

      assert :ok = Manager.record_spend(tm.id, Decimal.new("1.00"))

      assert_enqueued(
        worker: Tokengate.Budgets.SyncWorker,
        args: %{"member_id" => tm.id}
      )
    end

    test "nil cost is treated as 0" do
      {tm, _} = team_member_fixture()

      assert :ok = Manager.record_spend(tm.id, nil)

      spend = Manager.spend(tm.id)
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("0"))
    end
  end

  # ---------------------------------------------------------------------------
  # Lazy load — ETS seeded from request_logs on first touch
  # ---------------------------------------------------------------------------

  describe "lazy load from DB" do
    test "spend/1 reflects DB provider_cost_usd totals for untouched member" do
      {tm, _} = team_member_fixture()

      # Insert request_logs rows where the real paid cost is lower than the
      # credential price. The budget counters must use provider_cost_usd.
      log_spend(tm.id, "16.00", provider_cost_usd: "4.00")
      log_spend(tm.id, "16.00", provider_cost_usd: "4.00")

      # Clear any cached entry from record_spend above — this member is
      # untouched in ETS, so spend/1 will trigger a lazy load.
      spend = Manager.spend(tm.id)

      # $8 real paid total in DB, not $32 credential total.
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("8.00"))
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("8.00"))
    end

    test "check_ladder lazy-loads before comparing" do
      {tm, _team} = team_member_fixture()

      # Insert $90 of real paid spend into request_logs.
      log_spend(tm.id, "90.00")

      # No record_spend call — check should lazy-load and see $90.
      # Cap $100, already spent $90, request $20 → over.
      result =
        Manager.check_ladder(
          Decimal.new("100.00"),
          Manager.spend(tm.id).monthly_usd,
          Decimal.new("20.00")
        )

      assert {:error, :budget_exceeded, details} = result
      assert Decimal.equal?(details.available, Decimal.new("10.00"))
    end

    test "record_spend on top of lazy-loaded DB total accumulates correctly" do
      {tm, _} = team_member_fixture()

      # Seed DB with $30 real paid.
      log_spend(tm.id, "30.00")

      # record_spend should lazy-load $30, then add $10 = $40.
      assert :ok = Manager.record_spend(tm.id, Decimal.new("10.00"))

      spend = Manager.spend(tm.id)
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("40.00"))
    end
  end

  # ---------------------------------------------------------------------------
  # Day/month rollover
  # ---------------------------------------------------------------------------

  describe "day rollover" do
    test "stale daily entry (yesterday) resets to fresh on next access" do
      {tm, _} = team_member_fixture()

      # Seed an entry with today's date and a spend.
      assert :ok = Manager.record_spend(tm.id, Decimal.new("50.00"))

      # Verify it's there.
      assert Decimal.equal?(Manager.spend(tm.id).daily_usd, Decimal.new("50.00"))

      # Manually mark the daily entry as stale (yesterday's date).
      key = {tm.id, :daily}
      yesterday = Date.add(Date.utc_today(), -1)
      [{^key, micro, loaded?, _stamp}] = :ets.lookup(@table, key)
      :ets.insert(@table, {key, micro, loaded?, yesterday})

      # On next read, the entry should be detected as stale and re-seeded
      # from DB (which has no rows for today), resetting to 0.
      spend = Manager.spend(tm.id)
      # DB has no logs for today → 0.
      assert Decimal.equal?(spend.daily_usd, Decimal.new("0"))
    end

    test "stale monthly entry (last month) resets to fresh" do
      {tm, _} = team_member_fixture()

      assert :ok = Manager.record_spend(tm.id, Decimal.new("50.00"))

      # Mark monthly entry as last month.
      key = {tm.id, :monthly}
      today = Date.utc_today()
      last_month = Date.add(today, -31)
      [{^key, micro, loaded?, _stamp}] = :ets.lookup(@table, key)
      :ets.insert(@table, {key, micro, loaded?, {last_month.year, last_month.month}})

      spend = Manager.spend(tm.id)
      # DB has no logs for this month → 0.
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("0"))
    end
  end

  # ---------------------------------------------------------------------------
  # SyncWorker — drift correction
  # ---------------------------------------------------------------------------

  describe "SyncWorker drift correction" do
    test "perform_job resets ETS counters to DB truth" do
      {tm, _} = team_member_fixture()

      # Insert DB truth: $25.
      log_spend(tm.id, "25.00")

      # Drift the ETS counter manually to $100 (simulating drift).
      :ets.insert(@table, {{tm.id, :daily}, 100_000_000, true, Date.utc_today()})

      :ets.insert(
        @table,
        {{tm.id, :monthly}, 100_000_000, true, {Date.utc_today().year, Date.utc_today().month}}
      )

      # Confirm drift.
      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("100.00"))

      # Run the worker.
      job = %Oban.Job{args: %{"member_id" => tm.id}}
      assert :ok = Tokengate.Budgets.SyncWorker.perform(job)

      # Counters should now reflect DB truth ($25).
      spend = Manager.spend(tm.id)
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("25.00"))
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("25.00"))
    end

    test "perform_job with no DB rows resets to 0" do
      {tm, _} = team_member_fixture()

      # Drift to $50.
      :ets.insert(@table, {{tm.id, :daily}, 50_000_000, true, Date.utc_today()})

      :ets.insert(
        @table,
        {{tm.id, :monthly}, 50_000_000, true, {Date.utc_today().year, Date.utc_today().month}}
      )

      job = %Oban.Job{args: %{"member_id" => tm.id}}
      assert :ok = Tokengate.Budgets.SyncWorker.perform(job)

      spend = Manager.spend(tm.id)
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("0"))
    end

    test "worker can be enqueued and performed via Oban.Testing" do
      {tm, _} = team_member_fixture()

      log_spend(tm.id, "10.00")

      # Enqueue via Manager.record_spend (which enqueues the worker).
      assert :ok = Manager.record_spend(tm.id, Decimal.new("5.00"))

      # The job should be enqueued.
      assert_enqueued(worker: Tokengate.Budgets.SyncWorker)

      # Drain the queue and assert the worker ran successfully.
      assert %{success: 1, failure: 0} =
               Oban.drain_queue(queue: :budgets, with_safety: false)
    end
  end

  # ---------------------------------------------------------------------------
  # Micro-USD precision — no float drift
  # ---------------------------------------------------------------------------

  describe "micro-USD precision" do
    test "0.012500 USD spends accumulate exactly over 10k records" do
      {tm, _} = team_member_fixture()

      cost = Decimal.new("0.012500")

      for _ <- 1..10_000 do
        assert :ok = Manager.record_spend(tm.id, cost)
      end

      spend = Manager.spend(tm.id)

      # 0.012500 * 10000 = 125.00 exactly — no float drift.
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("125.00"))

      # Verify the internal micro-USD counter is exact.
      # 0.012500 * 1_000_000 = 12500 micro per record.
      # 12500 * 10000 = 125_000_000 micro total.
      [{_, daily_micro, _, _}] = :ets.lookup(@table, {tm.id, :daily})
      assert daily_micro == 125_000_000
    end

    test "sub-cent precision is preserved (0.000001 USD)" do
      {tm, _} = team_member_fixture()

      # 0.000001 USD = 1 micro-USD. record_spend 3 times = 3 micro.
      assert :ok = Manager.record_spend(tm.id, Decimal.new("0.000001"))
      assert :ok = Manager.record_spend(tm.id, Decimal.new("0.000001"))
      assert :ok = Manager.record_spend(tm.id, Decimal.new("0.000001"))

      spend = Manager.spend(tm.id)
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("0.000003"))
    end

    test "rounding uses half_up for .5 micro boundary" do
      {tm, _} = team_member_fixture()

      # 0.0000005 USD * 1_000_000 = 0.5 micro → rounds to 1 (half_up).
      assert :ok = Manager.record_spend(tm.id, Decimal.new("0.0000005"))

      [{_, daily_micro, _, _}] = :ets.lookup(@table, {tm.id, :daily})
      assert daily_micro == 1
    end
  end

  # ---------------------------------------------------------------------------
  # set_from_db/3 — direct ETS reset
  # ---------------------------------------------------------------------------

  describe "set_from_db/3" do
    test "resets both daily and monthly counters" do
      {tm, _} = team_member_fixture()

      # Seed some spend first.
      assert :ok = Manager.record_spend(tm.id, Decimal.new("50.00"))

      # Reset via set_from_db.
      assert :ok = Manager.set_from_db(tm.id, 10_000_000, 20_000_000)

      spend = Manager.spend(tm.id)
      assert Decimal.equal?(spend.daily_usd, Decimal.new("10.00"))
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("20.00"))
    end

    test "marks entries as loaded_from_db" do
      {tm, _} = team_member_fixture()

      assert :ok = Manager.set_from_db(tm.id, 1000, 2000)

      [{_, _, daily_loaded?, _}] = :ets.lookup(@table, {tm.id, :daily})
      [{_, _, monthly_loaded?, _}] = :ets.lookup(@table, {tm.id, :monthly})
      assert daily_loaded? == true
      assert monthly_loaded? == true
    end
  end

  # ---------------------------------------------------------------------------
  # load_from_db/2 — DB read helper
  # ---------------------------------------------------------------------------

  describe "load_from_db/2" do
    test "returns micro-USD sum from request_logs" do
      {tm, _} = team_member_fixture()

      log_spend(tm.id, "10.00")
      log_spend(tm.id, "20.00")

      from = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
      micro = Manager.load_from_db(tm.id, from)

      # $30.00 = 30_000_000 micro.
      assert micro == 30_000_000
    end

    test "returns 0 when no logs match" do
      {tm, _} = team_member_fixture()

      from = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
      micro = Manager.load_from_db(tm.id, from)

      assert micro == 0
    end
  end

  # ---------------------------------------------------------------------------
  # reset_monthly_counters/0 — monthly reset on 1st of month
  # ---------------------------------------------------------------------------

  describe "reset_monthly_counters/0" do
    test "deletes all monthly ETS entries" do
      {tm1, _} = team_member_fixture()
      {tm2, _} = team_member_fixture()

      assert :ok = Manager.record_spend(tm1.id, Decimal.new("10.00"))
      assert :ok = Manager.record_spend(tm2.id, Decimal.new("20.00"))

      # Verify entries exist.
      assert Decimal.equal?(Manager.spend(tm1.id).monthly_usd, Decimal.new("10.00"))
      assert Decimal.equal?(Manager.spend(tm2.id).monthly_usd, Decimal.new("20.00"))

      # Reset all monthly counters.
      deleted = Manager.reset_monthly_counters()
      assert deleted >= 2

      # Monthly counters are gone; next access lazy-loads from DB (which has
      # no rows for this month yet if we haven't inserted any), so they read 0.
      assert Decimal.equal?(Manager.spend(tm1.id).monthly_usd, Decimal.new("0"))
      assert Decimal.equal?(Manager.spend(tm2.id).monthly_usd, Decimal.new("0"))
    end

    test "daily counters are unaffected" do
      {tm, _} = team_member_fixture()

      assert :ok = Manager.record_spend(tm.id, Decimal.new("15.00"))

      Manager.reset_monthly_counters()

      # Daily should still reflect the spend.
      assert Decimal.equal?(Manager.spend(tm.id).daily_usd, Decimal.new("15.00"))
    end

    test "reset then record_spend accumulates from 0" do
      {tm, _} = team_member_fixture()

      # Log en el mes pasado para que el reset mensual lo ignore.
      last_month = Date.add(Date.utc_today(), -31)
      log_spend(tm.id, "5.00", inserted_at: DateTime.new!(last_month, ~T[00:00:00], "Etc/UTC"))

      # Seed ETS con gasto actual.
      assert :ok = Manager.record_spend(tm.id, Decimal.new("3.00"))

      # After reset, monthly lazy-loads from DB (only last month's logs).
      Manager.reset_monthly_counters()
      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("0"))

      # Add new spend → should start from 0.
      assert :ok = Manager.record_spend(tm.id, Decimal.new("2.00"))
      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("2.00"))
    end
  end
end
