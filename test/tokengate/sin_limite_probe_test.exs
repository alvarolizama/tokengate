defmodule Tokengate.SinLimiteProbeTest do
  @moduledoc """
  PROBE TEMPORAL (no forma parte de la suite) — qué significa exactamente
  «sin límite» en usuarios y en servicios.

  Recorre la matriz de estados (límite nil / 0 / N / agotado, con y sin
  top-up, ilimitado propio vs heredado) y mide, contra el motor real, qué
  pasa en un request de $0.01:

    * `plan/1`         → `limit_usd`, `unlimited?`
    * `summary/2`      → `has_path?` (¿queda algún camino de gasto?)
    * `reserve_plan/4` → `{:ok, hold}` o `{:error, {:budget_exceeded, %{layer:}}}`

  `layer: :no_credit` = bloqueado de verdad (402); `:subject` = el límite era
  0/agotado y tampoco hay top-up; `:global` = cap global diario.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.{Accounts, Credits, Logs}
  alias Tokengate.Accounts.GroupMember
  alias Tokengate.Budgets.Manager

  @cost Decimal.new("0.01")

  setup do
    pid = Process.whereis(Manager) || start_supervised!(Manager)
    _ = :sys.get_state(pid)
    :ets.delete_all_objects(:tokengate_credits)
    :ok
  end

  defp user_fixture(attrs \\ %{}) do
    {spend, rest} =
      Map.split(attrs, [
        "monthly_spend_limit_usd",
        "unlimited_spend",
        :monthly_spend_limit_usd,
        :unlimited_spend
      ])

    {:ok, user} =
      Accounts.register_user(
        Map.merge(
          %{
            "email" => "u#{System.unique_integer([:positive])}@example.com",
            "name" => "Probe",
            "password" => "ValidPassword123"
          },
          rest
        )
      )

    if map_size(spend) == 0 do
      user
    else
      {:ok, updated} = Accounts.update_user(user, spend)
      updated
    end
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

  defp topup_user(user, amount) do
    {:ok, _} = Credits.Topups.create(%{"user_id" => user.id, "amount_usd" => amount})
  end

  defp topup_service(service, amount) do
    {:ok, _} = Credits.Topups.create(%{"service_id" => service.id, "amount_usd" => amount})
  end

  # Gasto asentado en la verdad durable (request_logs), con `user_id` explícito.
  defp spend_log(member, user, cost) do
    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member.id,
        user_id: user.id,
        subject_type: "user",
        model_requested: "probe-model",
        provider_cost_usd: to_string(cost)
      })

    :ok
  end

  # Plan del usuario SIN membresía: es exactamente el cuerpo de
  # `Credits.plan_for_user/1` (privado), el camino que la regla 3 pone en duda.
  defp plan_without_sub(user) do
    limit = Credits.user_limit(user, nil)

    %{
      subject: {:user, user.id},
      limit_usd: limit.limit_usd,
      unlimited?: limit.unlimited?,
      topups: Credits.Topups.draining_order({:user, user.id})
    }
  end

  defp measure(label, plan) do
    # El ETS se vacía para forzar la siembra desde la verdad durable.
    :ets.delete_all_objects(:tokengate_credits)
    summary = Credits.summary(plan.subject, plan)

    :ets.delete_all_objects(:tokengate_credits)
    libre = describe(Manager.reserve_plan(plan, nil, @cost, false))

    :ets.delete_all_objects(:tokengate_credits)
    topado = describe(Manager.reserve_plan(plan, Decimal.new("0"), @cost, false))

    IO.puts(
      "#{String.pad_trailing(label, 42)} " <>
        "limit=#{String.pad_trailing(inspect(plan.limit_usd && Decimal.to_string(plan.limit_usd)), 8)} " <>
        "unlimited?=#{String.pad_trailing(to_string(plan.unlimited?), 5)} " <>
        "topups=#{length(plan.topups)} " <>
        "has_path?=#{String.pad_trailing(to_string(summary.has_path?), 5)} " <>
        "→ cap global nil: #{String.pad_trailing(libre, 12)} · cap global 0: #{topado}"
    )
  end

  defp describe({:ok, hold}), do: "OK(#{hold.kind})"
  defp describe({:error, {:budget_exceeded, %{layer: layer}}}), do: "402 #{layer}"

  # ---------------------------------------------------------------------------

  test "matriz completa: qué hace el motor en cada estado de «sin límite»" do
    IO.puts("\n================ USUARIO ================")

    user_no_sub = user_fixture()
    measure("U · SIN sub, sin nada", plan_without_sub(user_no_sub))

    user_no_sub_topup = user_fixture()
    topup_user(user_no_sub_topup, "10.00")
    measure("U · SIN sub + top-up 10", plan_without_sub(user_no_sub_topup))

    user_no_sub_unl = user_fixture(%{"unlimited_spend" => true})
    measure("U · SIN sub + unlimited propio", plan_without_sub(user_no_sub_unl))

    user_no_sub_limit = user_fixture(%{"monthly_spend_limit_usd" => "100.00"})
    measure("U · SIN sub + límite propio 100", plan_without_sub(user_no_sub_limit))

    # --- con sub (perfil de límites) ---
    member = fn attrs -> member_fixture(group_fixture(attrs), user_fixture()) end

    measure("U · sub SIN límite (nil), sin top-up", Credits.plan(member.(%{})))

    m = member.(%{})
    topup_user(Repo.get!(Tokengate.Accounts.User, m.user_id), "10.00")
    measure("U · sub SIN límite (nil) + top-up 10", Credits.plan(m))

    measure(
      "U · sub límite 0, sin top-up",
      Credits.plan(member.(%{"monthly_spend_limit_usd" => "0"}))
    )

    m = member.(%{"monthly_spend_limit_usd" => "0"})
    topup_user(Repo.get!(Tokengate.Accounts.User, m.user_id), "10.00")
    measure("U · sub límite 0 + top-up 10", Credits.plan(m))

    measure(
      "U · sub límite 50, sin top-up",
      Credits.plan(member.(%{"monthly_spend_limit_usd" => "50.00"}))
    )

    m = member.(%{"monthly_spend_limit_usd" => "50.00"})
    user = Repo.get!(Tokengate.Accounts.User, m.user_id)
    spend_log(m, user, "50.00")
    measure("U · sub límite 50 AGOTADO, sin top-up", Credits.plan(m))

    topup_user(user, "10.00")
    measure("U · sub límite 50 AGOTADO + top-up 10", Credits.plan(m))

    measure(
      "U · sub ilimitada (heredada)",
      Credits.plan(member.(%{"unlimited_spend" => true}))
    )

    m = member.(%{"unlimited_spend" => true})
    topup_user(Repo.get!(Tokengate.Accounts.User, m.user_id), "10.00")
    measure("U · sub ilimitada + top-up 10", Credits.plan(m))

    IO.puts("\n================ SERVICIO ================")

    measure("S · SIN límite (nil), sin top-up", Credits.plan(service_fixture()))

    s = service_fixture()
    topup_service(s, "10.00")
    measure("S · SIN límite (nil) + top-up 10", Credits.plan(s))

    measure(
      "S · límite 0, sin top-up",
      Credits.plan(service_fixture(%{"monthly_spend_limit_usd" => "0"}))
    )

    s = service_fixture(%{"monthly_spend_limit_usd" => "0"})
    topup_service(s, "10.00")
    measure("S · límite 0 + top-up 10", Credits.plan(s))

    measure("S · ilimitado propio", Credits.plan(service_fixture(%{"unlimited_spend" => true})))

    measure(
      "S · límite 50, sin top-up",
      Credits.plan(service_fixture(%{"monthly_spend_limit_usd" => "50.00"}))
    )
  end

  test "las invariantes que afirma la respuesta" do
    # 1. Sin límite (nil) y sin top-up: NO hay camino de gasto. Ésa es la
    #    única lectura correcta de «Sin límite» en el motor.
    user = user_fixture()
    plan = plan_without_sub(user)

    assert plan.limit_usd == nil
    refute plan.unlimited?
    assert Credits.summary(plan.subject, plan).has_path? == false

    assert {:error, {:budget_exceeded, %{layer: :no_credit}}} =
             Manager.reserve_plan(plan, nil, @cost, false)

    # 2. El mismo usuario con top-up: hay crédito. «Solo top-ups» = camino sí.
    topup_user(user, "10.00")
    plan = plan_without_sub(user)
    assert Credits.summary(plan.subject, plan).has_path?
    assert {:ok, %{kind: :topup}} = Manager.reserve_plan(plan, nil, @cost, false)

    # 3. Ilimitado NO es «sin techo»: el cap global diario lo sigue topando.
    member = member_fixture(group_fixture(%{"unlimited_spend" => true}), user_fixture())
    plan = Credits.plan(member)

    assert plan.unlimited?
    assert {:ok, _} = Manager.reserve_plan(plan, nil, @cost, false)

    assert {:error, {:budget_exceeded, %{layer: :global}}} =
             Manager.reserve_plan(plan, Decimal.new("0"), @cost, false)

    # 4. «Límite 0» no es ilimitado ni es «sin límite»: es CERO.
    m = member_fixture(group_fixture(%{"monthly_spend_limit_usd" => "0"}), user_fixture())
    plan = Credits.plan(m)

    assert Decimal.equal?(plan.limit_usd, Decimal.new("0"))
    refute plan.unlimited?

    assert {:error, {:budget_exceeded, %{layer: :subject}}} =
             Manager.reserve_plan(plan, nil, @cost, false)

    # 5. Un servicio sin límite se comporta igual que un usuario sin sub:
    #    nil ⇒ solo top-ups.
    service = service_fixture()
    plan = Credits.plan(service)
    assert plan.limit_usd == nil

    assert {:error, {:budget_exceeded, %{layer: :no_credit}}} =
             Manager.reserve_plan(plan, nil, @cost, false)

    topup_service(service, "10.00")
    plan = Credits.plan(service)
    assert {:ok, %{kind: :topup}} = Manager.reserve_plan(plan, nil, @cost, false)

    # 6. Un `%GroupMember{}` sin perfil de límites también resuelve (la resolución del
    #    motor es user primero; lo que falta es la membresía para autenticar).
    assert %{limit_usd: nil, unlimited?: false, source: nil} =
             Credits.user_limit(user, nil)

    assert %GroupMember{id: nil} = %GroupMember{}
  end
end
