defmodule Tokengate.Metrics.IdentityRotationTest do
  @moduledoc """
  Regresión de identidad durable: el gasto debe seguir atribuido al USUARIO
  (`request_logs.user_id`) cuando su membresía se rota o se borra.

  Este es el bug de producción reportado: el presupuesto del usuario se
  agotó (el motor de créditos debita por `user_id`), pero el dashboard
  scopeaba por las membresías *actuales* y la FK `ON DELETE CASCADE` había
  borrado el histórico — el KPI de costo (y requests/tokens) no cuadraba.
  """

  use Tokengate.DataCase, async: true

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Metrics.Rollup.HourlyAggregate
  alias Tokengate.Metrics.StatsQueries
  alias Tokengate.Repo

  # RequestLog tiene PK compuesta (id + inserted_at): reload! no sirve.
  import Ecto.Query

  defp fetch_log!(log) do
    Repo.one!(
      from rl in RequestLog,
        where: rl.id == ^log.id and rl.inserted_at == ^log.inserted_at
    )
  end

  defp user_member_fixture do
    u = System.unique_integer([:positive])

    {:ok, group} = Accounts.create_group(%{name: "Rot Group #{u}"})

    {:ok, user} =
      Accounts.register_user(%{
        email: "rot-#{u}@example.com",
        name: "Rot User #{u}",
        password: "ValidPassword123"
      })

    {:ok, member} = Accounts.create_group_member(%{group_id: group.id, user_id: user.id})

    {user, member}
  end

  defp log_for(member_id, inserted_at) do
    Logs.log_request(%{
      group_member_id: member_id,
      model_requested: "gpt-4",
      status_code: 200,
      prompt_tokens: 100,
      completion_tokens: 50,
      cost_usd: Decimal.new("1.500000"),
      latency_ms: 500,
      inserted_at: inserted_at
    })
  end

  test "borrar la membresía no borra el log ni el gasto del usuario" do
    {user, member} = user_member_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, log} = log_for(member.id, now)

    # El trigger de 20260917033650 puebla user_id EN LA DB (Repo.insert no
    # refleja mutaciones de trigger en el struct retornado: se relee).
    assert fetch_log!(log).user_id == user.id

    # Rotación: la membresía muere; el log SOBREVIVE (FK SET NULL) y
    # conserva la identidad durable.
    assert {:ok, _} = Accounts.delete_group_member(member)

    surviving = fetch_log!(log)
    assert is_nil(surviving.group_member_id)
    assert surviving.user_id == user.id

    # El KPI del dashboard (StatsQueries, cara cruda en test) sigue
    # contando la request y el costo por usuario.
    from = DateTime.add(now, -3600, :second)

    summary = StatsQueries.summary(from: from, to: nil, user_ids: [user.id])
    assert summary.request_count == 1
    assert Decimal.compare(summary.total_cost_usd, Decimal.new("1.500000")) == :eq

    # La serie horaria por usuario (fallback crudo) mantiene el bucket.
    series = Rollup.hourly_series_for_users([user.id], [from: from], "Etc/UTC")
    assert Enum.map(series, & &1.request_count) |> Enum.sum() == 1

    # El detalle /stats/users/:id (user_stats) también.
    stats = Logs.user_stats(user.id, from: from)
    assert stats.request_count == 1
    assert Decimal.compare(stats.total_cost_usd, Decimal.new("1.500000")) == :eq

    # El ranking de usuarios de /stats NO pierde al rotado.
    rows = Rollup.breakdown_by_user(from: from)
    row = Enum.find(rows, &(&1.user_id == user.id))
    assert row != nil
    assert row.request_count == 1
    assert row.groups == []
  end

  test "el rollup re-agregado lleva la dimensión user_id tras la rotación" do
    {user, member} = user_member_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    hour_start = %{now | minute: 0, second: 0, microsecond: {0, 0}}
    hour_end = DateTime.add(hour_start, 3600, :second)

    {:ok, _log} = log_for(member.id, hour_start)

    # Rotación ANTES de agregar: el bucket debe salir con user_id y
    # group_member_id NULL (antes de esta wave, el upsert viejo habría
    # dejado filas bajo la clave sin usuario).
    assert {:ok, _} = Accounts.delete_group_member(member)

    assert {:ok, _rows} = HourlyAggregate.aggregate_hours(hour_start, hour_end)

    rollup_summary =
      Rollup.summary_from_rollup(from: hour_start, to: hour_end, user_ids: [user.id])

    assert rollup_summary.request_count == 1
    assert Decimal.compare(rollup_summary.total_cost_usd, Decimal.new("1.500000")) == :eq

    # La re-agregación es idempotente: segunda corrida no duplica.
    assert {:ok, _rows} = HourlyAggregate.aggregate_hours(hour_start, hour_end)

    again = Rollup.summary_from_rollup(from: hour_start, to: hour_end, user_ids: [user.id])
    assert again.request_count == 1
  end
end
