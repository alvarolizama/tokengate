defmodule Tokengate.ReleaseRollupBackfillTest do
  @moduledoc """
  Formato de fecha compartido por `bin/rollup-backfill` (env vars
  `ROLLUP_BACKFILL_FROM` / `_TO`) y `mix tokengate.rollup.backfill --from/--to`:
  los dos entran por `Tokengate.Release.parse_datetime!/2`, así que una fecha
  aceptada (o rechazada) lo es por igual en la tarea y en el release.
  """

  use ExUnit.Case, async: true

  alias Tokengate.Release

  test "acepta YYYY-MM-DD como 00:00 UTC" do
    assert Release.parse_datetime!("--from", "2026-09-01") ==
             ~U[2026-09-01 00:00:00Z]
  end

  test "acepta ISO8601 con offset y lo pasa a UTC" do
    assert Release.parse_datetime!("--from", "2026-09-01T12:30:00+02:00") ==
             ~U[2026-09-01 10:30:00Z]
  end

  test "acepta ISO8601 en Z" do
    assert Release.parse_datetime!("ROLLUP_BACKFILL_TO", "2026-09-15T23:59:00Z") ==
             ~U[2026-09-15 23:59:00Z]
  end

  test "una fecha inválida levanta nombrando la variable" do
    assert_raise ArgumentError, ~r/ROLLUP_BACKFILL_FROM/, fn ->
      Release.parse_datetime!("ROLLUP_BACKFILL_FROM", "ayer")
    end
  end
end
