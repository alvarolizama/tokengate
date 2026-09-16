defmodule Tokengate.Credits.ManagerTest do
  @moduledoc """
  Tests for the credit-grant enforcement added to `Tokengate.Budgets.Manager`:
  reserve → settle against an ordered grant list, tier fallback, and the
  grant state derivation (consumed + rollover).

  `async: false` — the credit table is a named (singleton) ETS table.
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

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "u#{System.unique_integer([:positive])}@example.com",
        "name" => "Test User",
        "password" => "ValidPassword123"
      })

    user
  end

  defp group_fixture do
    {:ok, group} =
      Accounts.create_group(%{"name" => "G#{System.unique_integer([:positive])}"})

    group
  end

  defp member_fixture(group, user) do
    group = group || group_fixture()
    {:ok, member} = Accounts.create_group_member(%{"user_id" => user.id, "group_id" => group.id})
    member
  end

  defp sub_fixture(attrs) do
    {:ok, sub} =
      Credits.create_subscription(
        Map.merge(%{"units" => 100, "recurrence" => "monthly", "reset_day" => 1}, attrs)
      )

    sub
  end

  defp grant(sub, user, tier \\ 1), do: %{subscription: sub, user_id: user.id, tier: tier}

  defp log(member_id, subscription_id, cost_usd, inserted_at \\ nil) do
    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member_id,
        model_requested: "gpt-4",
        inserted_at: inserted_at || DateTime.utc_now() |> DateTime.truncate(:second),
        provider_cost_usd: Decimal.new(cost_usd),
        credit_subscription_id: subscription_id
      })
  end

  describe "reserve_credits/4 + settle_credits/2" do
    test "reserves then settles against the first grant" do
      user = user_fixture()
      _member = member_fixture(nil, user)
      sub = sub_fixture(%{})
      grants = [grant(sub, user)]

      assert {:ok, hold} = Manager.reserve_credits(grants, nil, Decimal.new("5"), false)
      assert hold.kind == :credit
      assert hold.subscription_id == sub.id

      assert :ok = Manager.settle_credits(hold, Decimal.new("3"))

      assert %{consumed_micro: 3_000_000, credited_micro: 100_000_000} =
               Manager.credit_spend(sub.id, user.id)
    end

    test "releases a hold without recording spend" do
      user = user_fixture()
      _member = member_fixture(nil, user)
      sub = sub_fixture(%{})
      grants = [grant(sub, user)]

      assert {:ok, hold} = Manager.reserve_credits(grants, nil, Decimal.new("5"), false)
      assert :ok = Manager.release_credits(hold)

      assert %{consumed_micro: 0} = Manager.credit_spend(sub.id, user.id)
    end

    test "an exhausted grant is rejected" do
      user = user_fixture()
      member = member_fixture(nil, user)
      sub = sub_fixture(%{"units" => 5})
      log(member.id, sub.id, "6")

      assert {:error, {:budget_exceeded, %{layer: :credit}}} =
               Manager.reserve_credits([grant(sub, user)], nil, Decimal.new("1"), false)
    end

    test "no grants -> only the global cap applies (tier 3)" do
      assert {:ok, %{kind: :no_credit, subscription_id: nil}} =
               Manager.reserve_credits([], nil, Decimal.new("1"), false)
    end

    test "falls through to the next grant when the first is exhausted" do
      user = user_fixture()
      member = member_fixture(nil, user)

      group_sub = sub_fixture(%{"units" => 1})
      direct_sub = sub_fixture(%{"units" => 100, "user_id" => user.id, "reset_day" => 15})
      log(member.id, group_sub.id, "2")

      grants = [grant(group_sub, user, 1), grant(direct_sub, user, 2)]

      assert {:ok, hold} = Manager.reserve_credits(grants, nil, Decimal.new("1"), false)
      assert hold.subscription_id == direct_sub.id
    end

    # Regresión: la entrada de ETS de un grant ya sembrado solo se resemilla
    # cuando cambia el ciclo o `units`. Pausar o vencer la sub no cambia
    # ninguno de los dos, así que el proxy seguía gastando el crédito viejo
    # aunque la UI ya mostrara la sub como pausada/vencida — "revocar" no
    # revocaba nada en caliente.
    test "pausar revoca un grant ya sembrado (sin esperar al ciclo)" do
      user = user_fixture()
      _member = member_fixture(nil, user)
      sub = sub_fixture(%{"units" => 100})
      grants = [grant(sub, user)]

      assert {:ok, _hold} = Manager.reserve_credits(grants, nil, Decimal.new("1"), false)
      assert %{credited_micro: 100_000_000} = Manager.credit_spend(sub.id, user.id)

      {:ok, _} = Credits.update_subscription(sub, %{"status" => "paused"})

      assert {:error, {:budget_exceeded, %{layer: :credit}}} =
               Manager.reserve_credits(
                 [grant(%{sub | status: "paused"}, user)],
                 nil,
                 Decimal.new("1"),
                 false
               )
    end

    test "un top-up vencido deja de otorgar aunque ya estuviera sembrado" do
      user = user_fixture()
      _member = member_fixture(nil, user)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      sub =
        sub_fixture(%{
          "units" => 100,
          "recurrence" => "none",
          "reset_day" => nil,
          "starts_at" => DateTime.add(now, -3600, :second),
          "expires_at" => DateTime.add(now, 3600, :second)
        })

      grants = [grant(sub, user)]
      assert {:ok, _hold} = Manager.reserve_credits(grants, nil, Decimal.new("1"), false)

      expired = %{sub | expires_at: DateTime.add(now, -60, :second)}

      assert {:error, {:budget_exceeded, %{layer: :credit}}} =
               Manager.reserve_credits([grant(expired, user)], nil, Decimal.new("1"), false)
    end

    # El flip inverso: si revocar dejaba la entrada sembrada en 0, reactivar la
    # sub tiene que devolver el crédito en caliente (si no, un miembro con
    # suscripción vigente queda bloqueado hasta el próximo cambio de ciclo).
    test "reactivar la sub devuelve el crédito a un grant ya sembrado" do
      user = user_fixture()
      _member = member_fixture(nil, user)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      sub =
        sub_fixture(%{
          "units" => 100,
          "recurrence" => "none",
          "reset_day" => nil,
          "starts_at" => DateTime.add(now, -3600, :second),
          "expires_at" => DateTime.add(now, -60, :second)
        })

      # Sembrado mientras está vencida: 0 crédito.
      assert {:error, {:budget_exceeded, %{layer: :credit}}} =
               Manager.reserve_credits([grant(sub, user)], nil, Decimal.new("1"), false)

      vigente = %{sub | expires_at: DateTime.add(now, 3600, :second)}

      assert {:ok, hold} =
               Manager.reserve_credits([grant(vigente, user)], nil, Decimal.new("1"), false)

      assert hold.subscription_id == sub.id
      assert Manager.credit_spend(sub.id, user.id).credited_micro == 100_000_000
    end

    test "reactivar (pausada -> activa) devuelve el crédito a un grant ya sembrado" do
      user = user_fixture()
      _member = member_fixture(nil, user)
      sub = sub_fixture(%{"units" => 100, "status" => "paused"})
      grants = [grant(sub, user)]

      assert {:error, {:budget_exceeded, %{layer: :credit}}} =
               Manager.reserve_credits(grants, nil, Decimal.new("1"), false)

      {:ok, _} = Credits.update_subscription(sub, %{"status" => "active"})
      active = %{sub | status: "active"}

      assert {:ok, hold} =
               Manager.reserve_credits([grant(active, user)], nil, Decimal.new("1"), false)

      assert hold.subscription_id == sub.id
    end
  end

  describe "Credits.grant_state/2" do
    test "sums the current cycle's settled spend" do
      user = user_fixture()
      member = member_fixture(nil, user)
      sub = sub_fixture(%{"units" => 100})
      log(member.id, sub.id, "30")

      assert %{consumed_micro: 30_000_000, credited_micro: 100_000_000} =
               Credits.grant_state(sub, user.id)
    end

    test "rollover carries a % of the previous cycle's unused base" do
      user = user_fixture()
      member = member_fixture(nil, user)

      sub =
        sub_fixture(%{
          "units" => 100,
          "reset_day" => 1,
          "rollover_mode" => "rollover",
          "rollover_pct" => 50
        })

      # Place 20 of spend in the PREVIOUS cycle (10 days before the current start).
      cur_start = Credits.cycle_bounds(sub, Date.utc_today()).start
      prev_dt = DateTime.new!(Date.add(cur_start, -10), ~T[12:00:00], "Etc/UTC")
      log(member.id, sub.id, "20", prev_dt)

      # unused base = 100 - 20 = 80; carry 50% => 40; credited = 140.
      assert %{credited_micro: 140_000_000, consumed_micro: 0} =
               Credits.grant_state(sub, user.id)
    end

    test "reset rollover does not carry" do
      user = user_fixture()
      member = member_fixture(nil, user)
      sub = sub_fixture(%{"units" => 100, "reset_day" => 1, "rollover_mode" => "reset"})

      cur_start = Credits.cycle_bounds(sub, Date.utc_today()).start
      prev_dt = DateTime.new!(Date.add(cur_start, -10), ~T[12:00:00], "Etc/UTC")
      log(member.id, sub.id, "20", prev_dt)

      assert %{credited_micro: 100_000_000} = Credits.grant_state(sub, user.id)
    end
  end
end
