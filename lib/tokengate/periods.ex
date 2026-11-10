defmodule Tokengate.Periods do
  @moduledoc """
  Calendar-period boundaries for timezone-aware metric queries.

  All datetimes are stored in UTC (`:utc_datetime`). These helpers compute
  *local* calendar boundaries (start of day, start of month, start of N days
  ago) and return them as UTC `DateTime`s, so queries keep filtering on the
  `inserted_at` column as-is.

  Timezone strings are IANA names validated by `DateTime.now/1` (via the
  `tz` time zone database configured in config.exs).
  """

  @default_timezone "Etc/UTC"

  @doc "UTC now truncated to the second (the query cutoff used everywhere)."
  def now_utc do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end

  def default_timezone, do: @default_timezone

  @doc "Local calendar date for the given timezone (file names, labels)."
  def local_today(tz \\ @default_timezone) do
    {:ok, now} = DateTime.now(tz)
    DateTime.to_date(now)
  end

  @doc "UTC instant of 00:00:00 local time for `tz` today."
  def start_of_day_utc(tz \\ @default_timezone) do
    {:ok, now} = DateTime.now(tz)
    local_midnight_utc(DateTime.to_date(now), tz)
  end

  @doc "UTC instant of 00:00:00 local time on the 1st of the current local month."
  def start_of_month_utc(tz \\ @default_timezone) do
    {:ok, now} = DateTime.now(tz)
    local_midnight_utc(Date.new!(now.year, now.month, 1), tz)
  end

  @doc "UTC instant of 00:00:00 local time on the Monday of the current local week."
  def start_of_week_utc(tz \\ @default_timezone) do
    {:ok, now} = DateTime.now(tz)
    # Date.day_of_week/1 returns 1=Monday … 7=Sunday
    days_since_monday = Date.day_of_week(DateTime.to_date(now)) - 1
    monday = Date.add(DateTime.to_date(now), -days_since_monday)
    local_midnight_utc(monday, tz)
  end

  @doc "UTC instant of 00:00:00 local time on the 1st of the previous local month."
  def start_of_previous_month_utc(tz \\ @default_timezone) do
    {:ok, now} = DateTime.now(tz)
    first_of_this_month = Date.new!(now.year, now.month, 1)
    last_of_prev = Date.add(first_of_this_month, -1)
    local_midnight_utc(Date.new!(last_of_prev.year, last_of_prev.month, 1), tz)
  end

  @doc "UTC instant of 00:00:00 local time `days` days ago (today = 0)."
  def start_of_n_days_ago_utc(days, tz \\ @default_timezone) do
    {:ok, now} = DateTime.now(tz)
    date = DateTime.to_date(now) |> Date.add(-days)
    local_midnight_utc(date, tz)
  end

  @doc """
  UTC window `%{from: DateTime.t(), to: DateTime.t()}` for a period label,
  using local calendar boundaries:

    * `"today"` — start of UTC day → now (la ventana que resetea el kill-switch)
    * `"week"`   — start of local week (Monday) → now
    * `"month"`  — start of UTC month → now (la ventana que resetea el budget mensual)
    * `"7d"`     — start of local day 6 days ago → now
    * `"30d"`    — start of local day 29 days ago → now
    * `"90d"`    — start of local day 89 days ago → now
  """
  def period_bounds(period, tz \\ @default_timezone, opts \\ []) do
    # `now` inyectable: previous_period_bounds tiene que poder calcular la
    # ventana previa de una SEMANA FIJA (tests DST deterministas) y las
    # bounds de hoy/mes dependen del instante actual.
    now = opts[:now] || DateTime.now!(tz)

    from =
      case period do
        # "Hoy" mide el día UTC — la misma ventana que resetea el kill-switch
        # global (ver Budgets.Manager): KPIs, tope y Mantenimiento tienen que
        # ver el mismo número. La zona del usuario sigue usándose para mostrar
        # horas (distribución por hora, "en tu hora local"), no para windowar.
        "today" ->
          now
          |> DateTime.shift_zone!("Etc/UTC")
          |> DateTime.to_date()
          |> local_midnight_utc("Etc/UTC")

        "week" ->
          # Date.day_of_week/1 returns 1=Monday … 7=Sunday
          days_since_monday = Date.day_of_week(DateTime.to_date(now)) - 1
          local_midnight_utc(Date.add(DateTime.to_date(now), -days_since_monday), tz)

        # Igual que "today": el mes UTC es la ventana en que resetea el
        # presupuesto mensual de cada sujeto (Budgets.Manager), así que el KPI
        # "Este mes" y los gastos mensuales de Mantenimiento tienen que medir
        # lo mismo que el enforcement.
        "month" ->
          now
          |> DateTime.shift_zone!("Etc/UTC")
          |> DateTime.to_date()
          |> Date.beginning_of_month()
          |> local_midnight_utc("Etc/UTC")

        "7d" ->
          local_midnight_utc(Date.add(DateTime.to_date(now), -6), tz)

        "30d" ->
          local_midnight_utc(Date.add(DateTime.to_date(now), -29), tz)

        "90d" ->
          local_midnight_utc(Date.add(DateTime.to_date(now), -89), tz)

        _ ->
          local_midnight_utc(DateTime.to_date(now), "Etc/UTC")
      end

    %{from: from, to: now |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)}
  end

  @doc """
  UTC window for the period *before* `period` — the calendar period that
  precedes it (used to compute deltas, e.g. this week vs last week).

    * `"today"` → the previous complete UTC day
    * `"week"`  → previous week (Mon–Sun, local calendar)
    * `"month"` → previous UTC calendar month (same window the budget resets in)
    * `"7d"`    → the 7 days before the last 7 days (span shift)
    * `"30d"`   → the 30 days before the last 30 days
    * `"90d"`   → the 90 days before the last 90 days

  El `to` del periodo previo es EXCLUSIVO (es el `from` del actual): con
  `>=`/`<` en las queries, un log exactamente en el borde no cuenta doble.
  """
  def previous_period_bounds(period, tz \\ @default_timezone, opts \\ []) do
    now = opts[:now] || DateTime.now!(tz)
    current = period_bounds(period, tz, now: now)

    prev_from =
      case period do
        "today" ->
          DateTime.add(current.from, -86_400, :second)

        "week" ->
          # Calendario local: 7 días NATURALES atrás en la zona del usuario.
          # Un shift absoluto de -168h en una semana que cruza DST aterriza
          # un día antes/tarde localmente y el delta compara 169 h contra
          # 168 h (Santiago, semana del 2026-09-07: 167 h).
          current.from
          |> DateTime.shift_zone!(tz)
          |> DateTime.to_date()
          |> Date.add(-7)
          |> local_midnight_utc(tz)

        "month" ->
          current.from
          |> DateTime.to_date()
          |> Date.beginning_of_month()
          |> Date.add(-1)
          |> Date.beginning_of_month()
          |> local_midnight_utc("Etc/UTC")

        # 30d/90d: span shift — son ventanas rodantes, no calendario.
        _ ->
          DateTime.add(current.from, -DateTime.diff(current.to, current.from, :second), :second)
      end

    %{from: prev_from, to: current.from}
  end

  @doc """
  UTC instant of the *next* 00:00 UTC — the boundary at which the global
  daily kill-switch (`GlobalSettings.daily_max_spend_usd`) resets.

  Companion to `Budgets.Manager.utc_day_start/0` (the start of the current
  UTC day): this one is the instant that day ends. Callers showing a
  "time left until reset" counter use this; the value is a fixed UTC instant,
  so the remaining *duration* is the same in every timezone — only the clock
  time it lands on depends on the zone.
  """
  @spec next_utc_day_start(DateTime.t()) :: DateTime.t()
  def next_utc_day_start(now \\ now_utc()) do
    now
    |> DateTime.to_date()
    |> Date.add(1)
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  @doc "Local day range `%{from: UTC start-of-day, to: UTC start-of-next-day}`."
  def local_day_range(tz \\ @default_timezone) do
    from = start_of_day_utc(tz)
    %{from: from, to: DateTime.add(from, 86_400, :second)}
  end

  defp local_midnight_utc(date, tz) do
    # DST-safe: en zonas con horario de verano la medianoche local puede NO
    # existir (gap, p.ej. America/Santiago 2026-09-06 00:00) o existir dos
    # veces (ambiguous). DateTime.new!/1 revienta en el gap y tumba la carga
    # de stats con un ArgumentError; aquí se resuelve con el primer instante
    # válido del día.
    case DateTime.new(date, ~T[00:00:00], tz) do
      {:ok, dt} -> shift_to_utc(dt)
      {:ambiguous, dt, _later} -> shift_to_utc(dt)
      {:gap, _just_before, just_after} -> shift_to_utc(just_after)
      {:error, reason} -> raise ArgumentError, "invalid midnight for #{tz}: #{inspect(reason)}"
    end
  end

  defp shift_to_utc(dt), do: DateTime.shift_zone!(dt, "Etc/UTC")
end
