defmodule TokengateWeb.TimezoneHelper do
  @moduledoc """
  Shared helpers for timezone-aware date formatting across LiveViews.

  All datetimes in the DB are stored as UTC (`:utc_datetime`).
  These functions shift the datetime to the user's preferred timezone
  before formatting, so the UI always shows local time.

  The timezone comes from `socket.assigns[:timezone]` (set by UserAuth
  on_mount from `user.timezone`). Falls back to `Etc/UTC` when absent.
  """

  @default_timezone "Etc/UTC"
  use Gettext, backend: TokengateWeb.Gettext

  # Curated list of common timezones for the selector.
  # Grouped by region for easier navigation.
  #
  # Las etiquetas van envueltas en gettext_noop/1: el string sale intacto en
  # runtime (se traduce en timezone_options/0) y el extractor lo ve como
  # msgid literal — las entradas del .po sobreviven a extract+merge.
  @timezones [
    {gettext_noop("UTC"),
     [
       {gettext_noop("UTC"), "Etc/UTC"}
     ]},
    {gettext_noop("America"),
     [
       {gettext_noop("Mexico City (CDT)"), "America/Mexico_City"},
       {gettext_noop("Mexico City (CST)"), "America/Merida"},
       {gettext_noop("New York (EST)"), "America/New_York"},
       {gettext_noop("Los Angeles (PST)"), "America/Los_Angeles"},
       {gettext_noop("Chicago (CST)"), "America/Chicago"},
       {gettext_noop("Denver (MST)"), "America/Denver"},
       {gettext_noop("Bogota"), "America/Bogota"},
       {gettext_noop("Lima"), "America/Lima"},
       {gettext_noop("Buenos Aires"), "America/Argentina/Buenos_Aires"},
       {gettext_noop("Santiago"), "America/Santiago"},
       {gettext_noop("Sao Paulo"), "America/Sao_Paulo"},
       {gettext_noop("Caracas"), "America/Caracas"},
       {gettext_noop("Guadalajara"), "America/Mexico_City"}
     ]},
    {gettext_noop("Europe"),
     [
       {gettext_noop("Madrid"), "Europe/Madrid"},
       {gettext_noop("Lisbon"), "Europe/Lisbon"},
       {gettext_noop("London"), "Europe/London"},
       {gettext_noop("Paris"), "Europe/Paris"},
       {gettext_noop("Berlin"), "Europe/Berlin"},
       {gettext_noop("Rome"), "Europe/Rome"},
       {gettext_noop("Amsterdam"), "Europe/Amsterdam"}
     ]},
    {gettext_noop("Other"),
     [
       {gettext_noop("Portugal (Azores)"), "Atlantic/Azores"}
     ]}
  ]

  @doc """
  Returns the curated timezone list for the selector.

  Las etiquetas (región y ciudad) son msgid en inglés y se traducen al
  vuelo: `@timezones` es data estática y `gettext/1` no puede evaluarse en
  un atributo de módulo. El valor IANA (`Etc/UTC`, `Europe/Madrid`…) nunca
  cambia.
  """
  def timezone_options do
    Enum.map(@timezones, fn {region, zones} ->
      {TokengateWeb.Gettext.translate(region),
       Enum.map(zones, fn {label, tz} -> {TokengateWeb.Gettext.translate(label), tz} end)}
    end)
  end

  # Lookup en runtime: las etiquetas salen de `@timezones`, así que no pueden ir
  # por el macro `gettext/1` (que exige un literal para poder extraerlo). Las
  # entradas correspondientes del `.po` se mantienen a mano.

  @doc "Returns the effective timezone from socket assigns, or UTC default."
  def timezone_from_assigns(assigns) do
    assigns[:timezone] || @default_timezone
  end

  @doc """
  Shifts a UTC datetime to the target timezone, then formats with strftime.
  Falls back to UTC if the timezone is invalid.

  ## Examples

      iex> format_datetime(~U(2026-07-31 15:00:00Z), "America/Mexico_City")
      "31/07/2026 10:00:00"

      iex> format_datetime(~U(2026-07-31 15:00:00Z), "Etc/UTC")
      "31/07/2026 15:00:00"
  """
  def format_datetime(nil, _tz), do: "—"

  def format_datetime(%DateTime{} = dt, tz),
    do: format(dt, tz, "%d/%m/%Y %H:%M:%S")

  @doc "Same as format_datetime/2 but date-only format."
  def format_date(nil, _tz), do: "—"

  def format_date(%DateTime{} = dt, tz),
    do: format(dt, tz, "%d/%m/%Y")

  @doc "Same as format_datetime/2 but short date+time (no seconds)."
  def format_datetime_short(nil, _tz), do: "—"

  def format_datetime_short(%DateTime{} = dt, tz),
    do: format(dt, tz, "%d/%m/%Y %H:%M")

  @doc "Same as format_datetime/2 but short date+hour (for chart buckets)."
  def format_bucket(nil, _tz), do: "—"

  def format_bucket(%DateTime{} = dt, tz),
    do: format(dt, tz, "%d/%m %H:%M")

  @doc "Date-only bucket format for chart x-axis labels."
  def format_bucket_date(nil, _tz), do: "—"

  def format_bucket_date(%DateTime{} = dt, tz),
    do: format(dt, tz, "%d/%m")

  @doc "ISO-like format with timezone offset (for technical views)."
  def format_datetime_iso(nil, _tz), do: "—"

  def format_datetime_iso(%DateTime{} = dt, tz),
    do: format(dt, tz, "%Y-%m-%d %H:%M")

  defp format(dt, tz, fmt) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, shifted} -> Calendar.strftime(shifted, fmt)
      {:error, _} -> Calendar.strftime(dt, fmt)
    end
  end
end
