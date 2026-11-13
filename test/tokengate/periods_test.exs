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

  # previous_period_bounds: la ventana previa con bordes EXCLUSIVOS (to ==
  # from del actual, un log en el borde no cuenta doble) y calendario local.
  describe "previous_period_bounds" do
    test "today: el día UTC de ayer completo" do
      %{from: from, to: to} = Periods.previous_period_bounds("today", "Etc/UTC")

      assert to == Periods.start_of_day_utc("Etc/UTC")
      assert DateTime.diff(to, from, :second) == 86_400
    end

    test "month: el mes UTC anterior completo" do
      %{from: from, to: to} = Periods.previous_period_bounds("month", "Etc/UTC")

      assert to == Periods.start_of_month_utc("Etc/UTC")
      prev_first = to |> DateTime.add(-1, :day) |> DateTime.to_date() |> Date.beginning_of_month()
      assert DateTime.to_date(from) == prev_first
      assert from.zone_abbr == "UTC"
    end

    test "30d: span shift — mismo largo que la ventana actual, pegado a ella" do
      current = Periods.period_bounds("30d", "Etc/UTC")
      %{from: from, to: to} = Periods.previous_period_bounds("30d", "Etc/UTC")

      # La ventana previa replica el largo de la ACTUAL (que incluye hoy
      # parcial), y termina exactamente donde empieza la actual: borde
      # exclusivo, ningún log cuenta doble.
      assert DateTime.diff(to, from, :second) ==
               DateTime.diff(current.to, current.from, :second)

      assert to == current.from
    end

    test "last_month: mes calendario UTC cerrado y su previo es el mes anterior" do
      current = Periods.period_bounds("last_month", "Etc/UTC")
      this_month = Periods.start_of_month_utc("Etc/UTC")

      assert current.to == this_month
      assert current.from.zone_abbr == "UTC"

      assert DateTime.to_date(current.from) ==
               this_month
               |> DateTime.add(-1, :day)
               |> DateTime.to_date()
               |> Date.beginning_of_month()

      %{from: from, to: to} = Periods.previous_period_bounds("last_month", "Etc/UTC")

      assert to == current.from

      assert DateTime.to_date(from) ==
               current.from
               |> DateTime.add(-1, :day)
               |> DateTime.to_date()
               |> Date.beginning_of_month()
    end

    # La semana del 2026-09-07 cruza el cambio de hora de Chile (2026-09-06,
    # DST): el lunes previo LOCAL está a 167h, no a 168h — un shift absoluto
    # de -168h aterriza domingo 23:00 local y el delta compara 169h vs 168h.
    test "week en Santiago cruzando DST: lunes local a lunes local" do
      monday =
        DateTime.new!(~D[2026-09-07], ~T[12:00:00], "America/Santiago")
        |> DateTime.shift_zone!("Etc/UTC")

      %{from: from, to: to} =
        Periods.previous_period_bounds("week", "America/Santiago", now: monday)

      # El from es medianoche local del lunes 2026-08-31...
      prev_local = DateTime.shift_zone!(from, "America/Santiago")
      assert DateTime.to_date(prev_local) == ~D[2026-08-31]
      assert prev_local.hour == 0
      # ...y la ventana mide la semana LOCAL (167h al cruzar DST), no 168h.
      assert DateTime.diff(to, from, :second) == 167 * 3_600
    end

    test "week sin DST en el camino: lunes local a lunes local, 168h" do
      monday =
        DateTime.new!(~D[2026-11-02], ~T[12:00:00], "America/Santiago")
        |> DateTime.shift_zone!("Etc/UTC")

      %{from: from, to: to} =
        Periods.previous_period_bounds("week", "America/Santiago", now: monday)

      prev_local = DateTime.shift_zone!(from, "America/Santiago")
      assert DateTime.to_date(prev_local) == ~D[2026-10-26]
      assert prev_local.hour == 0
      assert DateTime.diff(to, from, :second) == 168 * 3_600
    end
  end
end
