defmodule Tokengate.CreditsCountersParityTest do
  @moduledoc """
  Paridad de los agregados de crédito por sujeto: la ruta de
  `consumption_counters` (un renglón por sujeto por día) tiene que devolver
  exactamente lo mismo que el agregado sobre `request_logs` que la precedió.

  El caso importa porque `Credits.spend_and_limit_by_subjects/1` alimenta los
  límites del dashboard y de los listados: un centavo de diferencia ahí es un
  402 o un cobro mal calculado. El log es la referencia; los contadores los
  mantiene el trigger de `request_logs`, así que ambos lados tienen que cuadrar
  al micro-dólar.

  Cubre los dos caminos: contadores poblados (el normal) y el fallback crudo
  (contadores vacíos, p. ej. un deploy sin backfill).
  """

  use Tokengate.DataCase, async: false

  import Ecto.Query

  alias Tokengate.Accounts
  alias Tokengate.Credits
  alias Tokengate.Logs
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Metrics.{ConsumptionCounter, ConsumptionCounters}
  alias Tokengate.Periods
  alias Tokengate.Repo

  @base_attrs %{
    model_requested: "gpt-4",
    status_code: 200,
    prompt_tokens: 10,
    completion_tokens: 5,
    latency_ms: 100,
    streaming: false
  }

  defp user_fixture do
    {:ok, group} =
      Accounts.create_group(%{name: "Parity Group #{System.unique_integer([:positive])}"})

    {:ok, user} =
      Accounts.register_user(%{
        email: "parity-#{System.unique_integer([:positive])}@example.com",
        name: "Parity User",
        password: "ValidPassword123"
      })

    {:ok, member} = Accounts.create_group_member(%{group_id: group.id, user_id: user.id})
    {member, user}
  end

  defp log(member, user, inserted_at, cost, topup_id \\ nil) do
    attrs =
      @base_attrs
      |> Map.put(:group_member_id, member.id)
      |> Map.put(:user_id, user.id)
      |> Map.put(:provider_cost_usd, Decimal.new(cost))
      |> Map.put(:inserted_at, inserted_at)
      |> Map.put(:credit_topup_id, topup_id)

    {:ok, _} = Logs.log_request(attrs)
    :ok
  end

  # Mismo mes, más un renglón del mes pasado que la ventana del ciclo debe
  # excluir. La mitad se debita al límite (sin top-up) y la otra no.
  defp seed_logs(member, user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    this_month = month_start(now)
    last_month = DateTime.add(this_month, -40 * 24 * 3600, :second)
    fake_topup = Ecto.UUID.generate()

    log(member, user, this_month, "0.010000")
    log(member, user, DateTime.add(this_month, 60, :second), "0.002500", fake_topup)
    log(member, user, DateTime.add(this_month, 120, :second), "0.100000")
    # Fuera de la ventana (ciclo anterior).
    log(member, user, last_month, "9.990000")
  end

  # Primer instante del mes en curso, el mismo criterio que `Credits.since/2`
  # (mes calendario UTC).
  defp month_start(now),
    do: %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 0}}

  defp expected_from_logs(user_id) do
    from_month = Periods.start_of_month_utc("Etc/UTC")

    RequestLog
    |> where([rl], rl.user_id == ^user_id and rl.inserted_at >= ^from_month)
    |> select(
      [rl],
      {fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd),
       fragment(
         "COALESCE(SUM(?) FILTER (WHERE ? IS NULL), 0)",
         rl.provider_cost_usd,
         rl.credit_topup_id
       )}
    )
    |> Repo.one()
  end

  test "spend y limit_spend cuadran con los logs, al micro-dólar" do
    {member, user} = user_fixture()
    seed_logs(member, user)

    assert ConsumptionCounters.populated?()

    %{spend: spend, limit_spend: limit_spend} =
      Credits.spend_and_limit_by_subjects([{:user, user.id}])

    {raw_spend, raw_limit} = expected_from_logs(user.id)
    subject = {:user, user.id}

    assert spend[subject] == Decimal.new(to_string(raw_spend))
    assert limit_spend[subject] == Decimal.new(to_string(raw_limit))

    # Los números del fixture: 0.010000 + 0.002500 + 0.100000, y al límite
    # todo menos el renglón con top-up.
    assert spend[subject] == Decimal.new("0.112500")
    assert limit_spend[subject] == Decimal.new("0.110000")
  end

  test "el fallback crudo (contadores vacíos) da el mismo resultado" do
    {member, user} = user_fixture()
    seed_logs(member, user)

    with_counters = Credits.spend_and_limit_by_subjects([{:user, user.id}])

    Repo.delete_all(ConsumptionCounter)
    refute ConsumptionCounters.populated?()

    from_logs = Credits.spend_and_limit_by_subjects([{:user, user.id}])

    assert from_logs == with_counters
  end

  test "un sujeto sin gasto en el ciclo se reporta en cero" do
    {_member, user} = user_fixture()

    %{spend: spend, limit_spend: limit_spend} =
      Credits.spend_and_limit_by_subjects([{:user, user.id}])

    assert spend[{:user, user.id}] == Decimal.new(0)
    assert limit_spend[{:user, user.id}] == Decimal.new(0)
  end

  test "summaries/2 cached: true entrega el mismo crédito que la ruta directa" do
    {member, user} = user_fixture()
    seed_logs(member, user)

    memberships = Accounts.list_group_members_for_user(user.id)

    direct = Credits.summaries(memberships)
    cached = Credits.summaries(memberships, cached: true)

    assert Map.keys(direct) == Map.keys(cached)

    for {id, summary} <- direct do
      assert summary.spend_usd == cached[id].spend_usd
      assert summary.limit_spend_usd == cached[id].limit_spend_usd
      assert summary.remaining_limit_usd == cached[id].remaining_limit_usd
    end
  end
end
