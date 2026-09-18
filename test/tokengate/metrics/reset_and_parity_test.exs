defmodule Tokengate.Metrics.ResetAndParityTest do
  @moduledoc """
  Dos regresiones de producción:

  1. El botón de reset (Mantenimiento) truncaba `request_logs` pero dejaba
     `request_metrics_hourly` con las sumas viejas → el Resumen híbrido de
     /stats seguía mostrando gasto mientras En vivo (crudo) daba 0.
  2. Paridad En vivo vs Resumen en "hoy": KPIs crudos vs híbrido con el
     rollup poblado deben cuadrar.
  """

  # async: false — flips the global :stats_rollup hybrid flag + truncates.
  use Tokengate.DataCase, async: false

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Metrics.RequestMetricsHourly
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Metrics.Rollup.HourlyAggregate
  alias Tokengate.Metrics.StatsQueries
  alias Tokengate.Repo

  defp user_member_fixture do
    u = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "rst-#{u}@example.com",
        name: "Rst User",
        password: "ValidPassword123"
      })

    {:ok, group} = Accounts.create_group(%{name: "Rst Group #{u}"})
    {:ok, member} = Accounts.create_group_member(%{group_id: group.id, user_id: user.id})

    {user, member}
  end

  defp log_for(member_id, inserted_at, cost) do
    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member_id,
        model_requested: "gpt-4",
        status_code: 200,
        prompt_tokens: 100,
        completion_tokens: 50,
        cost_usd: Decimal.new(cost),
        latency_ms: 500,
        inserted_at: inserted_at
      })
  end

  test "reset deja todo en cero: crudo, rollup y lecturas híbridas" do
    {user, member} = user_member_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Gasto en la parte vieja del día (rollup) y en la cola fresca (crudo).
    old_hour = now |> DateTime.add(-2 * 3600, :second) |> floor_hour()
    log_for(member.id, old_hour, "2.000000")
    log_for(member.id, now, "1.000000")

    hour_end = DateTime.add(old_hour, 3600, :second)
    assert {:ok, _} = HourlyAggregate.aggregate_hours(old_hour, hour_end)

    # Sanity pre-reset: el híbrido ve el gasto completo.
    from = Tokengate.Periods.start_of_day_utc("Etc/UTC")
    pre = StatsQueries.summary(from: from, user_ids: [user.id])
    assert pre.request_count == 2

    # El reset de Mantenimiento.
    assert {0, nil} = Logs.truncate_request_logs()

    # Post-reset: NADA conserva el histórico.
    assert Repo.aggregate(RequestLog, :count, :id) == 0
    assert Repo.aggregate(RequestMetricsHourly, :count, :id) == 0

    post = StatsQueries.summary(from: from, user_ids: [user.id])
    assert post.request_count == 0
    assert Decimal.compare(post.total_cost_usd, Decimal.new(0)) == :eq

    raw = Logs.cost_summary(%{from: from})
    assert raw.request_count == 0

    live = Rollup.breakdown_by_user(from: from)
    assert live == []
  end

  test "reset limpia los bolsines de top-up del ETS (gasto fantasma post-truncate)" do
    {_user, _member} = user_member_fixture()

    # Bolsín con consumo pre-reset: sin clear, `ensure_topup_loaded/1` nunca
    # re-siembra (sólo siembra si la clave no existe) y el enforcement vería
    # gasto que ya no existe en los logs truncados.
    :ets.insert(
      :tokengate_credits,
      {{:topup, "reset-parity-t1"}, 500_000, 1_000_000, nil, true, nil, false}
    )

    assert {0, nil} = Logs.truncate_request_logs()

    assert [] == :ets.lookup(:tokengate_credits, {:topup, "reset-parity-t1"})
  after
    :ets.delete(:tokengate_credits, {:topup, "reset-parity-t1"})
  end

  test "hoy cuadra: híbrido (Resumen) == crudo (En vivo) con rollup poblado" do
    {user, member} = user_member_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    from = Tokengate.Periods.start_of_day_utc("Etc/UTC")

    # 3 logs en horas viejas de hoy (servidas por rollup) + 1 fresco (crudo).
    h1 = from |> DateTime.add(3600, :second) |> floor_hour()
    h2 = from |> DateTime.add(2 * 3600, :second) |> floor_hour()
    log_for(member.id, h1, "1.000000")
    log_for(member.id, h1, "1.500000")
    log_for(member.id, h2, "0.500000")
    log_for(member.id, now, "0.250000")

    assert {:ok, _} = HourlyAggregate.aggregate_hours(from, now)

    hybrid = StatsQueries.summary(from: from, user_ids: [user.id])
    raw = Logs.cost_summary(%{from: from, user_ids: [user.id]})

    assert hybrid.request_count == raw.request_count
    assert Decimal.compare(hybrid.total_cost_usd, raw.total_cost_usd) == :eq
    assert hybrid.request_count == 4
    assert Decimal.compare(hybrid.total_cost_usd, Decimal.new("3.250000")) == :eq
  end

  defp floor_hour(%DateTime{} = dt),
    do: %{dt | minute: 0, second: 0, microsecond: {0, 0}}
end
