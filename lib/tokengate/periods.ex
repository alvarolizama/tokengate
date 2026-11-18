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

  # The ONE period vocabulary every stats surface offers — `StatsHelpers.canonical_periods/0`
  # delegates here so no page can grow its own copy of the list again.
  #
  #   * `"today"`     — open UTC day
  #   * `"yesterday"` — CLOSED UTC day (fixed 24h window)
  #   * `"week"`      — open local-calendar week (Monday → now)
  #   * `"30d"`       — open rolling 30 local days
  @canonical_periods ~w(today yesterday week 30d)
  @default_period "week"

  @doc "Every selectable period, in display order."
  def canonical_periods, do: @canonical_periods

  @doc "The period an out-of-set bookmark degrades to."
  def default_period, do: @default_period

  @doc "True when `period` belongs to the canonical vocabulary."
  def canonical_period?(period), do: period in @canonical_periods

  @doc """
  Casts an arbitrary value into the canonical vocabulary: canonical values pass
  through, anything else (an old `?period=month` bookmark, `"7d"`, a non-binary
  forged param) degrades to `default` instead of raising or being reinterpreted
  as some other window.
  """
  def normalize_period(period, default \\ @default_period) do
    if canonical_period?(period), do: period, else: default
  end

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
  UTC window `%{from: DateTime.t(), to: DateTime.t()}` for a period label:

    * `"today"`     — start of UTC day → now (la ventana que resetea el kill-switch)
    * `"yesterday"` — the CLOSED UTC day before today (fixed 24h, aligned with the
      same UTC-day boundary the kill-switch and the daily budget reset on)
    * `"week"`      — start of local week (Monday) → now
    * `"30d"`       — start of local day 29 days ago → now

  Canonical vocabulary above (`canonical_periods/0`). The remaining clauses are
  legacy window builders kept for the monthly surfaces that later phases migrate
  and for the rollup closed-window tests — they are NOT part of the set any
  page offers, and an unknown label degrades to `default_period/0`:

    * `"month"`      — start of UTC month → now (la ventana que resetea el budget mensual)
    * `"last_month"` — previous UTC calendar month, closed (from → first day of the current month)
    * `"7d"`         — start of local day 6 days ago → now

  Every caller must filter with BOTH bounds (`inserted_at >= from and
  inserted_at <= to`): `"yesterday"`/`"last_month"` are closed windows, and a
  reader that only takes `from` adds the window that follows.
  """
  def period_bounds(period, tz \\ @default_timezone, opts \\ []) do
    # `now` inyectable: previous_period_bounds tiene que poder calcular la
    # ventana previa de una SEMANA FIJA (tests DST deterministas) y las
    # bounds de hoy/mes dependen del instante actual.
    now = opts[:now] || DateTime.now!(tz)
    now_utc = now |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

    this_month_start =
      now_utc |> DateTime.to_date() |> Date.beginning_of_month() |> local_midnight_utc("Etc/UTC")

    # Open (rolling) periods end at `now`; closed calendar periods ("yesterday",
    # "last_month") end at their own boundary.
    {from, to} =
      case period do
        # "Hoy" mide el día UTC — la misma ventana que resetea el kill-switch
        # global (ver Budgets.Manager): KPIs, tope y Mantenimiento tienen que
        # ver el mismo número. La zona del usuario sigue usándose para mostrar
        # horas (distribución por hora, "en tu hora local"), no para windowar.
        "today" ->
          {local_midnight_utc(DateTime.to_date(now_utc), "Etc/UTC"), now_utc}

        # "Ayer" es el día UTC CERRADO anterior: ancla UTC (no la zona del
        # usuario) porque es el mismo calendario con el que resetean el
        # kill-switch y el budget diario. Anclado en UTC mide siempre 24 h —
        # ningún cambio de hora lo alarga ni lo acorta.
        "yesterday" ->
          today_start = local_midnight_utc(DateTime.to_date(now_utc), "Etc/UTC")
          {DateTime.add(today_start, -86_400, :second), today_start}

        "week" ->
          {week_start(now, tz), now_utc}

        # Igual que "today": el mes UTC es la ventana en que resetea el
        # presupuesto mensual de cada sujeto (Budgets.Manager), así que el KPI
        # "Este mes" y los gastos mensuales de Mantenimiento tienen que medir
        # lo mismo que el enforcement.
        "month" ->
          {this_month_start, now_utc}

        # Closed previous calendar month (UTC, same window the monthly budget
        # resets in): from the first day of last month to the first day of
        # this one. Unlike "month" it does not grow, so it is immutable and
        # cache-friendly.
        "last_month" ->
          last_month_start =
            this_month_start
            |> DateTime.to_date()
            |> Date.add(-1)
            |> Date.beginning_of_month()
            |> local_midnight_utc("Etc/UTC")

          {last_month_start, this_month_start}

        "7d" ->
          {local_midnight_utc(Date.add(DateTime.to_date(now), -6), tz), now_utc}

        "30d" ->
          {local_midnight_utc(Date.add(DateTime.to_date(now), -29), tz), now_utc}

        _ ->
          # Bookmark fuera del set (`?period=month` de un link viejo, basura):
          # degrada al periodo por defecto en vez de reinterpretarse como "hoy".
          {week_start(now, tz), now_utc}
      end

    %{from: from, to: to}
  end

  # Monday 00:00 local of the week `now` falls in. Local calendar, not a
  # -168h shift: a week that crosses DST is 167h/169h long and the boundary
  # has to stay on the local Monday.
  defp week_start(now, tz) do
    # Date.day_of_week/1 returns 1=Monday … 7=Sunday
    days_since_monday = Date.day_of_week(DateTime.to_date(now)) - 1
    local_midnight_utc(Date.add(DateTime.to_date(now), -days_since_monday), tz)
  end

  @doc """
  UTC window for the period *before* `period` — the calendar period that
  precedes it (used to compute deltas, e.g. this week vs last week).

    * `"today"`     → the previous complete UTC day
    * `"yesterday"` → the UTC day before it (span shift: same 24h length)
    * `"week"`      → previous week (Mon–Sun, local calendar)
    * `"30d"`       → the 30 days before the last 30 days (span shift)
    * `"month"`     → previous UTC calendar month (same window the budget resets in)
    * `"last_month"` → the UTC calendar month before it
    * `"7d"`        → the 7 days before the last 7 days

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

        # Closed UTC day: the window before it is the UTC day before, same
        # length by construction (UTC has no DST). Span shift, never a
        # calendar shift in a zone that could make it 23h/25h.
        "yesterday" ->
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

        # Closed calendar month: its previous window is the month before it.
        "last_month" ->
          current.from
          |> DateTime.to_date()
          |> Date.add(-1)
          |> Date.beginning_of_month()
          |> local_midnight_utc("Etc/UTC")

        # 30d: span shift — son ventanas rodantes, no calendario.
        _ ->
          DateTime.add(current.from, -DateTime.diff(current.to, current.from, :second), :second)
      end

    %{from: prev_from, to: current.from}
  end

  @doc """
  UTC instant of the *next* 00:00 UTC — the boundary at which the current UTC
  day ends.

  Companion to `Budgets.Manager.utc_day_start/0` (the start of the current
  UTC day): this one is the instant that day ends. Callers that show a "time
  left in the UTC day" figure subtract `now_utc/0` from it; the value is a
  fixed UTC instant, so the remaining *duration* is the same in every
  timezone — only the clock time it lands on depends on the zone.
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
