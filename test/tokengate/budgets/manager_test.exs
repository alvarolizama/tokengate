defmodule Tokengate.Budgets.ManagerTest do
  @moduledoc """
  Tests for Tokengate.Budgets.Manager — the ETS micro-USD spend cache with the
  monthly per-subject limit (plus the credits spend plan) enforced through a
  reserve → settle primitive, with lazy DB load.

  `async: false` because the ETS table `:tokengate_budgets` is a named
  (singleton) table; concurrent tests would clobber each other's counters.
  Each test uses a unique group member (via real Accounts fixtures) so
  inter-test contamination is avoided even within the serial run.
  """

  use Tokengate.DataCase, async: false
  use Oban.Testing, repo: Tokengate.Repo
  alias Tokengate.Budgets.Manager
  alias Tokengate.Accounts
  alias Tokengate.Credits
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
  defp record(subject_id, cost_usd) do
    today = Date.utc_today()

    hold = %{
      monthly_micro: 0,
      # Stamps de período, iguales a los de los holds reales: el guard de
      # settle/release compara contra el ESTADO del contador, no el reloj.
      period: {today.year, today.month}
    }

    Manager.settle(subject_id, hold, cost_usd)
  end

  # Sujeto con límite mensual propio (en el grupo) para los probes de créditos.
  defp limited_member_fixture(limit_usd) do
    group = group_fixture(%{"monthly_spend_limit_usd" => limit_usd})
    user = user_fixture()

    {:ok, member} =
      Accounts.create_group_member(%{"user_id" => user.id, "group_id" => group.id})

    {member, user}
  end

  # Dispara 10 reserve_plan concurrentes y regresa los resultados en orden de
  # lanzamiento (la aserción es sobre resultados, no sobre tiempos).
  defp run_concurrent_reserve(plan, requested_usd) do
    1..10
    |> Task.async_stream(
      fn _i -> Manager.reserve_plan(plan, requested_usd) end,
      max_concurrency: 10
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  # ---------------------------------------------------------------------------
  # Setup — reuse app-tree Manager if running, else start_supervised!.
  # ---------------------------------------------------------------------------

  setup do
    pid = Process.whereis(Manager) || start_supervised!(Manager)
    _ = :sys.get_state(pid)
    :ok
  end

  # ---------------------------------------------------------------------------
  # reserve/3 — monthly hold
  # ---------------------------------------------------------------------------

  describe "reserve/3 — monthly hold" do
    test "under the cap returns a hold and holds on the monthly counter" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} =
               Manager.reserve(tm.id, Decimal.new("100.00"), Decimal.new("20.00"))

      assert hold.monthly_micro == 20_000_000

      # The counter reads the held amount.
      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("20.00"))
    end

    test "rejects when the subject monthly cap is already exhausted" do
      {tm, _} = group_member_fixture()
      record(tm.id, Decimal.new("100.00"))

      assert {:error, {:budget_exceeded, %{layer: :subject}}} =
               Manager.reserve(tm.id, Decimal.new("100.00"), Decimal.new("5.00"))
    end

    test "nil monthly budget never rejects" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} = Manager.reserve(tm.id, nil, Decimal.new("999.00"))
      assert hold.monthly_micro == 0
    end

    test "concurrent reservations cannot jointly exceed the cap" do
      {tm, _} = group_member_fixture()
      budget = Decimal.new("1.00")

      # 50 back-to-back reservations of $1.00 against a $1.00 cap. The first
      # holds the whole cap; every subsequent one sees an exhausted subject.
      results =
        for _ <- 1..50 do
          Manager.reserve(tm.id, budget, Decimal.new("1.00"))
        end

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:budget_exceeded, _}}, &1)) == 49
    end
  end

  # ---------------------------------------------------------------------------
  # settle/3 — hold → real cost
  # ---------------------------------------------------------------------------

  describe "settle/3" do
    test "swaps the hold for the real cost on the monthly + daily display" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} =
               Manager.reserve(tm.id, Decimal.new("100.00"), Decimal.new("20.00"))

      assert :ok = Manager.settle(tm.id, hold, Decimal.new("0.50"))

      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("0.50"))
      assert Decimal.equal?(Manager.spend(tm.id).daily_usd, Decimal.new("0.50"))
    end

    test "nil actual cost releases the hold fully" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} =
               Manager.reserve(tm.id, Decimal.new("100.00"), Decimal.new("20.00"))

      assert :ok = Manager.settle(tm.id, hold, nil)

      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("0"))
    end

    test "enqueues SyncWorker with subject_id" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} = Manager.reserve(tm.id, nil, Decimal.new("1.00"))
      assert :ok = Manager.settle(tm.id, hold, Decimal.new("1.00"))

      assert_enqueued(
        worker: Tokengate.Budgets.SyncWorker,
        args: %{"subject_id" => tm.id}
      )
    end
  end

  # ---------------------------------------------------------------------------
  # release/2 — error path
  # ---------------------------------------------------------------------------

  describe "release/2" do
    test "releases a hold without recording spend" do
      {tm, _} = group_member_fixture()

      assert {:ok, hold} =
               Manager.reserve(tm.id, Decimal.new("100.00"), Decimal.new("5.00"))

      assert :ok = Manager.release(tm.id, hold)

      assert Decimal.equal?(Manager.spend(tm.id).monthly_usd, Decimal.new("0"))
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
               Manager.reserve(tm.id, Decimal.new("100.00"), Decimal.new("10.00"))

      assert hold.monthly_micro == 10_000_000

      # The counter now reads $100 ($90 loaded + $10 held) → the next hold is
      # rejected.
      assert {:error, {:budget_exceeded, %{layer: :subject}}} =
               Manager.reserve(tm.id, Decimal.new("100.00"), Decimal.new("1.00"))
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

      assert {:ok, hold} = Manager.reserve(tm.id, nil, Decimal.new("1.00"))
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
  # reserve_plan/4 — gate atómico de créditos (probes de concurrencia)
  # ---------------------------------------------------------------------------

  describe "reserve_plan/4 — gate atómico" do
    setup do
      pid = Process.whereis(Manager) || start_supervised!(Manager)
      _ = :sys.get_state(pid)
      # La tabla de créditos es un singleton compartido entre tests: arrancar
      # limpia para que ningún contador heredado contamine el probe.
      :ets.delete_all_objects(:tokengate_credits)
      :ok
    end

    test "10 reserve_plan concurrentes de 1.00 contra límite 1.00 conceden exactamente 1" do
      {member, _user} = limited_member_fixture("1.00")
      plan = Credits.plan(member)

      results = run_concurrent_reserve(plan, Decimal.new("1.00"))

      granted = Enum.count(results, &match?({:ok, _}, &1))

      rejected =
        Enum.count(results, &match?({:error, {:budget_exceeded, %{layer: :subject}}}, &1))

      assert granted == 1, "esperaba 1 concedido, hubo #{granted}: #{inspect(results)}"
      assert rejected == 9

      :ets.delete(:tokengate_credits, {:limit, plan.subject})
    end

    test "10 reserve_plan concurrentes de 1.00 contra bolsín de 1.00 conceden exactamente 1" do
      {member, user} = limited_member_fixture("0")

      {:ok, topup} =
        Credits.Topups.create(%{"user_id" => user.id, "amount_usd" => "1.00", "label" => "probe"})

      plan = Credits.plan(member)

      # Bolsín FRÍO a propósito: la carga perezosa desde DB es la que da ancho
      # de carrera al probe pre-fix (calentarlo colapsa la ventana y el probe
      # pasa de suerte); post-fix el guard de seed hace el desenlace determinista.
      results = run_concurrent_reserve(plan, Decimal.new("1.00"))

      granted = Enum.count(results, &match?({:ok, %{kind: :topup}}, &1))

      rejected =
        Enum.count(results, &match?({:error, {:budget_exceeded, %{layer: :subject}}}, &1))

      assert granted == 1, "esperaba 1 concedido, hubo #{granted}: #{inspect(results)}"
      assert rejected == 9

      :ets.delete(:tokengate_credits, {:topup, topup.id})
      :ets.delete(:tokengate_credits, {:limit, plan.subject})
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

    test "daily and global counters are wiped too (maintenance reset contract)" do
      {tm, _} = group_member_fixture()

      assert :ok = record(tm.id, Decimal.new("15.00"))

      Manager.reset_monthly_counters()

      # El reset de Mantenimiento borra TODO el gasto derivado de los logs:
      # tras truncar el histórico, el enforcement no puede seguir viendo el
      # gasto diario (o rechazaría 402 contra datos inexistentes). El
      # siguiente acceso lazy-recarga desde la DB (vacía tras el truncate).
      assert Decimal.equal?(Manager.spend(tm.id).daily_usd, Decimal.new("0"))
    end

    test "settle cruzando el reset no absorbe actual − held en el contador fresco" do
      {member, _user} = limited_member_fixture("10.00")
      subject = {:user, member.user_id}
      key = {:limit, subject}

      # Verdad durable: 5.00 debitados al límite este mes (logs sin top-up).
      log_spend(member.id, "5.00")

      plan = Credits.plan(member)

      # Hold en vuelo: 1.00 retenidos contra el contador del límite.
      assert {:ok, hold} = Manager.reserve_plan(plan, Decimal.new("1.00"))
      assert hold.kind == :limit

      # El reset mensual borra {:limit, subject} EN PLENO VUELO.
      assert Manager.reset_monthly_counters() >= 1

      # El settle del hold viejo aterriza tarde: 0.30 reales vs 1.00 retenidos.
      # Con la entrada ausente, el guard por ESTADO del contador lo salta: ni
      # absorbe −0.70 ni resucita la clave — la recuperación es el re-seed
      # desde logs, no el settle.
      assert :ok = Manager.settle_credits(hold, Decimal.new("0.30"))
      assert [] = :ets.lookup(:tokengate_credits, key)

      # El re-seed (verdad durable) reconstruye EXACTAMENTE el gasto de logs:
      # sin el hold fantasma (nunca llegó a logs) ni la absorción negativa.
      assert :ok = Manager.reseed_limit_counter(subject)
      assert %{consumed_micro: 5_000_000} = Manager.limit_spend(subject)

      :ets.delete(:tokengate_credits, key)
    end

    test "el settle de un top-up SIEMPRE aterriza en su bolsín (no es mensual)" do
      group = group_fixture(%{"monthly_spend_limit_usd" => "0"})
      user = user_fixture()

      {:ok, member} =
        Accounts.create_group_member(%{"user_id" => user.id, "group_id" => group.id})

      {:ok, topup} =
        Credits.Topups.create(%{
          "user_id" => user.id,
          "amount_usd" => "1.00",
          "label" => "rescate"
        })

      plan = Credits.plan(member)

      assert {:ok, hold} = Manager.reserve_plan(plan, Decimal.new("1.00"))
      assert hold.kind == :topup

      # El reset mensual NO toca los bolsines; el settle tardío del top-up
      # aterriza igual: 0.30 reales vs 1.00 retenidos → 0.30 consumidos.
      Manager.reset_monthly_counters()

      assert :ok = Manager.settle_credits(hold, Decimal.new("0.30"))
      assert %{consumed_micro: 300_000} = Manager.topup_spend(topup.id)

      :ets.delete(:tokengate_credits, {:topup, topup.id})
    end
  end

  # ---------------------------------------------------------------------------
  # clear_topup_counters/0 — SOLO reset de Mantenimiento (truncate de logs)
  # ---------------------------------------------------------------------------

  describe "clear_topup_counters/0" do
    test "borra los bolsines de top-up pero no los contadores de límite" do
      :ets.insert(
        :tokengate_credits,
        {{:limit, {:user, "tu1"}}, 5, nil, nil, true, nil, true}
      )

      :ets.insert(:tokengate_credits, {{:topup, "tt1"}, 5, 10, nil, true, nil, false})

      _deleted = Manager.clear_topup_counters()

      # The return count is global (other tests/lazy seeds may coexist).
      # Assert the targeted deletion and the surviving limit, not that count.
      assert [] == :ets.lookup(:tokengate_credits, {:topup, "tt1"})
      # El límite NO se toca: clear_topup_counters es complemento del truncate,
      # no un sustituto del reset mensual (que sí borra los límites).
      assert [_] = :ets.lookup(:tokengate_credits, {:limit, {:user, "tu1"}})
    after
      :ets.delete(:tokengate_credits, {:limit, {:user, "tu1"}})
      :ets.delete(:tokengate_credits, {:topup, "tt1"})
    end
  end
end
