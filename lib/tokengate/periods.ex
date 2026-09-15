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

    * `"today"` — start of local day → now
    * `"week"`   — start of local week (Monday) → now
    * `"month"`  — start of UTC month → now
    * `"7d"`     — start of local day 6 days ago → now
    * `"30d"`    — start of local day 29 days ago → now
    * `"90d"`    — start of local day 89 days ago → now
  """
  def period_bounds(period, tz \\ @default_timezone) do
    from =
      case period do
        # "Hoy" mide el día UTC — la misma ventana que resetea el kill-switch
        # global (ver Budgets.Manager): KPIs, tope y Mantenimiento tienen que
        # ver el mismo número. La zona del usuario sigue usándose para mostrar
        # horas (distribución por hora, "en tu hora local"), no para windowar.
        "today" -> start_of_day_utc("Etc/UTC")
        "week" -> start_of_week_utc(tz)
        # Igual que "today": el mes UTC es la ventana en que resetea el
        # presupuesto mensual de cada sujeto (Budgets.Manager), así que el KPI
        # "Este mes" y los gastos mensuales de Mantenimiento tienen que medir
        # lo mismo que el enforcement.
        "month" -> start_of_month_utc("Etc/UTC")
        "7d" -> start_of_n_days_ago_utc(6, tz)
        "30d" -> start_of_n_days_ago_utc(29, tz)
        "90d" -> start_of_n_days_ago_utc(89, tz)
        _ -> start_of_day_utc("Etc/UTC")
      end

    %{from: from, to: now_utc()}
  end

  @doc """
  UTC window for the period *before* `period` — the same span length, shifted
  back in time. Used to compute deltas (e.g. this week vs last week).

    * `"today"` → yesterday
    * `"week"`  → previous week (Mon–Sun)
    * `"month"` → previous calendar month
    * `"7d"`    → the 7 days before the last 7 days
    * `"30d"`   → the 30 days before the last 30 days
    * `"90d"`   → the 90 days before the last 90 days
  """
  def previous_period_bounds(period, tz \\ @default_timezone) do
    current = period_bounds(period, tz)
    span_seconds = DateTime.diff(current.to, current.from, :second)

    prev_to = current.from
    prev_from = DateTime.add(prev_to, -span_seconds, :second)

    %{from: prev_from, to: prev_to}
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
    date
    |> DateTime.new!(~T[00:00:00], tz)
    |> DateTime.shift_zone!("Etc/UTC")
  end
end
