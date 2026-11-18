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
  alias Tokengate.Metrics.RollupWorker
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

  # -------------------------------------------------------------------------
  # Self-healing (F29) and cadence (F53/F54)
  # -------------------------------------------------------------------------

  describe "RollupWorker self-healing" do
    setup do
      previous = Application.get_env(:tokengate, :stats_rollup, hybrid: true)
      Application.put_env(:tokengate, :stats_rollup, hybrid: true)
      on_exit(fn -> Application.put_env(:tokengate, :stats_rollup, previous) end)
      :ok
    end

    test "a gap bigger than the readers' tail heals at boot and the guard trusts again",
         %{group_member: tm} do
      at = now()
      hour = floor_hour(at)

      # Six closed hours of traffic and an EMPTY rollup: the deploy/OOM hole
      # that used to make every hybrid read fall back to raw forever.
      for h <- 1..6, do: log_request(tm.id, DateTime.add(hour, -h * 3600, :second))

      assert %{last_hour_utc: nil, buckets: 0} = Rollup.coverage()
      assert HourlyAggregate.gap_hours() == :empty

      name = :w10_heal_worker

      start_supervised!({
        RollupWorker,
        # Bounded retention for the fresh-rollup backfill: the test only has
        # today's traffic, there is no reason to walk 90 empty days.
        name: name, enabled: true, interval_ms: 3_600_000, retention_days: 2, boot_backfill: true
      })

      # `handle_continue(:boot)` runs before the GenServer handles any message:
      # this call returns only after the boot backfill finished.
      _ = :sys.get_state(name)

      status = RollupWorker.status(name)
      assert status.last_backfill.status == :backfilled
      assert status.last_backfill.days >= 1

      # The rollup now tracks the newest raw hour.
      assert HourlyAggregate.gap_hours() == 0.0
      assert %{last_hour_utc: %DateTime{}} = Rollup.coverage()

      # The closed span is exactly covered by the rollup (this is the equality
      # `StatsQueries.rollup_trusted?/4` checks)...
      from = DateTime.add(hour, -7 * 3600, :second)
      cutoff = hour

      rollup_half = Rollup.summary_from_rollup(from: from, to: cutoff)
      raw_half = Logs.cost_summary(%{from: from, to: cutoff})
      assert rollup_half.request_count == raw_half.request_count
      assert Decimal.equal?(rollup_half.total_cost_usd, raw_half.total_cost_usd)
      assert rollup_half.request_count == 6

      # ...so the hybrid read serves the same numbers as raw (no silent
      # degradation to a full raw window).
      hybrid = StatsQueries.summary(from: from, to: at)
      raw = Logs.cost_summary(%{from: from, to: at})
      assert hybrid.request_count == raw.request_count
      assert Decimal.equal?(hybrid.total_cost_usd, raw.total_cost_usd)
    end

    test "the periodic refresh rewrites ONLY the tail the readers do not serve" do
      test_pid = self()

      start_supervised!(
        {RollupWorker,
         name: :w10_tail_worker,
         enabled: true,
         boot_backfill: false,
         interval_ms: 3_600_000,
         refresh_fun: fn from, to ->
           send(test_pid, {:refresh_window, from, to})
           {:ok, 0}
         end}
      )

      _ = :sys.get_state(:w10_tail_worker)

      assert {:ok, %{rows: 0}} = RollupWorker.refresh_now(:w10_tail_worker)
      assert_received {:refresh_window, from, to}

      # The window is the last closed hour plus the open one — not the 3-4h the
      # old worker rewrote every 60s and nobody read (readers switch to raw
      # inside the 3h tail).
      assert from == DateTime.add(floor_hour(to), -3600, :second)
      assert DateTime.diff(to, from, :second) <= 2 * 3600
    end

    test "a failing cycle increments the counter, emits the error metric and backs off" do
      test_pid = self()

      :telemetry.attach(
        "w10-rollup-refresh",
        [:tokengate, :rollup, :refresh],
        fn event, measurements, metadata, pid ->
          send(pid, {:rollup_metric, event, measurements, metadata})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach("w10-rollup-refresh") end)

      start_supervised!(
        {RollupWorker,
         name: :w10_fail_worker,
         enabled: true,
         boot_backfill: false,
         interval_ms: 60_000,
         refresh_fun: fn _from, _to -> {:error, :boom} end}
      )

      _ = :sys.get_state(:w10_fail_worker)

      assert {:error, reason} = RollupWorker.refresh_now(:w10_fail_worker)
      assert inspect(reason) =~ "boom"

      status = RollupWorker.status(:w10_fail_worker)
      assert status.consecutive_failures == 1
      assert status.last_error =~ "boom"

      assert_received {:rollup_metric, [:tokengate, :rollup, :refresh], %{rows: 0},
                       %{result: :error, failures: 1}}

      # Backoff grows with the failure count (60s → 120s → … capped at 15min).
      assert RollupWorker.backoff_ms(1) == 60_000
      assert RollupWorker.backoff_ms(2) == 120_000
      assert RollupWorker.backoff_ms(50) == 15 * 60_000
    end

    test "a successful cycle emits the ok metric and resets the counter" do
      test_pid = self()

      :telemetry.attach(
        "w10-rollup-ok",
        [:tokengate, :rollup, :refresh],
        fn event, measurements, metadata, pid ->
          send(pid, {:rollup_metric, event, measurements, metadata})
        end,
        test_pid
      )

      on_exit(fn -> :telemetry.detach("w10-rollup-ok") end)

      start_supervised!(
        {RollupWorker,
         name: :w10_ok_worker,
         enabled: true,
         boot_backfill: false,
         interval_ms: 60_000,
         refresh_fun: fn _from, _to -> {:ok, 3} end}
      )

      _ = :sys.get_state(:w10_ok_worker)

      assert {:ok, %{rows: 3}} = RollupWorker.refresh_now(:w10_ok_worker)
      assert RollupWorker.status(:w10_ok_worker).consecutive_failures == 0

      assert_received {:rollup_metric, [:tokengate, :rollup, :refresh], %{rows: 3},
                       %{result: :ok}}
    end

    test "the tick is scheduled on a fixed period, not after the work" do
      # Same deadline: the next tick is exactly one period later.
      assert RollupWorker.next_deadline(1_000, 900, 60_000) == 1_000
      assert RollupWorker.next_deadline(1_000, 1_000, 60_000) == 61_000

      # A tick that took 500ms still lands on the grid (61_000, not 61_500).
      assert RollupWorker.next_deadline(1_000, 1_500, 60_000) == 61_000

      # A suspended process catches up with ONE tick on the original grid.
      assert RollupWorker.next_deadline(1_000, 200_000, 60_000) == 241_000
    end
  end
end
