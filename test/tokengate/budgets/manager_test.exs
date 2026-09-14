defmodule Tokengate.Budgets.ManagerTest do
  @moduledoc """
  Tests for Tokengate.Budgets.Manager — the ETS micro-USD spend cache with the
  two budget layers (monthly per subject + global daily kill-switch) enforced
  through a reserve → settle primitive, with lazy DB load.

  `async: false` because the ETS table `:tokengate_budgets` is a named
  (singleton) table; concurrent tests would clobber each other's counters.
  Each test uses a unique group member (via real Accounts fixtures) so
  inter-test contamination is avoided even within the serial run.
  """

  use Tokengate.DataCase, async: false
  use Oban.Testing, repo: Tokengate.Repo
  alias Tokengate.Budgets.Manager
  alias Tokengate.Accounts
  alias Tokengate.Budgets.Exemptions
  alias Tokengate.Logs

  @table :tokengate_budgets

  # ---------------------------------------------------------------------------
  # Fixtures — create FK parents via the REAL Accounts context.
  # ---------------------------------------------------------------------------

  defp group_fixture(attrs \\ %{}) do
    {:ok, group} =
      Accounts.create_group(
        Map.merge(
          %{
            "name" => "Platform Group",
            "monthly_budget_per_user_usd" => "100.00",
            "default_concurrency_limit" => 10,
            "default_rpm_limit" => 120
          },
          attrs
        )
      )

    group
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

  defp group_member_fixture(attrs \\ %{}) do
    group = group_fixture()
    user = user_fixture()

    {:ok, group_member} =
      Accounts.create_group_member(
        Map.merge(
          %{
            "user_id" => user.id,
            "group_id" => group.id
          },
          attrs
        )
      )

    {group_member, group}
  end

  defp log_spend(group_member_id, cost_usd, opts \\ []) do
    provider_cost_usd = Keyword.get(opts, :provider_cost_usd, cost_usd)
    inserted_at = Keyword.get(opts, :inserted_at, DateTime.utc_now())

    {:ok, _} =
      Logs.log_request(%{
        group_member_id: group_member_id,
        model_requested: "gpt-4",
        provider_cost_usd: Decimal.new(to_string(provider_cost_usd)),
        credential_id: Keyword.get(opts, :credential_id),
        inserted_at: inserted_at
      })
  end

  # Simulates the post-request half of a completed request: settle a zero hold
  # to the given cost. Equivalent to the old `record_spend/2` accumulation
  # (minus the transient hold), used where tests just need spend on the books.
  defp record(subject_id, cost_usd, opts \\ []) do
    hold = %{
      monthly_micro: 0,
      global_micro: 0,
      exempt_global?: Keyword.get(opts, :exempt_global?, false)
    }

    Manager.settle(subject_id, hold, cost_usd)
  end

  # ---------------------------------------------------------------------------
  # Setup — reuse app-tree Manager if running, else start_supervised!; clear the
  # global daily counter so each test starts from its own DB truth.
  # ---------------------------------------------------------------------------

  setup do
    pid = Process.whereis(Manager) || start_supervised!(Manager)
    _ = :sys.get_state(pid)
    :ets.delete(@table, {:global, :daily})
    # The table is a singleton shared across tests; a leftover debounce mark
    # would make the NEXT test's `insert_new` fail and silently skip the
    # enqueue (spurious assert_enqueued failures).
    :ets.delete(@table, {:sync_pending, :global})
    :ok
  end

  # ---------------------------------------------------------------------------
  # reserve/5 — two-layer hold
  # ---------------------------------------------------------------------------

  describe "reserve/5 — two-layer hold" do
    test "under both caps returns a hold and holds on monthly + global" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} =
               Manager.reserve(
                 tm.id,
                 Decimal.new("100.00"),
                 Decimal.new("1000.00"),
                 Decimal.new("20.00"),
                 false
               )

      assert hold.monthly_micro == 20_000_000
      assert hold.global_micro == 20_000_000
      refute hold.exempt_global?

      # The counters read the held amount.
      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("20.00"))
      assert Decimal.equal?(Manager.global_daily_spend(), Decimal.new("20.00"))
    end

    test "rejects when the subject monthly cap is already exhausted" do
      {tm, _} = group_member_fixture()
      record(tm.id, Decimal.new("100.00"))

      assert {:error, {:budget_exceeded, %{layer: :subject}}} =
               Manager.reserve(tm.id, Decimal.new("100.00"), nil, Decimal.new("5.00"), false)
    end

    test "rejects when the global cap is exhausted and rolls back the monthly hold" do
      {tm, _} = group_member_fixture()
      record(tm.id, Decimal.new("50.00"))
      before = Manager.spend(tm.id).monthly_usd

      assert {:error, {:budget_exceeded, %{layer: :global}}} =
               Manager.reserve(
                 tm.id,
                 Decimal.new("100.00"),
                 Decimal.new("50.00"),
                 Decimal.new("5.00"),
                 false
               )

      # Layer 1 rolled back — the rejected reservation left no trace.
      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, before)
    end

    test "nil monthly budget and nil global cap never reject" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} = Manager.reserve(tm.id, nil, nil, Decimal.new("999.00"), false)
      assert hold.monthly_micro == 0
      assert hold.global_micro == 0
    end

    test "exempt_global? skips the global hold" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} =
               Manager.reserve(
                 tm.id,
                 Decimal.new("100.00"),
                 Decimal.new("1.00"),
                 Decimal.new("5.00"),
                 true
               )

      assert hold.exempt_global?
      assert Decimal.equal?(Manager.global_daily_spend(), Decimal.new("0"))
      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("5.00"))
    end

    test "concurrent reservations cannot jointly exceed the cap" do
      {tm, _} = group_member_fixture()
      budget = Decimal.new("1.00")

      # 50 back-to-back reservations of $1.00 against a $1.00 cap. The first
      # holds the whole cap; every subsequent one sees an exhausted subject.
      results =
        for _ <- 1..50 do
          Manager.reserve(tm.id, budget, nil, Decimal.new("1.00"), false)
        end

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:budget_exceeded, _}}, &1)) == 49
    end
  end

  # ---------------------------------------------------------------------------
  # settle/3 — hold → real cost
  # ---------------------------------------------------------------------------

  describe "settle/3" do
    test "swaps the hold for the real cost on both layers + daily display" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} =
               Manager.reserve(
                 tm.id,
                 Decimal.new("100.00"),
                 Decimal.new("1000.00"),
                 Decimal.new("20.00"),
                 false
               )

      assert :ok = Manager.settle(tm.id, hold, Decimal.new("0.50"))

      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("0.50"))
      assert Decimal.equal?(Manager.spend(tm.id).daily_usd, Decimal.new("0.50"))
      assert Decimal.equal?(Manager.global_daily_spend(), Decimal.new("0.50"))
    end

    test "nil actual cost releases the hold fully" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} =
               Manager.reserve(
                 tm.id,
                 Decimal.new("100.00"),
                 Decimal.new("1000.00"),
                 Decimal.new("20.00"),
                 false
               )

      assert :ok = Manager.settle(tm.id, hold, nil)

      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("0"))
      assert Decimal.equal?(Manager.global_daily_spend(), Decimal.new("0"))
    end

    test "enqueues SyncWorker with subject_id" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} = Manager.reserve(tm.id, nil, nil, Decimal.new("1.00"), false)
      assert :ok = Manager.settle(tm.id, hold, Decimal.new("1.00"))

      assert_enqueued(
        worker: Tokengate.Budgets.SyncWorker,
        args: %{"subject_id" => tm.id}
      )
    end

    test "an exempt hold never touches the global counter" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} =
               Manager.reserve(
                 tm.id,
                 Decimal.new("100.00"),
                 Decimal.new("1000.00"),
                 Decimal.new("5.00"),
                 true
               )

      assert :ok = Manager.settle(tm.id, hold, Decimal.new("2.00"))

      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("2.00"))
      assert Decimal.equal?(Manager.global_daily_spend(), Decimal.new("0"))
    end
  end

  # ---------------------------------------------------------------------------
  # release/2 — error path
  # ---------------------------------------------------------------------------

  describe "release/2" do
    test "releases a hold without recording spend" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} =
               Manager.reserve(
                 tm.id,
                 Decimal.new("100.00"),
                 Decimal.new("1000.00"),
                 Decimal.new("5.00"),
                 false
               )

      assert :ok = Manager.release(tm.id, hold)

      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("0"))
      assert Decimal.equal?(Manager.global_daily_spend(), Decimal.new("0"))
    end
  end

  # ---------------------------------------------------------------------------
  # spend/1 — accumulation and read-back
  # ---------------------------------------------------------------------------

  describe "spend/1" do
    test "settled spend accumulates in both daily and monthly" do
      {tm, _} = group_member_fixture()

      assert :ok = record(tm.id, Decimal.new("10.00"))
      assert :ok = record(tm.id, Decimal.new("20.50"))

      spend = Manager.spend(tm.id)
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("30.50"))
      assert Decimal.equal?(spend.daily_usd, Decimal.new("30.50"))
    end

    test "spend/1 returns Decimals" do
      {tm, _} = group_member_fixture()

      assert :ok = record(tm.id, Decimal.new("5.25"))

      spend = Manager.spend(tm.id)
      assert %Decimal{} = spend.monthly_usd
      assert %Decimal{} = spend.daily_usd
    end

    test "spend/1 on untouched member returns zeros" do
      {tm, _} = group_member_fixture()

      spend = Manager.spend(tm.id)
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("0"))
      assert Decimal.equal?(spend.daily_usd, Decimal.new("0"))
    end

    test "nil cost is treated as 0" do
      {tm, _} = group_member_fixture()

      assert :ok = record(tm.id, nil)

      spend = Manager.spend(tm.id)
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("0"))
    end
  end

  # ---------------------------------------------------------------------------
  # Lazy load — ETS seeded from request_logs on first touch
  # ---------------------------------------------------------------------------

  describe "lazy load from DB" do
    test "spend/1 reflects DB provider_cost_usd totals for untouched member" do
      {tm, _} = group_member_fixture()

      # Insert request_logs rows where the real paid cost is lower than the
      # credential price. The budget counters must use provider_cost_usd.
      log_spend(tm.id, "16.00", provider_cost_usd: "4.00")
      log_spend(tm.id, "16.00", provider_cost_usd: "4.00")

      # Untouched member in ETS → spend/1 triggers a lazy load.
      spend = Manager.spend(tm.id)

      # $8 real paid total in DB, not $32 credential total.
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("8.00"))
    end

    test "reserve lazy-loads DB spend before deciding" do
      {tm, _group} = group_member_fixture()

      # Insert $90 of real paid spend into request_logs.
      log_spend(tm.id, "90.00")

      # No settle call — reserve should lazy-load the $90. With a $100 cap, a
      # $10 hold is allowed (spend $90 < cap $100).
      assert {:ok, hold} =
               Manager.reserve(tm.id, Decimal.new("100.00"), nil, Decimal.new("10.00"), false)

      assert hold.monthly_micro == 10_000_000

      # The counter now reads $100 ($90 loaded + $10 held) → the next hold is
      # rejected.
      assert {:error, {:budget_exceeded, %{layer: :subject}}} =
               Manager.reserve(tm.id, Decimal.new("100.00"), nil, Decimal.new("1.00"), false)
    end

    test "settle on top of lazy-loaded DB total accumulates correctly" do
      {tm, _} = group_member_fixture()

      # Seed DB with $30 real paid.
      log_spend(tm.id, "30.00")

      # settle should lazy-load $30, then add $10 = $40.
      assert :ok = record(tm.id, Decimal.new("10.00"))

      spend = Manager.spend(tm.id)
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("40.00"))
    end
  end

  # ---------------------------------------------------------------------------
  # Day/month rollover
  # ---------------------------------------------------------------------------

  describe "day rollover" do
    test "stale daily entry (yesterday) resets to fresh on next access" do
      {tm, _} = group_member_fixture()

      assert :ok = record(tm.id, Decimal.new("50.00"))
      assert Decimal.equal?(Manager.spend(tm.id).daily_usd, Decimal.new("50.00"))

      # Manually mark the daily entry as stale (yesterday's date).
      key = {tm.id, :daily}
      yesterday = Date.add(Date.utc_today(), -1)
      [{^key, micro, loaded?, _stamp}] = :ets.lookup(@table, key)
      :ets.insert(@table, {key, micro, loaded?, yesterday})

      # Next read detects staleness and re-seeds from DB (no logs today) → 0.
      assert Decimal.equal?(Manager.spend(tm.id).daily_usd, Decimal.new("0"))
    end

    test "stale monthly entry (last month) resets to fresh" do
      {tm, _} = group_member_fixture()

      assert :ok = record(tm.id, Decimal.new("50.00"))

      key = {tm.id, :monthly}
      today = Date.utc_today()
      last_month = Date.add(today, -31)
      [{^key, micro, loaded?, _stamp}] = :ets.lookup(@table, key)
      :ets.insert(@table, {key, micro, loaded?, {last_month.year, last_month.month}})

      # DB has no logs for this month → 0.
      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("0"))
    end
  end

  # ---------------------------------------------------------------------------
  # SyncWorker — drift correction
  # ---------------------------------------------------------------------------

  describe "SyncWorker drift correction" do
    test "perform_job resets the monthly counter to DB truth" do
      {tm, _} = group_member_fixture()

      # Insert DB truth: $25.
      log_spend(tm.id, "25.00")

      # Drift the ETS monthly counter to $100.
      :ets.insert(
        @table,
        {{tm.id, :monthly}, 100_000_000, true, {Date.utc_today().year, Date.utc_today().month}}
      )

      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("100.00"))

      job = %Oban.Job{args: %{"subject_id" => tm.id}}
      assert :ok = Tokengate.Budgets.SyncWorker.perform(job)

      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("25.00"))
    end

    test "perform_job with no DB rows resets to 0" do
      {tm, _} = group_member_fixture()

      :ets.insert(
        @table,
        {{tm.id, :monthly}, 50_000_000, true, {Date.utc_today().year, Date.utc_today().month}}
      )

      job = %Oban.Job{args: %{"subject_id" => tm.id}}
      assert :ok = Tokengate.Budgets.SyncWorker.perform(job)

      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("0"))
    end

    test "worker can be enqueued and performed via Oban.Testing" do
      {tm, _} = group_member_fixture()

      log_spend(tm.id, "10.00")

      assert {:ok, hold} = Manager.reserve(tm.id, nil, nil, Decimal.new("1.00"), false)
      assert :ok = Manager.settle(tm.id, hold, Decimal.new("5.00"))

      assert_enqueued(worker: Tokengate.Budgets.SyncWorker)

      assert %{failure: 0} = drained = Oban.drain_queue(queue: :budgets, with_safety: false)
      assert drained.success >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # Micro-USD precision — no float drift
  # ---------------------------------------------------------------------------

  describe "micro-USD precision" do
    test "0.012500 USD spends accumulate exactly over 10k records" do
      {tm, _} = group_member_fixture()

      cost = Decimal.new("0.012500")

      for _ <- 1..10_000 do
        assert :ok = record(tm.id, cost)
      end

      spend = Manager.spend(tm.id)

      # 0.012500 * 10000 = 125.00 exactly — no float drift.
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("125.00"))

      # Verify the internal micro-USD counter is exact.
      # 12500 micro per record * 10000 = 125_000_000 micro total.
      [{_, daily_micro, _, _}] = :ets.lookup(@table, {tm.id, :daily})
      assert daily_micro == 125_000_000
    end

    test "sub-cent precision is preserved (0.000001 USD)" do
      {tm, _} = group_member_fixture()

      assert :ok = record(tm.id, Decimal.new("0.000001"))
      assert :ok = record(tm.id, Decimal.new("0.000001"))
      assert :ok = record(tm.id, Decimal.new("0.000001"))

      spend = Manager.spend(tm.id)
      assert Decimal.equal?(spend.monthly_usd, Decimal.new("0.000003"))
    end

    test "rounding uses half_up for .5 micro boundary" do
      {tm, _} = group_member_fixture()

      # 0.0000005 USD * 1_000_000 = 0.5 micro → rounds to 1 (half_up).
      assert :ok = record(tm.id, Decimal.new("0.0000005"))

      [{_, daily_micro, _, _}] = :ets.lookup(@table, {tm.id, :daily})
      assert daily_micro == 1
    end
  end

  # ---------------------------------------------------------------------------
  # set_from_db/2 — direct ETS reset
  # ---------------------------------------------------------------------------

  describe "set_from_db/2" do
    test "resets the monthly counter and marks it loaded_from_db" do
      {tm, _} = group_member_fixture()

      assert :ok = record(tm.id, Decimal.new("50.00"))
      assert :ok = Manager.set_from_db(tm.id, 20_000_000)

      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("20.00"))

      [{_, _, monthly_loaded?, _}] = :ets.lookup(@table, {tm.id, :monthly})
      assert monthly_loaded? == true
    end
  end

  # ---------------------------------------------------------------------------
  # load_from_db/2 — DB read helper
  # ---------------------------------------------------------------------------

  describe "load_from_db/2" do
    test "returns micro-USD sum from request_logs" do
      {tm, _} = group_member_fixture()

      log_spend(tm.id, "10.00")
      log_spend(tm.id, "20.00")

      from = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
      micro = Manager.load_from_db(tm.id, from)

      # $30.00 = 30_000_000 micro.
      assert micro == 30_000_000
    end

    test "returns 0 when no logs match" do
      {tm, _} = group_member_fixture()

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
      {tm1, _} = group_member_fixture()
      {tm2, _} = group_member_fixture()

      assert :ok = record(tm1.id, Decimal.new("10.00"))
      assert :ok = record(tm2.id, Decimal.new("20.00"))

      assert Decimal.equal?(Manager.spend(tm1.id).monthly_usd, Decimal.new("10.00"))
      assert Decimal.equal?(Manager.spend(tm2.id).monthly_usd, Decimal.new("20.00"))

      deleted = Manager.reset_monthly_counters()
      assert deleted >= 2

      assert Decimal.equal?(Manager.spend(tm1.id).monthly_usd, Decimal.new("0"))
      assert Decimal.equal?(Manager.spend(tm2.id).monthly_usd, Decimal.new("0"))
    end

    test "daily counters are unaffected" do
      {tm, _} = group_member_fixture()

      assert :ok = record(tm.id, Decimal.new("15.00"))

      Manager.reset_monthly_counters()

      assert Decimal.equal?(Manager.spend(tm.id).daily_usd, Decimal.new("15.00"))
    end

    test "reset then settle accumulates from 0" do
      {tm, _} = group_member_fixture()

      # Log en el mes pasado para que el reset mensual lo ignore.
      last_month = Date.add(Date.utc_today(), -31)
      log_spend(tm.id, "5.00", inserted_at: DateTime.new!(last_month, ~T[00:00:00], "Etc/UTC"))

      assert :ok = record(tm.id, Decimal.new("3.00"))

      Manager.reset_monthly_counters()
      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("0"))

      assert :ok = record(tm.id, Decimal.new("2.00"))
      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("2.00"))
    end
  end

  # ---------------------------------------------------------------------------
  # Global daily counter — accumulation, lazy DB load and exemptions
  # ---------------------------------------------------------------------------

  describe "global daily counter" do
    test "settled spend accumulates global daily spend" do
      {tm1, _} = group_member_fixture()
      {tm2, _} = group_member_fixture()

      assert :ok = record(tm1.id, Decimal.new("10.00"))
      assert :ok = record(tm2.id, Decimal.new("20.00"))

      assert Decimal.equal?(Manager.global_daily_spend(), Decimal.new("30.00"))
    end

    test "lazy-loads today's total spend from request_logs on first touch" do
      {tm, _group} = group_member_fixture()

      log_spend(tm.id, "4.00")
      log_spend(tm.id, "6.00")

      :ets.delete(@table, {:global, :daily})

      assert Decimal.equal?(Manager.global_daily_spend(), Decimal.new("10.00"))
    end

    test "yesterday's logs don't count (UTC day rollover)" do
      {tm, _group} = group_member_fixture()

      yesterday = Date.add(Date.utc_today(), -1)
      log_spend(tm.id, "8.00", inserted_at: DateTime.new!(yesterday, ~T[23:59:59], "Etc/UTC"))

      :ets.delete(@table, {:global, :daily})

      assert Decimal.equal?(Manager.global_daily_spend(), Decimal.new("0"))
    end

    test "set_global_from_db resets the counter" do
      {tm, _} = group_member_fixture()

      assert :ok = record(tm.id, Decimal.new("5.00"))
      assert :ok = Manager.set_global_from_db(2_000_000)

      assert Decimal.equal?(Manager.global_daily_spend(), Decimal.new("2.00"))
    end

    test "a global-exempt subject never bumps the global counter" do
      {tm, _} = group_member_fixture()

      {:ok, _} =
        Exemptions.add(%{
          "scope" => "global_daily",
          "subject_type" => "user",
          "user_id" => tm.user_id
        })

      assert {:ok, hold} =
               Manager.reserve(
                 tm.id,
                 Decimal.new("100.00"),
                 Decimal.new("1000.00"),
                 Decimal.new("5.00"),
                 true
               )

      assert :ok = Manager.settle(tm.id, hold, Decimal.new("5.00"))

      # Own counter still bumps; the global counter does not.
      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("5.00"))
      assert Decimal.equal?(Manager.global_daily_spend(), Decimal.new("0"))
    end

    test "a non-exempt subject bumps the global counter" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} =
               Manager.reserve(
                 tm.id,
                 Decimal.new("100.00"),
                 Decimal.new("1000.00"),
                 Decimal.new("5.00"),
                 false
               )

      assert :ok = Manager.settle(tm.id, hold, Decimal.new("5.00"))

      assert Decimal.equal?(Manager.global_daily_spend(), Decimal.new("5.00"))
    end
  end

  describe "global reconciliation" do
    test "load_global_from_db sums the whole instance without a subject filter" do
      {tm1, _} = group_member_fixture()
      {tm2, _} = group_member_fixture()

      log_spend(tm1.id, "7.00")
      log_spend(tm2.id, "3.00")

      micro = Manager.load_global_from_db(Manager.utc_day_start())

      assert micro == 10_000_000
    end

    test "load_global_from_db ignores a stale subject filter (the :global trap)" do
      {tm, _} = group_member_fixture()
      log_spend(tm.id, "4.00")

      # Passing :global to load_from_db/2 does NOT return 0 — it raises: the
      # filter casts an atom against a binary_id column. That is exactly why
      # the reconciler needs its own subject-less loader.
      assert_raise Ecto.Query.CastError, fn ->
        Manager.load_from_db(:global, Manager.utc_day_start())
      end

      assert Manager.load_global_from_db(Manager.utc_day_start()) == 4_000_000
    end

    test "a settled request enqueues the global reconciler exactly once" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} =
               Manager.reserve(
                 tm.id,
                 Decimal.new("100.00"),
                 Decimal.new("1000.00"),
                 Decimal.new("5.00"),
                 false
               )

      assert :ok = Manager.settle(tm.id, hold, Decimal.new("5.00"))

      assert_enqueued(worker: Tokengate.Budgets.GlobalSyncWorker)
    end

    test "an exempt-global subject does NOT enqueue the global reconciler" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} =
               Manager.reserve(
                 tm.id,
                 Decimal.new("100.00"),
                 Decimal.new("1000.00"),
                 Decimal.new("5.00"),
                 true
               )

      assert :ok = Manager.settle(tm.id, hold, Decimal.new("5.00"))

      refute_enqueued(worker: Tokengate.Budgets.GlobalSyncWorker)
    end

    test "the reconciler resets phantom holds to the real DB spend" do
      {tm, _} = group_member_fixture()

      # Real spend is $5, but a crashed request left a $20 ceiling on the
      # counter (the falso-402 scenario).
      log_spend(tm.id, "5.00")
      :ets.insert(@table, {{:global, :daily}, 25_000_000, true, Date.utc_today()})

      assert Decimal.equal?(Manager.global_daily_spend(), Decimal.new("25.00"))

      assert :ok = perform_job(Tokengate.Budgets.GlobalSyncWorker, %{})

      assert Decimal.equal?(Manager.global_daily_spend(), Decimal.new("5.00"))
    end

    test "the reconciler clears its debounce mark so the next settle re-enqueues" do
      assert :ok = perform_job(Tokengate.Budgets.GlobalSyncWorker, %{})

      {tm, _} = group_member_fixture()

      assert {:ok, hold} =
               Manager.reserve(
                 tm.id,
                 Decimal.new("100.00"),
                 Decimal.new("1000.00"),
                 Decimal.new("5.00"),
                 false
               )

      assert :ok = Manager.settle(tm.id, hold, Decimal.new("5.00"))

      assert_enqueued(worker: Tokengate.Budgets.GlobalSyncWorker)
    end
  end
end
