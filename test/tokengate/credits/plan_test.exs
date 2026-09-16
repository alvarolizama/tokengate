defmodule Tokengate.Credits.PlanTest do
  @moduledoc """
  Tests del enforcement por **límite del sujeto + top-ups** (W2 del contrato).

  `async: false` — la tabla de crédito es un ETS nombrado (singleton).

  Cubre la precedencia documentada en `Budgets.Manager.reserve_plan/4`:

    1. `unlimited_spend` ⇒ solo cap global;
    2. límite con remanente ⇒ se descuenta del límite;
    3. límite agotado (o `0`) y top-ups vigentes ⇒ drena el que expira antes;
    4. sin límite (`nil`) sin ilimitado ni top-ups ⇒ 402 `:no_credit`.

  Y las ramas `nil`/`0`, que son exactamente donde el modelo viejo se equivocó.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.{Accounts, Credits, Logs}
  alias Tokengate.Budgets.Manager

  setup do
    pid = Process.whereis(Manager) || start_supervised!(Manager)
    _ = :sys.get_state(pid)
    :ets.delete_all_objects(:tokengate_credits)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      Accounts.register_user(
        Map.merge(
          %{
            "email" => "u#{System.unique_integer([:positive])}@example.com",
            "name" => "Test User",
            "password" => "ValidPassword123"
          },
          attrs
        )
      )

    user
  end

  defp group_fixture(attrs \\ %{}) do
    {:ok, group} =
      Accounts.create_group(
        Map.merge(%{"name" => "G#{System.unique_integer([:positive])}"}, attrs)
      )

    group
  end

  defp member_fixture(group, user) do
    {:ok, member} =
      Accounts.create_group_member(%{"user_id" => user.id, "group_id" => group.id})

    Accounts.get_group_member!(member.id)
  end

  defp service_fixture(attrs \\ %{}) do
    {:ok, service} =
      Accounts.create_service(
        Map.merge(%{"name" => "S#{System.unique_integer([:positive])}"}, attrs)
      )

    service
  end

  defp topup_fixture(attrs) do
    {:ok, topup} = Credits.Topups.create(attrs)
    topup
  end

  # Consumo asentado: un request log con su costo, atribuido al top-up o al límite.
  defp log_spend(member, cost_usd, opts \\ []) do
    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member.id,
        subject_type: "user",
        model_requested: "test-model",
        provider_cost_usd: to_string(cost_usd),
        credit_topup_id: Keyword.get(opts, :topup_id)
      })

    :ok
  end

  # ---------------------------------------------------------------------------
  # Límite efectivo: herencia y semántica de 0 / nil
  # ---------------------------------------------------------------------------

  describe "user_limit/1 — el límite efectivo" do
    test "sin límite propio, hereda el del grupo" do
      group = group_fixture(%{"monthly_spend_limit_usd" => "50.00"})
      user = user_fixture()
      member = member_fixture(group, user)

      limit = Credits.user_limit(member)

      assert limit.source == :group
      assert Decimal.equal?(limit.limit_usd, Decimal.new("50.00"))
      refute limit.unlimited?
    end

    test "con límite propio, el suyo gana sobre el del grupo" do
      group = group_fixture(%{"monthly_spend_limit_usd" => "50.00"})
      user = user_fixture(%{"monthly_spend_limit_usd" => "10.00"})
      member = member_fixture(group, user)

      limit = Credits.user_limit(member)

      assert limit.source == :user
      assert Decimal.equal?(limit.limit_usd, Decimal.new("10.00"))
    end

    test "límite 0 del usuario es CERO, no ilimitado" do
      group = group_fixture(%{"monthly_spend_limit_usd" => "50.00"})
      user = user_fixture(%{"monthly_spend_limit_usd" => "0"})
      member = member_fixture(group, user)

      limit = Credits.user_limit(member)

      assert limit.source == :user
      assert Decimal.equal?(limit.limit_usd, Decimal.new("0"))
      refute limit.unlimited?
    end

    test "unlimited_spend del grupo lo heredan sus miembros" do
      group = group_fixture(%{"unlimited_spend" => true})
      user = user_fixture()
      member = member_fixture(group, user)

      limit = Credits.user_limit(member)

      assert limit.unlimited?
      assert limit.source == :group
    end

    test "unlimited_spend propio gana sobre el límite del grupo" do
      group = group_fixture(%{"monthly_spend_limit_usd" => "50.00"})
      user = user_fixture(%{"unlimited_spend" => true})
      member = member_fixture(group, user)

      assert Credits.user_limit(member).unlimited?
    end

    test "sin límite en ninguno de los dos: source nil (solo top-ups)" do
      group = group_fixture()
      user = user_fixture()
      member = member_fixture(group, user)

      limit = Credits.user_limit(member)

      assert limit.source == nil
      assert limit.limit_usd == nil
      refute limit.unlimited?
    end
  end

  # ---------------------------------------------------------------------------
  # Precedencia de la reserva
  # ---------------------------------------------------------------------------

  describe "reserve_plan/4 — precedencia" do
    test "unlimited_spend pasa con cap global y no toca el límite" do
      group = group_fixture(%{"unlimited_spend" => true})
      member = member_fixture(group, user_fixture())
      plan = Credits.plan(member)

      assert {:ok, hold} = Manager.reserve_plan(plan, nil, Decimal.new("5"), false)
      assert hold.kind == :no_credit

      :ok = Manager.release_credits(hold)
    end

    test "límite con remanente: descuenta del límite" do
      group = group_fixture(%{"monthly_spend_limit_usd" => "10.00"})
      member = member_fixture(group, user_fixture())
      plan = Credits.plan(member)

      assert {:ok, hold} = Manager.reserve_plan(plan, nil, Decimal.new("4"), false)
      assert hold.kind == :limit
      assert hold.subject == {:user, member.user_id}

      :ok = Manager.settle_credits(hold, Decimal.new("3"))
    end

    test "límite 0 sin top-up: 402 con capa :subject (cero NO es ilimitado)" do
      group = group_fixture(%{"monthly_spend_limit_usd" => "0"})
      member = member_fixture(group, user_fixture())
      plan = Credits.plan(member)

      assert {:error, {:budget_exceeded, %{layer: :subject}}} =
               Manager.reserve_plan(plan, nil, Decimal.new("1"), false)
    end

    test "sin límite, sin ilimitado y sin top-ups: 402 con capa :no_credit" do
      group = group_fixture()
      member = member_fixture(group, user_fixture())
      plan = Credits.plan(member)

      assert {:error, {:budget_exceeded, %{layer: :no_credit}}} =
               Manager.reserve_plan(plan, nil, Decimal.new("1"), false)
    end

    test "límite agotado y top-up vigente: drena el top-up" do
      group = group_fixture(%{"monthly_spend_limit_usd" => "5.00"})
      user = user_fixture()
      member = member_fixture(group, user)

      # El límite ya está agotado por un request asentado.
      log_spend(member, "5.00")
      :ets.delete_all_objects(:tokengate_credits)

      topup_fixture(%{"user_id" => user.id, "amount_usd" => "20.00", "label" => "rescate"})

      plan = Credits.plan(member)

      assert {:ok, hold} = Manager.reserve_plan(plan, nil, Decimal.new("2"), false)
      assert hold.kind == :topup

      :ok = Manager.settle_credits(hold, Decimal.new("1.5"))
    end

    test "límite agotado sin top-ups: 402 capa :subject" do
      group = group_fixture(%{"monthly_spend_limit_usd" => "5.00"})
      member = member_fixture(group, user_fixture())

      log_spend(member, "5.00")
      :ets.delete_all_objects(:tokengate_credits)

      plan = Credits.plan(member)

      assert {:error, {:budget_exceeded, %{layer: :subject}}} =
               Manager.reserve_plan(plan, nil, Decimal.new("1"), false)
    end
  end

  # ---------------------------------------------------------------------------
  # Top-ups: orden de drenado y vencimiento
  # ---------------------------------------------------------------------------

  describe "Topups.draining_order/1 — primero el que expira antes" do
    test "ordena por expires_at ascendente, los sin expiración al final" do
      user = user_fixture()
      now = DateTime.utc_now()

      _tardio = topup_fixture(%{"user_id" => user.id, "amount_usd" => "10", "expires_at" => DateTime.add(now, 30, :day), "label" => "30d"})
      _temprano = topup_fixture(%{"user_id" => user.id, "amount_usd" => "10", "expires_at" => DateTime.add(now, 2, :day), "label" => "2d"})
      _sin = topup_fixture(%{"user_id" => user.id, "amount_usd" => "10", "label" => "nunca"})

      labels = Credits.Topups.draining_order({:user, user.id}) |> Enum.map(& &1.label)

      assert labels == ["2d", "30d", "nunca"]
    end

    test "un top-up vencido NO está en el orden de drenado y no otorga" do
      user = user_fixture()

      topup =
        topup_fixture(%{
          "user_id" => user.id,
          "amount_usd" => "10",
          "expires_in_days" => 1,
          "expires_at" => DateTime.add(DateTime.utc_now(), -2, :day)
        })

      assert Credits.Topups.draining_order({:user, user.id}) == []
      refute Credits.Topups.grants_credit?(topup)
    end

    test "un top-up sin expiración nunca vence y otorga" do
      user = user_fixture()

      topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "10"})

      assert topup.expires_at == nil
      assert Credits.Topups.grants_credit?(topup)
      assert [_] = Credits.Topups.draining_order({:user, user.id})
    end

    test "el remanente se mide contra los logs atribuidos al top-up" do
      group = group_fixture(%{"unlimited_spend" => true})
      user = user_fixture()
      member = member_fixture(group, user)

      topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "10.00"})

      log_spend(member, "3.00", topup_id: topup.id)

      assert Decimal.equal?(Credits.Topups.consumed_usd(topup), Decimal.new("3.000000"))
      assert Decimal.equal?(Credits.Topups.remaining_usd(topup), Decimal.new("7.000000"))
    end

    test "un top-up agotado deja de otorgar" do
      group = group_fixture(%{"unlimited_spend" => true})
      user = user_fixture()
      member = member_fixture(group, user)

      topup = topup_fixture(%{"user_id" => user.id, "amount_usd" => "2.00"})
      log_spend(member, "2.00", topup_id: topup.id)

      assert Decimal.equal?(Credits.Topups.remaining_usd(topup), Decimal.new("0"))
      refute Credits.Topups.grants_credit?(topup)
    end
  end

  # ---------------------------------------------------------------------------
  # Servicios
  # ---------------------------------------------------------------------------

  describe "service_limit/1 y plan/1 de servicio" do
    test "el servicio con límite propio usa su número" do
      service = service_fixture(%{"monthly_spend_limit_usd" => "80.00"})

      limit = Credits.service_limit(service)

      assert Decimal.equal?(limit.limit_usd, Decimal.new("80.00"))
      refute limit.unlimited?
    end

    test "servicio sin límite ni ilimitado: solo top-ups" do
      service = service_fixture()
      plan = Credits.plan(service)

      assert plan.limit_usd == nil
      refute plan.unlimited?
      assert plan.subject == {:service, service.id}
    end

    test "servicio con top-up gasta aunque no tenga límite" do
      service = service_fixture()
      topup_fixture(%{"service_id" => service.id, "amount_usd" => "25.00"})

      plan = Credits.plan(service)

      assert {:ok, hold} = Manager.reserve_plan(plan, nil, Decimal.new("3"), false)
      assert hold.kind == :topup

      :ok = Manager.release_credits(hold)
    end
  end

  # ---------------------------------------------------------------------------
  # has_path? y display
  # ---------------------------------------------------------------------------

  describe "has_path? y summary" do
    test "summary distingue los tres caminos de gasto" do
      group = group_fixture(%{"monthly_spend_limit_usd" => "20.00"})
      user = user_fixture()
      member = member_fixture(group, user)

      summary = Credits.summary({:user, user.id}, Credits.user_limit(member))

      assert Decimal.equal?(summary.limit_usd, Decimal.new("20.00"))
      assert summary.has_path?
      assert Decimal.equal?(summary.remaining_limit_usd, Decimal.new("20.00"))
    end

    test "sin límite, sin ilimitado y sin top-up: has_path? false (bloqueado)" do
      group = group_fixture()
      user = user_fixture()
      member = member_fixture(group, user)

      summary = Credits.summary({:user, user.id}, Credits.user_limit(member))

      refute summary.has_path?
    end

    test "un top-up le da camino a un sujeto sin límite" do
      group = group_fixture()
      user = user_fixture()
      member = member_fixture(group, user)
      topup_fixture(%{"user_id" => user.id, "amount_usd" => "5.00"})

      summary = Credits.summary({:user, user.id}, Credits.user_limit(member))

      assert summary.has_path?
      assert Decimal.equal?(summary.remaining_topup_usd, Decimal.new("5.000000"))
    end
  end
end
