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

  test "period_bounds today = día local completo hasta now" do
    %{from: from, to: to} = Periods.period_bounds("today", "America/Mexico_City")
    assert DateTime.compare(from, to) == :lt
    local_from = DateTime.shift_zone!(from, "America/Mexico_City")
    assert local_from.hour == 0 and local_from.minute == 0
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

  test "period_bounds month = start of local month" do
    %{from: from} = Periods.period_bounds("month", "America/Mexico_City")
    assert from == Periods.start_of_month_utc("America/Mexico_City")
  end

  test "local_day_range devuelve start y start+24h" do
    %{from: from, to: to} = Periods.local_day_range("America/Mexico_City")
    assert DateTime.diff(to, from, :second) == 86_400
  end

  test "local_today devuelve la fecha local" do
    {:ok, now} = DateTime.now("America/Mexico_City")
    assert Periods.local_today("America/Mexico_City") == DateTime.to_date(now)
  end
end
