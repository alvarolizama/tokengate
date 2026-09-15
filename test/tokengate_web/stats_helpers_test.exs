defmodule TokengateWeb.StatsHelpersTest do
  use ExUnit.Case, async: true

  alias TokengateWeb.StatsHelpers, as: Stats

  describe "countdown_parts/2" do
    test "separa horas y minutos, minutos a dos dígitos" do
      now = ~U[2026-09-15 02:00:00Z]
      assert Stats.countdown_parts(~U[2026-09-15 03:05:00Z], now) == {"1", "05"}
      assert Stats.countdown_parts(~U[2026-09-16 00:00:00Z], now) == {"22", "00"}
    end

    test "redondea hacia arriba a minutos completos" do
      now = ~U[2026-09-15 02:24:49Z]
      assert Stats.countdown_parts(~U[2026-09-15 04:49:00Z], now) == {"2", "25"}
    end

    test "con menos de un minuto restante los minutos son 01, no 00" do
      assert Stats.countdown_parts(~U[2026-09-16 00:00:00Z], ~U[2026-09-15 23:59:30Z]) ==
               {"0", "01"}
    end

    test "instantes pasados o nil rinden {\"0\", \"00\"}" do
      now = ~U[2026-09-15 02:00:00Z]

      assert Stats.countdown_parts(now, now) == {"0", "00"}
      assert Stats.countdown_parts(DateTime.add(now, -100, :second), now) == {"0", "00"}
      assert Stats.countdown_parts(nil, now) == {"0", "00"}
    end
  end

  describe "format_countdown/2" do
    test "une las partes como H:MM" do
      now = ~U[2026-09-15 02:00:00Z]
      assert Stats.format_countdown(~U[2026-09-15 03:05:00Z], now) == "1:05"
      assert Stats.format_countdown(nil, now) == "0:00"
    end

    test "un día completo se lee 24:00" do
      assert Stats.format_countdown(~U[2026-09-16 00:00:00Z], ~U[2026-09-15 00:00:00Z]) ==
               "24:00"
    end

    test "usa la hora actual cuando no se pasa `now`" do
      target = DateTime.add(DateTime.utc_now(), 60, :second)
      assert Stats.format_countdown(target) in ["0:01", "1:00", "1:01"]
    end
  end

  describe "format_time/2" do
    test "rinde HH:MM en la zona pedida" do
      dt = ~U[2026-09-16 00:00:00Z]

      assert Stats.format_time(dt, "Etc/UTC") == "00:00"
      assert Stats.format_time(dt, "America/Merida") == "18:00"
      assert Stats.format_time(dt, "Europe/Madrid") == "02:00"
    end

    test "cae a UTC sin zona o con zona inválida" do
      dt = ~U[2026-09-16 00:00:00Z]

      assert Stats.format_time(dt) == "00:00"
      assert Stats.format_time(dt, "No/Existe") == "00:00"
      assert Stats.format_time(nil, "Etc/UTC") == "—"
    end
  end
end
