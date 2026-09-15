defmodule Tokengate.PeriodsTest do
  use ExUnit.Case, async: true
  alias Tokengate.Periods

  # America/Mexico_City = UTC-6 fijo (sin DST desde 2022)
  test "start_of_day_utc convierte medianoche local a UTC" do
    {:ok, now} = DateTime.now("America/Mexico_City")
    date = DateTime.to_date(now)

    from = Periods.start_of_day_utc("America/Mexico_City")

    expected =
      DateTime.new!(date, ~T[00:00:00], "America/Mexico_City")
      |> DateTime.shift_zone!("Etc/UTC")

    assert from.zone_abbr == "UTC"
    assert from == expected
    assert DateTime.to_date(DateTime.shift_zone!(from, "America/Mexico_City")) == date
  end

  test "start_of_month_utc usa el mes local" do
    {:ok, now} = DateTime.now("America/Mexico_City")
    first = Date.new!(now.year, now.month, 1)

    from = Periods.start_of_month_utc("America/Mexico_City")
    shifted = DateTime.shift_zone!(from, "America/Mexico_City")
    assert DateTime.to_date(shifted) == first
    assert shifted.hour == 0 and shifted.minute == 0
  end

  test "start_of_n_days_ago_utc(0, tz) == start_of_day_utc(tz)" do
    assert Periods.start_of_n_days_ago_utc(0, "Etc/UTC") == Periods.start_of_day_utc("Etc/UTC")

    assert Periods.start_of_n_days_ago_utc(0, "America/Mexico_City") ==
             Periods.start_of_day_utc("America/Mexico_City")
  end

  test "period_bounds today = día UTC completo hasta now" do
    # "Hoy" mide el día UTC (la ventana que resetea el kill-switch global), no
    # el día local del usuario: por eso `from` es la medianoche UTC aunque el
    # tz sea otro.
    %{from: from, to: to} = Periods.period_bounds("today", "America/Mexico_City")
    assert DateTime.compare(from, to) == :lt
    assert from == Periods.start_of_day_utc("Etc/UTC")

    utc_from = DateTime.shift_zone!(from, "Etc/UTC")
    assert utc_from.hour == 0 and utc_from.minute == 0

    # El tz del usuario NO mueve la ventana de "Hoy"...
    assert from == Periods.period_bounds("today", "Europe/Madrid").from
    # ...pero sí sigue moviendo las ventanas que son de calendario local.
    refute Periods.period_bounds("30d", "Etc/UTC").from ==
             Periods.period_bounds("30d", "America/Mexico_City").from

    # to == now UTC truncado
    assert DateTime.diff(to, DateTime.utc_now() |> DateTime.truncate(:second)) in -2..2
  end

  test "period_bounds 30d = start of local day -29 días" do
    %{from: from} = Periods.period_bounds("30d", "America/Mexico_City")

    day =
      Periods.start_of_day_utc("America/Mexico_City")
      |> DateTime.to_date()
      |> Date.add(-29)

    expected =
      DateTime.new!(day, ~T[00:00:00], "America/Mexico_City")
      |> DateTime.shift_zone!("Etc/UTC")

    assert from == expected
  end

  test "period_bounds month = start of UTC month" do
    # "Este mes" mide el mes UTC — la ventana en que resetea el presupuesto
    # mensual de cada sujeto (Budgets.Manager), igual que "Hoy" con el día.
    %{from: from} = Periods.period_bounds("month", "America/Mexico_City")
    assert from == Periods.start_of_month_utc("Etc/UTC")

    # El tz no mueve la ventana mensual...
    assert from == Periods.period_bounds("month", "Europe/Madrid").from
    # ...pero sí las que siguen siendo de calendario local.
    assert Periods.period_bounds("week", "Etc/UTC").from !=
             Periods.period_bounds("week", "America/Mexico_City").from
  end

  test "local_day_range devuelve start y start+24h" do
    %{from: from, to: to} = Periods.local_day_range("America/Mexico_City")
    assert DateTime.diff(to, from, :second) == 86_400
  end

  test "local_today devuelve la fecha local" do
    {:ok, now} = DateTime.now("America/Mexico_City")
    assert Periods.local_today("America/Mexico_City") == DateTime.to_date(now)
  end

  test "next_utc_day_start es la próxima medianoche UTC" do
    now = ~U[2026-09-15 13:45:12Z]
    reset = Periods.next_utc_day_start(now)

    assert reset == ~U[2026-09-16 00:00:00Z]
    assert reset.zone_abbr == "UTC"
    assert DateTime.diff(reset, now, :second) == 36_888
  end

  test "next_utc_day_start a medianoche ya apunta al día siguiente" do
    # No devuelve el mismo instante: la frontera de hoy ya pasó.
    assert Periods.next_utc_day_start(~U[2026-09-15 00:00:00Z]) == ~U[2026-09-16 00:00:00Z]
  end

  test "next_utc_day_start cierra el día que abre utc_day_start" do
    start = Tokengate.Budgets.Manager.utc_day_start()
    reset = Periods.next_utc_day_start()

    assert DateTime.compare(reset, start) == :gt
    assert DateTime.diff(reset, start, :second) in 86_399..86_401
  end
end
