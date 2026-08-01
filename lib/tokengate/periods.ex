defmodule Tokengate.Periods do
  @moduledoc """
  Calendar-period boundaries for timezone-aware metric queries.

  All datetimes are stored in UTC (`:utc_datetime`). These helpers compute
  *local* calendar boundaries (start of day, start of month, start of N days
  ago) and return them as UTC `DateTime`s, so queries keep filtering on the
  `inserted_at` column as-is.

  Timezone strings are IANA names validated by `DateTime.now/1` (tzdata).
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
    * `"7d"`    — start of local day 6 days ago → now
    * `"30d"`   — start of local day 29 days ago → now
    * `"90d"`   — start of local day 89 days ago → now
    * `"month"` — start of local month → now
  """
  def period_bounds(period, tz \\ @default_timezone) do
    from =
      case period do
        "today" -> start_of_day_utc(tz)
        "7d" -> start_of_n_days_ago_utc(6, tz)
        "30d" -> start_of_n_days_ago_utc(29, tz)
        "90d" -> start_of_n_days_ago_utc(89, tz)
        "month" -> start_of_month_utc(tz)
        _ -> start_of_day_utc(tz)
      end

    %{from: from, to: now_utc()}
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
