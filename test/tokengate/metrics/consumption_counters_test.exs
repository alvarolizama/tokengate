defmodule Tokengate.Metrics.ConsumptionCountersTest do
  @moduledoc """
  The durable counters are DERIVED from `request_logs` by the trigger created in
  `20261122064158_create_consumption_counters`: every insert path bumps them in
  the same transaction, and a deduplicated retry bumps nothing.

  These tests own the invariant the readers depend on: counter == aggregate of
  the logs, in exact integer micro-USD.
  """
  # The retention test below creates and DROPs a real `request_logs` partition,
  # and that structure is shared: DDL is transactional in Postgres, but two
  # suites touching the same partitions at once must not overlap.
  use Tokengate.DataCase, async: false

  import Ecto.Query

  alias Tokengate.Accounts.{Group, GroupMember, Service, User}
  alias Tokengate.Credits.Topup
  alias Tokengate.Credits.Topups
  alias Tokengate.Metrics.ConsumptionCounters
  alias Tokengate.Logs
  alias Tokengate.Logs.PartitionWorker
  alias Tokengate.Repo

  defp insert_user! do
    Repo.insert!(%User{
      email: "counters-#{System.unique_integer([:positive])}@test.local",
      name: "Counters Test"
    })
  end

  defp insert_service! do
    Repo.insert!(%Service{name: "counters-#{System.unique_integer([:positive])}"})
  end

  defp insert_member!(user) do
    group = Repo.insert!(%Group{name: "counters-#{System.unique_integer([:positive])}"})

    Repo.insert!(%GroupMember{user_id: user.id, group_id: group.id})
  end

  defp insert_topup!(user) do
    Repo.insert!(%Topup{user_id: user.id, amount_usd: Decimal.new("10.000000"), status: "active"})
  end

  defp counter(query), do: Repo.one(query)

  defp user_counter(user_id, day) do
    counter(
      from(c in "consumption_counters",
        where: c.user_id == type(^user_id, :binary_id) and c.day == ^day,
        select: %{
          request_count: c.request_count,
          error_count: c.error_count,
          spend_micro: c.spend_micro,
          limit_spend_micro: c.limit_spend_micro,
          prompt_tokens: c.prompt_tokens,
          completion_tokens: c.completion_tokens
        }
      )
    )
  end

  defp service_counter(service_id, day) do
    counter(
      from(c in "consumption_counters",
        where: c.service_id == type(^service_id, :binary_id) and c.day == ^day,
        select: %{
          request_count: c.request_count,
          error_count: c.error_count,
          spend_micro: c.spend_micro,
          limit_spend_micro: c.limit_spend_micro
        }
      )
    )
  end

  defp topup_counter(topup_id) do
    counter(
      from(t in "topup_consumption_counters",
        where: t.topup_id == type(^topup_id, :binary_id),
        select: %{consumed_micro: t.consumed_micro, request_count: t.request_count}
      )
    )
  end

  defp log!(attrs) do
    base = %{
      model_requested: "gpt-4",
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      subject_type: "user",
      status_code: 200
    }

    {:ok, log} = Logs.log_request(Map.merge(base, attrs))
    log
  end

  test "a logged request bumps the user, service and top-up counters" do
    user = insert_user!()
    service = insert_service!()
    member = insert_member!(user)
    topup = insert_topup!(user)

    log =
      log!(%{
        user_id: user.id,
        group_member_id: member.id,
        service_id: service.id,
        credit_topup_id: topup.id,
        provider_cost_usd: Decimal.new("0.123456"),
        prompt_tokens: 100,
        completion_tokens: 40
      })

    day = DateTime.to_date(log.inserted_at)

    assert user_counter(user.id, day) == %{
             request_count: 1,
             error_count: 0,
             spend_micro: 123_456,
             # Debited to the top-up, so it does NOT consume the limit.
             limit_spend_micro: 0,
             prompt_tokens: 100,
             completion_tokens: 40
           }

    assert service_counter(service.id, day) == %{
             request_count: 1,
             error_count: 0,
             spend_micro: 123_456,
             limit_spend_micro: 0
           }

    assert topup_counter(topup.id) == %{consumed_micro: 123_456, request_count: 1}
  end

  test "rows without a top-up consume the limit amount too" do
    user = insert_user!()
    member = insert_member!(user)

    log =
      log!(%{
        user_id: user.id,
        group_member_id: member.id,
        provider_cost_usd: Decimal.new("2.50")
      })

    assert %{spend_micro: 2_500_000, limit_spend_micro: 2_500_000} =
             user_counter(user.id, DateTime.to_date(log.inserted_at))
  end

  test "errors are counted as requests; a cache hit costs nothing" do
    user = insert_user!()
    member = insert_member!(user)

    log =
      log!(%{
        user_id: user.id,
        group_member_id: member.id,
        status_code: 503,
        provider_cost_usd: Decimal.new("0")
      })

    day = DateTime.to_date(log.inserted_at)

    assert %{request_count: 1, error_count: 1, spend_micro: 0} = user_counter(user.id, day)

    log!(%{
      user_id: user.id,
      group_member_id: member.id,
      cache_hit: true,
      provider_cost_usd: Decimal.new("0")
    })

    assert %{request_count: 2, error_count: 1, spend_micro: 0} = user_counter(user.id, day)
  end

  test "per-day buckets split on the UTC day, not on insert time" do
    user = insert_user!()
    member = insert_member!(user)

    day_a = ~U[2026-03-10 23:59:59Z]
    day_b = ~U[2026-03-11 00:00:01Z]

    log!(%{
      user_id: user.id,
      group_member_id: member.id,
      inserted_at: day_a,
      provider_cost_usd: Decimal.new("1")
    })

    log!(%{
      user_id: user.id,
      group_member_id: member.id,
      inserted_at: day_b,
      provider_cost_usd: Decimal.new("2")
    })

    assert %{spend_micro: 1_000_000} = user_counter(user.id, ~D[2026-03-10])
    assert %{spend_micro: 2_000_000} = user_counter(user.id, ~D[2026-03-11])
  end

  # The retry contract: `ON CONFLICT (oban_job_id, inserted_at) DO NOTHING`
  # means the second insert creates no row — so the trigger never fires and the
  # counters stay exact. A bump-after-commit would double count here.
  test "a deduplicated retry does not bump the counters twice" do
    user = insert_user!()
    member = insert_member!(user)
    inserted_at = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      user_id: user.id,
      group_member_id: member.id,
      oban_job_id: 987_654,
      inserted_at: inserted_at,
      provider_cost_usd: Decimal.new("3.00")
    }

    log!(attrs)
    log!(attrs)

    assert Repo.aggregate(from(l in "request_logs", where: l.oban_job_id == 987_654), :count) == 1

    assert %{request_count: 1, spend_micro: 3_000_000} =
             user_counter(user.id, DateTime.to_date(inserted_at))
  end

  test "truncate_request_logs also empties the counters" do
    user = insert_user!()
    member = insert_member!(user)
    topup = insert_topup!(user)

    log =
      log!(%{
        user_id: user.id,
        group_member_id: member.id,
        credit_topup_id: topup.id,
        provider_cost_usd: Decimal.new("5.00")
      })

    assert user_counter(user.id, DateTime.to_date(log.inserted_at)) != nil
    assert topup_counter(topup.id) != nil

    Logs.truncate_request_logs()

    assert user_counter(user.id, DateTime.to_date(log.inserted_at)) == nil
    assert topup_counter(topup.id) == nil
  end

  test "deleting a service drops its counters; a user keeps history (no FK)" do
    user = insert_user!()
    service = insert_service!()
    member = insert_member!(user)

    log =
      log!(%{
        user_id: user.id,
        group_member_id: member.id,
        service_id: service.id,
        provider_cost_usd: Decimal.new("1.00")
      })

    day = DateTime.to_date(log.inserted_at)

    Repo.delete!(service)
    assert service_counter(service.id, day) == nil
    assert %{spend_micro: 1_000_000} = user_counter(user.id, day)
  end

  test "deleting a top-up drops its counter and keeps the log attribution" do
    user = insert_user!()
    member = insert_member!(user)
    topup = insert_topup!(user)

    log!(%{
      user_id: user.id,
      group_member_id: member.id,
      credit_topup_id: topup.id,
      provider_cost_usd: Decimal.new("4.00")
    })

    assert %{consumed_micro: 4_000_000} = topup_counter(topup.id)

    Topups.delete(topup)

    assert topup_counter(topup.id) == nil

    assert Repo.aggregate(
             from(l in "request_logs", where: l.credit_topup_id == type(^topup.id, :binary_id)),
             :count
           ) == 1
  end

  # ── El bug de dinero, cerrado ────────────────────────────────────────────
  # `consumed_usd/1` sumaba los logs crudos. `request_logs` conserva 90 días, así
  # que un top-up sin expiración más viejo que la retención perdía sus débitos con
  # las particiones: el remanente volvía a subir y el sujeto recuperaba crédito ya
  # gastado. El contador durable no se poda con los logs.
  test "un top-up longevo no recupera crédito cuando la retención borra sus logs" do
    user = insert_user!()
    member = insert_member!(user)
    topup = insert_topup!(user)

    old_day = Date.add(Date.utc_today(), -120)
    {_, _} = PartitionWorker.ensure_partition(old_day)

    old_at = DateTime.new!(old_day, ~T[12:00:00], "Etc/UTC")

    log!(%{
      user_id: user.id,
      group_member_id: member.id,
      credit_topup_id: topup.id,
      inserted_at: old_at,
      provider_cost_usd: Decimal.new("4.00")
    })

    assert Decimal.equal?(Topups.consumed_usd(topup), Decimal.new("4.00"))
    assert Decimal.equal?(Topups.remaining_usd(topup), Decimal.new("6.00"))
    assert Topups.grants_credit?(topup)

    # La retención dropea la partición vieja (el cron diario hace exactamente
    # esto con todo lo que pasa de 90 días).
    {:ok, dropped} = PartitionWorker.cleanup_old_partitions(90)
    assert PartitionWorker.partition_name(old_day) in dropped

    assert Repo.aggregate(
             from(l in "request_logs", where: l.credit_topup_id == type(^topup.id, :binary_id)),
             :count
           ) == 0

    # El consumo sigue siendo el mismo: el crédito ya gastado NO resucita.
    assert Decimal.equal?(Topups.consumed_usd(topup), Decimal.new("4.00"))
    assert Decimal.equal?(Topups.remaining_usd(topup), Decimal.new("6.00"))
  end

  # Paridad exacta, en micro-USD enteros: el contador es el mismo número que la
  # query de agregación sobre los logs (que es lo que permite repararlo y
  # auditarlo), sin tolerancia de redondeo.
  test "the counter equals the raw aggregate, exactly" do
    user = insert_user!()
    service = insert_service!()
    member = insert_member!(user)
    topup = insert_topup!(user)

    costs = ["0.123456", "1.500000", "0.000001", "7.250000", "0"]

    for cost <- costs do
      log!(%{
        user_id: user.id,
        group_member_id: member.id,
        service_id: service.id,
        credit_topup_id: if(cost in ["1.500000", "0.000001"], do: topup.id),
        provider_cost_usd: Decimal.new(cost),
        status_code: if(cost == "0", do: 402, else: 200)
      })
    end

    raw =
      Repo.one(
        from(l in "request_logs",
          where: l.user_id == type(^user.id, :binary_id),
          select: %{
            requests: count(l.id),
            errors: filter(count(l.id), l.status_code >= 400),
            spend_micro:
              fragment("COALESCE(SUM(ROUND(? * 1000000)), 0)::bigint", l.provider_cost_usd),
            limit_spend_micro:
              fragment(
                "COALESCE(SUM(ROUND(? * 1000000)) FILTER (WHERE ? IS NULL), 0)::bigint",
                l.provider_cost_usd,
                l.credit_topup_id
              )
          }
        )
      )

    counter = user_counter(user.id, Date.utc_today())

    assert counter.request_count == raw.requests
    assert counter.error_count == raw.errors
    assert counter.spend_micro == raw.spend_micro
    assert counter.limit_spend_micro == raw.limit_spend_micro

    # 8.873457 USD en micro, sin pérdida; el top-up acumula 1.500001.
    assert counter.spend_micro == 8_873_457
    assert counter.limit_spend_micro == 7_373_456
    assert topup_counter(topup.id).consumed_micro == 1_500_001
  end

  # La ruta de reparación: `reconcile` detecta el bucket desincronizado y
  # `backfill` lo re-agrega desde los logs (reemplazo idempotente, días cerrados).
  test "reconcile detects a drifted bucket and backfill repairs it" do
    user = insert_user!()
    member = insert_member!(user)
    yesterday = Date.add(Date.utc_today(), -1)
    at = DateTime.new!(yesterday, ~T[10:00:00], "Etc/UTC")

    log!(%{
      user_id: user.id,
      group_member_id: member.id,
      inserted_at: at,
      provider_cost_usd: Decimal.new("2.00")
    })

    # Drift simulado: el contador del día cerrado perdió el gasto (un restore, un
    # DELETE manual sobre la tabla derivada). Lo que un JOIN simple no vería es el
    # bucket que falta del todo, por eso el reconcile es FULL OUTER.
    Repo.query!("UPDATE consumption_counters SET spend_micro = 0 WHERE user_id = $1", [
      Ecto.UUID.dump!(user.id)
    ])

    assert [%{counter_micro: 0, raw_micro: 2_000_000, day: ^yesterday}] =
             ConsumptionCounters.mismatches(:user)

    {:ok, _} = ConsumptionCounters.backfill()

    assert ConsumptionCounters.mismatches(:user) == []
    assert %{spend_micro: 2_000_000} = user_counter(user.id, yesterday)
  end

  # ── Los totales lifetime leen el contador, no las particiones ────────────
  # `total_spend_by_user/0` y `total_spend_by_service/1` sumaban todas las
  # particiones retenidas; con el contador son un rango de índice, y el
  # "total" sigue siendo lifetime cuando la retención borra días viejos.
  test "los totales lifetime salen del contador y no de request_logs" do
    user = insert_user!()
    service = insert_service!()
    member = insert_member!(user)

    log!(%{
      user_id: user.id,
      group_member_id: member.id,
      service_id: service.id,
      provider_cost_usd: Decimal.new("2.50")
    })

    log!(%{
      user_id: user.id,
      group_member_id: member.id,
      service_id: service.id,
      inserted_at: DateTime.new!(Date.add(Date.utc_today(), -3), ~T[09:00:00], "Etc/UTC"),
      provider_cost_usd: Decimal.new("1.25")
    })

    assert Decimal.equal?(Map.fetch!(Logs.total_spend_by_user(), user.id), Decimal.new("3.75"))

    assert Decimal.equal?(
             Map.fetch!(Logs.total_spend_by_service(), service.id),
             Decimal.new("3.75")
           )

    # Ni una query contra request_logs: el total sale del contador.
    assert count_queries("request_logs", fn -> Logs.total_spend_by_user() end) == 0
    assert count_queries("request_logs", fn -> Logs.total_spend_by_service() end) == 0
    assert count_queries("consumption_counters", fn -> Logs.total_spend_by_user() end) >= 1
  end

  test "una ventana explícita de total por servicio sigue siendo exacta" do
    service = insert_service!()
    user = insert_user!()
    member = insert_member!(user)

    recent = DateTime.utc_now() |> DateTime.truncate(:second)
    old = DateTime.new!(Date.add(Date.utc_today(), -10), ~T[09:00:00], "Etc/UTC")

    for {at, cost} <- [{recent, "4.00"}, {old, "1.00"}] do
      log!(%{
        user_id: user.id,
        group_member_id: member.id,
        service_id: service.id,
        inserted_at: at,
        provider_cost_usd: Decimal.new(cost)
      })
    end

    from = DateTime.add(recent, -3600, :second)
    windowed = Logs.total_spend_by_service(from: from)

    # La ventana excluye el día viejo; el contador es diario, así que una ventana
    # con borde intradía NO puede servirse de él.
    assert Decimal.equal?(Map.fetch!(windowed, service.id), Decimal.new("4.00"))

    assert Decimal.equal?(
             Map.fetch!(Logs.total_spend_by_service(), service.id),
             Decimal.new("5.00")
           )
  end

  # El total sobrevive a la retención: el día viejo se va con su partición y el
  # contador (que no se poda) sigue contándolo.
  test "el total lifetime no baja cuando la retención borra el día" do
    user = insert_user!()
    member = insert_member!(user)

    old_day = Date.add(Date.utc_today(), -120)
    {:ok, _} = PartitionWorker.ensure_partition(old_day)

    log!(%{
      user_id: user.id,
      group_member_id: member.id,
      inserted_at: DateTime.new!(old_day, ~T[08:00:00], "Etc/UTC"),
      provider_cost_usd: Decimal.new("6.00")
    })

    assert Decimal.equal?(Map.fetch!(Logs.total_spend_by_user(), user.id), Decimal.new("6.00"))

    {:ok, dropped} = PartitionWorker.cleanup_old_partitions(90)
    assert PartitionWorker.partition_name(old_day) in dropped

    assert Decimal.equal?(Map.fetch!(Logs.total_spend_by_user(), user.id), Decimal.new("6.00"))
  end

  defp count_queries(source, fun) do
    counter = :counters.new(1, [:atomics])
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:tokengate, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata[:source] == source, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    :counters.get(counter, 1)
  end

  # ── Regresiones de la auditoría de contadores ────────────────────────────

  # F1 CRÍTICA: `request_logs.credit_topup_id` NO tiene FK (la atribución
  # histórica sobrevive al borrado), pero el contador de top-up sí. Sin el
  # guard, un log tardío contra un top-up borrado abortaba el INSERT del log
  # entero por foreign_key_violation.
  test "un log tardío contra un top-up borrado se persiste (y no crea contador)" do
    user = insert_user!()
    member = insert_member!(user)
    topup = insert_topup!(user)

    {:ok, _} = Topups.delete(topup)

    assert {:ok, log} =
             Logs.log_request(%{
               user_id: user.id,
               group_member_id: member.id,
               credit_topup_id: topup.id,
               model_requested: "gpt-4",
               inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
               subject_type: "user",
               status_code: 200,
               provider_cost_usd: Decimal.new("1.00")
             })

    assert log.credit_topup_id == topup.id
    assert topup_counter(topup.id) == nil
    assert %{spend_micro: 1_000_000} = user_counter(user.id, Date.utc_today())
  end

  test "el backfill no revienta con logs huérfanos de un top-up borrado" do
    user = insert_user!()
    member = insert_member!(user)
    topup = insert_topup!(user)

    log!(%{
      user_id: user.id,
      group_member_id: member.id,
      credit_topup_id: topup.id,
      inserted_at: DateTime.new!(Date.add(Date.utc_today(), -2), ~T[10:00:00], "Etc/UTC"),
      provider_cost_usd: Decimal.new("1.00")
    })

    Repo.delete!(topup)

    assert {:ok, %{user_rows: _}} = ConsumptionCounters.backfill()
    assert topup_counter(topup.id) == nil
  end

  # F2: el bucket de HOY y los días que la retención ya purgó son histórico
  # esperado, no drift. Antes de acotar el CTE cada corrida los reportaba.
  test "reconcile no reporta drift falso por el bucket de hoy" do
    user = insert_user!()
    member = insert_member!(user)
    log!(%{user_id: user.id, group_member_id: member.id, provider_cost_usd: Decimal.new("3.00")})

    assert ConsumptionCounters.mismatches(:user) == []

    assert {:ok, %{user: [], service: [], topups: [], topups_underreported: []}} =
             ConsumptionCounters.reconcile()
  end

  test "reconcile no reporta drift falso por días ya purgados" do
    user = insert_user!()
    member = insert_member!(user)
    old_day = Date.add(Date.utc_today(), -120)
    {:ok, _} = PartitionWorker.ensure_partition(old_day)

    log!(%{
      user_id: user.id,
      group_member_id: member.id,
      inserted_at: DateTime.new!(old_day, ~T[08:00:00], "Etc/UTC"),
      provider_cost_usd: Decimal.new("6.00")
    })

    {:ok, _dropped} = PartitionWorker.cleanup_old_partitions(90)

    # El contador conserva el día; el raw ya no lo tiene. Eso no es drift.
    assert ConsumptionCounters.mismatches(:user) == []
    assert Decimal.equal?(Map.fetch!(Logs.total_spend_by_user(), user.id), Decimal.new("6.00"))
  end

  # F5: la columna que gobierna el cap mensual y el contador de errores también
  # se comparan; antes un drift ahí era invisible para `reconcile`.
  test "reconcile detecta drift en error_count" do
    user = insert_user!()
    member = insert_member!(user)
    yesterday = Date.add(Date.utc_today(), -1)

    log!(%{
      user_id: user.id,
      group_member_id: member.id,
      inserted_at: DateTime.new!(yesterday, ~T[10:00:00], "Etc/UTC"),
      status_code: 500,
      provider_cost_usd: Decimal.new("1.00")
    })

    Repo.query!("UPDATE consumption_counters SET error_count = 0 WHERE user_id = $1", [
      Ecto.UUID.dump!(user.id)
    ])

    assert [%{counter_errors: 0, raw_errors: 1, day: ^yesterday}] =
             ConsumptionCounters.mismatches(:user)
  end

  test "topup_mismatches detecta un contador de top-up desincronizado" do
    user = insert_user!()
    member = insert_member!(user)
    topup = insert_topup!(user)

    log!(%{
      user_id: user.id,
      group_member_id: member.id,
      credit_topup_id: topup.id,
      inserted_at: DateTime.new!(Date.add(Date.utc_today(), -1), ~T[10:00:00], "Etc/UTC"),
      provider_cost_usd: Decimal.new("2.00")
    })

    assert ConsumptionCounters.topup_mismatches() == []

    Repo.query!("UPDATE topup_consumption_counters SET consumed_micro = 0 WHERE topup_id = $1", [
      Ecto.UUID.dump!(topup.id)
    ])

    assert [%{topup_id: topup_id, counter_micro: 0, raw_micro: 2_000_000}] =
             ConsumptionCounters.topup_mismatches()

    assert topup_id == topup.id
    # Y la invariante dura: un contador por debajo de sus logs, para top-ups de
    # cualquier edad.
    assert [%{topup_id: ^topup_id}] = ConsumptionCounters.topup_underreported()
  end

  # F3: el backfill es monótono — una snapshot vieja no puede borrar el gasto de
  # una fila que llegó tarde al día ya cerrado.
  test "el backfill nunca baja un bucket (fila tardía sobrevive)" do
    user = insert_user!()
    member = insert_member!(user)
    yesterday = Date.add(Date.utc_today(), -1)

    log!(%{
      user_id: user.id,
      group_member_id: member.id,
      inserted_at: DateTime.new!(yesterday, ~T[10:00:00], "Etc/UTC"),
      provider_cost_usd: Decimal.new("1.00")
    })

    {:ok, _} = ConsumptionCounters.backfill()
    assert %{spend_micro: 1_000_000} = user_counter(user.id, yesterday)

    # Fila tardía: llega después del backfill pero pertenece al día cerrado.
    log!(%{
      user_id: user.id,
      group_member_id: member.id,
      inserted_at: DateTime.new!(yesterday, ~T[23:59:50], "Etc/UTC"),
      provider_cost_usd: Decimal.new("2.00")
    })

    assert %{spend_micro: 3_000_000} = user_counter(user.id, yesterday)

    # Un backfill posterior NO puede ignorar ni pisar ese bump.
    {:ok, _} = ConsumptionCounters.backfill()
    assert %{spend_micro: 3_000_000} = user_counter(user.id, yesterday)
    assert ConsumptionCounters.mismatches(:user) == []
  end

  test "un costo NULL cuenta como cero y no rompe la paridad" do
    user = insert_user!()
    member = insert_member!(user)
    yesterday = Date.add(Date.utc_today(), -1)

    log!(%{
      user_id: user.id,
      group_member_id: member.id,
      inserted_at: DateTime.new!(yesterday, ~T[10:00:00], "Etc/UTC"),
      provider_cost_usd: nil
    })

    assert %{spend_micro: 0, limit_spend_micro: 0, request_count: 1} =
             user_counter(user.id, yesterday)

    assert ConsumptionCounters.mismatches(:user) == []
  end
end
