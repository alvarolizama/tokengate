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

  # Durable spend row in request_logs — what display queries read now.
  defp record_log(member, cost_usd, inserted_at \\ nil) do
    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member.id,
        subject_type: "user",
        model_requested: "test-model",
        agent_type: "api",
        status_code: 200,
        prompt_tokens: 10,
        completion_tokens: 5,
        provider_cost_usd: cost_usd,
        latency_ms: 100,
        streaming: false,
        inserted_at: inserted_at || DateTime.utc_now() |> DateTime.truncate(:second)
      })
  end

  # Gasto asentado contra un TOP-UP concreto (el proxy lo persiste en
  # `request_logs.credit_topup_id`). No cuenta contra el límite del sujeto.
  defp record_topup_log(member, topup, cost) do
    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member.id,
        subject_type: "user",
        model_requested: "test-model",
        status_code: 200,
        provider_cost_usd: Decimal.new(cost),
        credit_topup_id: topup.id,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
  end

  # Gasto debitado al LÍMITE del sujeto (log sin top-up): es lo que cuenta
  # contra `monthly_spend_limit_usd`.
  defp record_limit_log(member, cost) do
    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member.id,
        subject_type: "user",
        model_requested: "test-model",
        status_code: 200,
        provider_cost_usd: Decimal.new(cost),
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
  end

  # Camino que usan las vistas (Postgres, por lotes): es el que puede diferir
  # del contador ETS en `member_budget/1`.
  defp budget_for(member) do
    Budgets.list_member_budgets("Etc/UTC")
    |> Enum.find(&(&1.member.id == member.id))
  end

  describe "member_budget/1" do
    test "reports zero spend with no monthly limit (budget is credit now)" do
      member = member_fixture()

      budget = Budgets.member_budget(member)

      assert Decimal.eq?(budget.monthly_spend_usd, Decimal.new("0"))
      assert is_nil(budget.monthly_limit_usd)
      assert is_nil(budget.monthly_pct)
      # Sin límite, sin `unlimited_spend` y sin top-up NO hay camino de gasto:
      # el proxy responde 402. `nil` ya no significa ilimitado.
      assert budget.exhausted?
      assert budget.monthly_exhausted?
    end

    test "reporta el gasto durable del mes (request_logs), no un contador ETS" do
      user = user_fixture()
      group = group_fixture(%{"monthly_spend_limit_usd" => "100.00"})
      member = member_fixture(group, user)

      record_limit_log(member, "33.33")

      budget = Budgets.member_budget(member)

      assert Decimal.eq?(budget.monthly_spend_usd, Decimal.new("33.33"))
      assert Decimal.eq?(budget.monthly_limit_usd, Decimal.new("100.00"))
      refute budget.exhausted?
    end
  end

  # Regresión: los usuarios de un grupo con suscripción salían "sin límite"
  # El límite del miembro es el EFECTIVO: propio si lo define, si no el del
  # grupo. `unlimited_spend` es el único camino a ilimitado y `0` es CERO.
  describe "member_budget/1 con límite por sujeto" do
    test "sin límite propio hereda el del grupo (no nil)" do
      user = user_fixture()
      group = group_fixture(%{"monthly_spend_limit_usd" => "10.00"})
      member = member_fixture(group, user)

      budget = Budgets.member_budget(member)

      assert budget.has_credit?
      refute is_nil(budget.monthly_limit_usd)
      assert Decimal.eq?(budget.monthly_limit_usd, Decimal.new("10.00"))
      assert Decimal.eq?(budget.monthly_spend_usd, Decimal.new("0"))
      assert Decimal.eq?(budget.credit_remaining_usd, Decimal.new("10.00"))
      refute budget.exhausted?
    end

    test "lo debitado al límite es el gasto sin top-up; el de top-up va aparte" do
      user = user_fixture()
      group = group_fixture(%{"monthly_spend_limit_usd" => "10.00"})
      member = member_fixture(group, user)

      {:ok, topup} =
        Tokengate.Credits.Topups.create(%{"user_id" => user.id, "amount_usd" => "5.00"})

      # 2.00 contra el límite + 1.50 contra un top-up.
      record_limit_log(member, "2.00")
      record_topup_log(member, topup, "1.50")

      budget = budget_for(member)

      # Contra el límite solo cuenta el request sin top-up…
      assert Decimal.eq?(budget.monthly_spend_usd, Decimal.new("2"))
      assert Decimal.eq?(budget.credit_remaining_usd, Decimal.new("8"))
      assert_in_delta budget.monthly_pct, 20.0, 0.01
      # …y el gasto real del mes incluye ambos.
      assert Decimal.eq?(budget.real_monthly_spend_usd, Decimal.new("3.5"))
      refute budget.exhausted?
    end

    test "límite 0 es CERO: agotado y al 100%, nunca ilimitado" do
      user = user_fixture()
      group = group_fixture(%{"monthly_spend_limit_usd" => "0"})
      member = member_fixture(group, user)

      budget = Budgets.member_budget(member)

      assert budget.has_credit?
      assert Decimal.eq?(budget.monthly_limit_usd, Decimal.new("0"))
      assert budget.exhausted?
      assert_in_delta budget.monthly_pct, 100.0, 0.01
    end

    test "unlimited_spend pasa con cap global: sin pct y sin agotar" do
      user = user_fixture()
      group = group_fixture(%{"unlimited_spend" => true})
      member = member_fixture(group, user)

      budget = Budgets.member_budget(member)

      assert budget.unlimited?
      refute budget.has_credit?
      assert is_nil(budget.monthly_limit_usd)
      assert is_nil(budget.monthly_pct)
      refute budget.exhausted?
    end

    test "sin límite, sin ilimitado y sin top-up: agotado (bloqueado de verdad)" do
      member = member_fixture(group_fixture(), user_fixture())

      budget = Budgets.member_budget(member)

      assert is_nil(budget.monthly_limit_usd)
      refute budget.unlimited?
      refute budget.has_credit?
      assert budget.exhausted?
    end

    test "un top-up vigente le da camino de gasto a un sujeto sin límite" do
      user = user_fixture()
      member = member_fixture(group_fixture(), user)
      {:ok, _} = Tokengate.Credits.Topups.create(%{"user_id" => user.id, "amount_usd" => "5.00"})

      budget = Budgets.member_budget(member)

      refute budget.exhausted?
      assert Decimal.eq?(budget.remaining_topup_usd, Decimal.new("5"))
    end

    test "list_member_budgets/1 resuelve el límite efectivo en lote" do
      user = user_fixture()
      group = group_fixture(%{"monthly_spend_limit_usd" => "7.00"})
      member = member_fixture(group, user)
      record_limit_log(member, "1.00")

      budgets = Budgets.list_member_budgets("Etc/UTC")
      budget = Enum.find(budgets, &(&1.member.id == member.id))

      assert budget.has_credit?
      assert Decimal.eq?(budget.monthly_limit_usd, Decimal.new("7.00"))
      assert Decimal.eq?(budget.monthly_spend_usd, Decimal.new("1"))
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
    test "marca a quien no tiene camino de gasto, no a quien tiene margen" do
      # Con límite y sin gasto: tiene margen.
      ok_group = group_fixture(%{"monthly_spend_limit_usd" => "100.00"})
      ok_member = member_fixture(ok_group, user_fixture())

      # Sin límite, sin ilimitado y sin top-up: bloqueado (es lo que el proxy
      # responde 402 con `:no_credit`).
      blocked_member = member_fixture(group_fixture(), user_fixture())

      exhausted = Budgets.list_exhausted_member_budgets()
      ids = Enum.map(exhausted, & &1.member.id)

      assert blocked_member.id in ids
      refute ok_member.id in ids
      assert Budgets.count_exhausted() == length(exhausted)
    end
  end

  describe "spend_by_user/0" do
    test "rolls up spend across all memberships of a user" do
      user = user_fixture()
      group_a = group_fixture(%{"monthly_spend_limit_usd" => "10.00"})
      group_b = group_fixture(%{"monthly_spend_limit_usd" => "1000.00"})
      member_a = member_fixture(group_a, user)
      member_b = member_fixture(group_b, user)

      record_limit_log(member_a, "2.00")
      record_limit_log(member_b, "3.00")

      spend = Budgets.spend_by_user()
      user_spend = Map.fetch!(spend, user.id)

      # El límite se suma entre membresías; el gasto es el del usuario (una
      # sola vez, aunque tenga varias membresías) en el mes UTC.
      assert Decimal.eq?(user_spend.monthly_usd, Decimal.new("5.00"))
      assert Decimal.eq?(user_spend.monthly_limit_usd, Decimal.new("1010.00"))
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
    test "agrupa por grupo: suma los límites y el gasto de sus miembros" do
      group = group_fixture(%{"monthly_spend_limit_usd" => "300.00"})
      member_a = member_fixture(group)
      member_b = member_fixture(group)
      # Otro grupo que no debe mezclarse
      _other = member_fixture()

      record_limit_log(member_a, "100.00")
      record_limit_log(member_b, "50.00")

      groups = Budgets.list_group_budgets()
      row = Enum.find(groups, &(&1.group.id == group.id))

      assert row.member_count == 2
      # Cada miembro hereda el límite del grupo: el rollup los suma.
      assert Decimal.eq?(row.monthly_limit_usd, Decimal.new("600.00"))
      refute row.has_unlimited?
      # gasto del grupo = 100 + 50
      assert Decimal.eq?(row.monthly_spend_usd, Decimal.new("150.00"))
      assert_in_delta row.monthly_pct, 25.0, 0.01
    end

    test "spot check on group budget values" do
      _member = member_fixture()
      group = group_fixture()
      _member = member_fixture()

      groups = Budgets.list_group_budgets()
      refute Enum.find(groups, &(&1.group.id == group.id))
    end
  end

  describe "spend windows (día local · mes UTC)" do
    test "spend_by_member_ids: día local para el daily, mes UTC para el monthly" do
      member = member_fixture()
      tz = "America/Mexico_City"
      local_day_start = Periods.start_of_day_utc(tz)
      utc_month_start = Periods.start_of_month_utc("Etc/UTC")

      # Tres instantes que separan las ventanas entre sí:
      # 1) antes del inicio del MES UTC → fuera del monthly
      log_request(member.id, DateTime.add(utc_month_start, -3600, :second), "8.00")
      # 2) 23:00 del día anterior LOCAL (06:00 UTC − 1h = 05:00 UTC) → fuera del
      #    daily local pero DENTRO del mes UTC: el caso que discrimina los dos
      #    criterios (con un mes local, este log quedaba fuera del monthly).
      log_request(member.id, DateTime.add(local_day_start, -3600, :second), "1.50")
      # 3) hoy local → cuenta en ambas
      log_request(member.id, DateTime.add(local_day_start, 3600, :second), "2.50")

      spend = Budgets.spend_by_member_ids([member.id], tz)

      # Daily: día local del visor (display-only, sin tope que respaldar).
      assert Decimal.eq?(spend.daily[member.id], Decimal.new("2.50"))

      # Monthly: mes UTC — incluye el log de "ayer local" y excluye solo el
      # anterior al día 1 UTC.
      assert Decimal.eq?(spend.monthly[member.id], Decimal.new("4.00"))
    end

    test "el monthly NO depende del timezone del visor (mismo número en UTC y Madrid)" do
      member = member_fixture()

      # Ancla: minuto 1 del MES UTC. Cae dentro del mes UTC siempre, y la
      # invarianza que este test mide es la del monthly (el daily tiene su
      # propio test), así que la hora de corrida no influye.
      utc_month_start = Periods.start_of_month_utc("Etc/UTC")
      log_request(member.id, DateTime.add(utc_month_start, 60, :second), "1.50")

      utc = Budgets.spend_by_member_ids([member.id], "Etc/UTC")
      madrid = Budgets.spend_by_member_ids([member.id], "Europe/Madrid")

      assert Decimal.eq?(utc.monthly[member.id], Decimal.new("1.50"))
      # El mismo número con cualquier timezone del visor: el mes es UTC.
      assert Decimal.eq?(utc.monthly[member.id], madrid.monthly[member.id])
    end

    test "el daily sí sigue el día local del visor" do
      member = member_fixture()
      # Zona con offset POSITIVO: su medianoche cae ANTES de la de UTC, así que
      # su día arranca unas horas antes del día UTC. La frontera así construida
      # queda siempre en el pasado (a cualquier hora del día), a diferencia de
      # anclar a la medianoche local futura.
      tz = "Asia/Tokyo"
      tokyo_start = Periods.start_of_day_utc(tz)

      # 60s dentro del día de Tokio: en su ventana diaria, pero ANTERIOR al
      # arranque del día UTC (que empieza más tarde).
      log_request(member.id, DateTime.add(tokyo_start, 60, :second), "1.50")

      tokyo = Budgets.spend_by_member_ids([member.id], tz)
      utc = Budgets.spend_by_member_ids([member.id], "Etc/UTC")

      # El visor de Tokio ve el log dentro de su día…
      assert Decimal.eq?(Map.get(tokyo.daily, member.id, Decimal.new(0)), Decimal.new("1.50"))

      # …y el visor UTC no: prueba que la ventana diaria sigue al visor y no al
      # reloj UTC.
      assert Decimal.eq?(Map.get(utc.daily, member.id, Decimal.new(0)), Decimal.new("0"))
    end

    test "list_member_budgets lee el gasto mensual del mes UTC" do
      member = member_fixture()
      tz = "America/Mexico_City"
      local_day_start = Periods.start_of_day_utc(tz)

      # 23:00 del día anterior local → daily 0 (día local), monthly 5.00 (mes UTC)
      log_request(member.id, DateTime.add(local_day_start, -3600, :second), "5.00")

      budgets = Budgets.list_member_budgets(tz)
      budget = Enum.find(budgets, &(&1.member.id == member.id))

      assert Decimal.eq?(budget.daily_spend_usd, Decimal.new("0"))
      assert Decimal.eq?(budget.monthly_spend_usd, Decimal.new("5.00"))
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

      assert Decimal.eq?(Budgets.monthly_spend_for_member(member.id), Decimal.new("1.00"))
      assert Decimal.eq?(Budgets.daily_spend_for_member(member.id, tz), Decimal.new("1.00"))
    end

    test "list_member_budgets(tz) con 0 miembros no revienta" do
      assert Budgets.spend_by_member_ids([], "America/Mexico_City") == %{daily: %{}, monthly: %{}}
    end
  end

  describe "global_daily_budget_summary/0" do
    # El contador global vive en ETS (tabla pública del árbol de la app):
    # se limpia como en manager_test para que cada test siembre desde su
    # propia DB.
    setup do
      :ets.delete(:tokengate_budgets, {:global, :daily})
      :ok
    end

    test "sin cap configurado: nil en cap y pct, sin badge de estado" do
      {:ok, _} = Tokengate.GlobalSettings.update(%{"daily_max_spend_usd" => nil})

      summary = Budgets.global_daily_budget_summary()

      assert summary.daily_cap_usd == nil
      assert summary.daily_pct == nil
      assert summary.exempt_count == 0
      assert Decimal.eq?(summary.daily_spend_usd, Decimal.new(0))
    end

    test "con cap: pct refleja el gasto real de la DB (request_logs), no el contador ETS" do
      {:ok, _} = Tokengate.GlobalSettings.update(%{"daily_max_spend_usd" => "100.00"})
      member = member_fixture()
      record_log(member, Decimal.new("25.00"))
      # Hold en vuelo en el contador ETS: NO debe reflejarse en el display.
      # El sujeto es ilimitado ⇒ solo se toca el cap global.
      plan = %{subject: {:user, "cap-test"}, limit_usd: nil, unlimited?: true, topups: []}
      {:ok, hold} = Manager.reserve_plan(plan, Decimal.new("100.00"), Decimal.new("20.00"), false)

      summary = Budgets.global_daily_budget_summary()

      # El spend del card es gasto real desde la DB, no el contador con holds.
      refute Decimal.eq?(summary.daily_spend_usd, Manager.global_daily_spend())
      assert Decimal.eq?(summary.daily_spend_usd, Decimal.new("25.00"))
      assert Decimal.eq?(summary.daily_cap_usd, Decimal.new("100.00"))
      assert summary.daily_pct == 25.0

      :ok = Manager.release_credits(hold)
    end

    test "cuenta las exenciones global_daily aunque no afecten el contador" do
      {:ok, _} = Tokengate.GlobalSettings.update(%{"daily_max_spend_usd" => "50.00"})
      user = user_fixture()

      {:ok, _} =
        Tokengate.Budgets.Exemptions.add(%{
          "scope" => "global_daily",
          "subject_type" => "user",
          "user_id" => user.id
        })

      # Sujeto exento: su gasto no toca el contador global…
      member = member_fixture(nil, user)
      record_log(member, Decimal.new("10.00"))

      summary = Budgets.global_daily_budget_summary()

      # …pero la exención sí aparece en el conteo del card, y su gasto real
      # (que el proxy no cuenta) SÍ entra al gasto mostrado.
      assert summary.exempt_count == 1
      assert Decimal.eq?(summary.daily_spend_usd, Decimal.new("10.00"))
    end

    test "gasto del día UTC: ignora logs de días anteriores" do
      {:ok, _} = Tokengate.GlobalSettings.update(%{"daily_max_spend_usd" => "100.00"})
      member = member_fixture()

      yesterday =
        DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

      record_log(member, Decimal.new("5.00"), yesterday)
      record_log(member, Decimal.new("25.00"))

      # La ventana del tope es la del kill-switch (día UTC): el log de ayer no
      # entra, y no hay forma de pedir otra ventana.
      assert Decimal.eq?(
               Budgets.global_daily_budget_summary().daily_spend_usd,
               Decimal.new("25.00")
             )
    end
  end
end
