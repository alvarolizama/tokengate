defmodule Tokengate.Metrics.RollupWindowAlignmentTest do
  @moduledoc """
  El `RollupWorker` re-agrega `[now - 3h, now]` cada 60s — una ventana que
  casi nunca cae en borde de hora. `HourlyAggregate.aggregate_hours/2` tiene
  que pisar `from` al inicio de la hora: si no, el bucket que CONTIENE `from`
  queda fuera del DELETE y dentro del INSERT, el `ON CONFLICT` lo sobreescribe
  con el agregado parcial y, cuando la ventana se desliza, ese parcial queda
  congelado (cada hora del rollup terminaba con ~1 minuto de tráfico).

  Síntoma en producción: Resumen (`/stats/overview`) y dashboard —lecturas
  híbridas rollup + cola cruda— caían contra `/stats` (En vivo) y
  `/budget/global`, que leen `request_logs` crudo.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Metrics.Rollup.HourlyAggregate
  alias Tokengate.Metrics.StatsQueries

  @base_attrs %{
    model_requested: "gpt-4",
    model_responded: "gpt-4-turbo",
    agent_type: "api",
    status_code: 200,
    prompt_tokens: 100,
    completion_tokens: 50,
    cost_usd: Decimal.new("1.000000"),
    latency_ms: 500,
    streaming: false
  }

  setup do
    group = group_fixture()
    user = user_fixture()

    {:ok, group_member} =
      Accounts.create_group_member(%{"group_id" => group.id, "user_id" => user.id})

    {:ok, group_member: group_member}
  end

  defp group_fixture do
    {:ok, group} =
      Accounts.create_group(%{
        "name" => "Platform Group #{System.unique_integer([:positive])}",
        "monthly_budget_per_user_usd" => "100.00",
        "default_concurrency_limit" => 10,
        "default_rpm_limit" => 120
      })

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

  defp log_request(group_member_id, inserted_at) do
    attrs =
      @base_attrs
      |> Map.put(:group_member_id, group_member_id)
      |> Map.put(:inserted_at, inserted_at)

    {:ok, _log} = Logs.log_request(attrs)
    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp floor_hour(%DateTime{} = dt), do: %{dt | minute: 0, second: 0, microsecond: {0, 0}}

  # Un tick del worker, tal cual: ventana de 3h sin alinear.
  defp worker_tick(at) do
    {:ok, _rows} = HourlyAggregate.aggregate_hours(DateTime.add(at, -3 * 3600, :second), at)
    :ok
  end

  test "los ticks no alineados no dejan el bucket de hora a medias", %{group_member: tm} do
    at = now()
    h_start = at |> DateTime.add(-6 * 3600, :second) |> floor_hour()
    h_end = DateTime.add(h_start, 3600, :second)

    # 60 requests, una por minuto, dentro del bucket [h_start, h_start + 1h).
    for m <- 0..59, do: log_request(tm.id, DateTime.add(h_start, m * 60, :second))

    # Los ticks que el worker habría corrido mientras la ventana se deslizaba
    # sobre ese bucket (lo cubre mientras `floor(now - 3h) <= h_start`).
    for k <- 0..80, do: worker_tick(DateTime.add(h_start, 3 * 3600 + k * 60, :second))

    raw = Logs.cost_summary(%{from: h_start, to: h_end})
    rollup = Rollup.summary_from_rollup(from: h_start, to: h_end)

    assert raw.request_count == 60
    assert rollup.request_count == raw.request_count
    assert Decimal.equal?(rollup.total_cost_usd, raw.total_cost_usd)
  end

  test "el summary híbrido coincide con el crudo para la ventana de hoy", %{group_member: tm} do
    at = now()
    day_start = at |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    old_bucket = at |> DateTime.add(-5 * 3600, :second) |> floor_hour()

    # Bucket viejo (más atrás que la cola fresca de 3h → lo sirve el rollup),
    # con tráfico continuo: una request cada 5s, como en producción. La
    # densidad importa: el tick que clobbea deja en el bucket sólo su tramo
    # final, así que sin logs en ese tramo el clobbeo no se ve en el agregado.
    for s <- 0..719, do: log_request(tm.id, DateTime.add(old_bucket, s * 5, :second))

    # ...y tráfico dentro de la cola fresca (lo sirve el crudo).
    log_request(tm.id, DateTime.add(at, -10 * 60, :second))
    log_request(tm.id, DateTime.add(at, -90 * 60, :second))

    # Cada bucket del día recibe su ÚLTIMO tick: el worker corre cada 60s, así
    # que el último que todavía cubre la hora `h_start` cae justo antes de
    # `h_start + 4h` (mientras `floor(t - 3h)` sigue pisando `h_start`). Es el
    # tick que deja congelado el valor del bucket.
    for h <- 0..23 do
      h_start = DateTime.add(day_start, h * 3600, :second)
      last_tick = DateTime.add(h_start, 4 * 3600 - 30, :second)

      if DateTime.compare(last_tick, at) == :lt do
        worker_tick(last_tick)
      end
    end

    previous = Application.get_env(:tokengate, :stats_rollup, hybrid: true)
    Application.put_env(:tokengate, :stats_rollup, hybrid: true)
    on_exit(fn -> Application.put_env(:tokengate, :stats_rollup, previous) end)

    raw = Logs.cost_summary(%{from: day_start, to: at})
    hybrid = StatsQueries.summary(from: day_start, to: at)

    assert hybrid.request_count == raw.request_count
    assert Decimal.equal?(hybrid.total_cost_usd, raw.total_cost_usd)
    assert hybrid.total_prompt_tokens == raw.total_prompt_tokens
    assert hybrid.total_completion_tokens == raw.total_completion_tokens
  end
end
