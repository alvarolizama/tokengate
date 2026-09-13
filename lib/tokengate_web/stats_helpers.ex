defmodule TokengateWeb.StatsHelpers do
  @moduledoc """
  Helpers de formato y cálculo de presentación para las secciones de
  StatsLive (y reutilizables en otras vistas de analíticas).

  Extraído de `TokengateWeb.StatsLive` al separar el template monolítico
  en componentes por sección (`TokengateWeb.StatsLive.{Index,Models,Groups,Group,Services,Users,LiveSection
  Groups,Services,Member,Credits}`).

  Convención: los componentes de sección los importan como
      alias TokengateWeb.StatsHelpers, as: Stats
  y llaman `Stats.format_number/1`, `Stats.cache_hit_pct/2`, etc.
  """

  use TokengateWeb, :html

  ## Template helpers -----------------------------------------------------
  def format_decimal(%Decimal{} = d) do
    d
    |> Decimal.round(4)
    |> Decimal.to_string()
  end

  def format_decimal(n) when is_number(n), do: to_string(n)
  def format_decimal(_), do: "0"

  def format_number(n) when is_integer(n), do: with_thousands_separator(n)
  def format_number(n) when is_float(n), do: Float.to_string(n)
  def format_number(_), do: "0"

  @doc "Compact notation for big counters: 32.7K, 1.2M, 3.4B."
  def format_compact(n) when is_integer(n) and n >= 1_000_000_000,
    do: "#{Float.round(n / 1_000_000_000, 1)}B"

  def format_compact(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  def format_compact(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  def format_compact(n) when is_integer(n), do: Integer.to_string(n)
  def format_compact(n) when is_float(n), do: format_compact(trunc(n))
  def format_compact(_), do: "0"

  defp with_thousands_separator(n) do
    digits = Integer.to_string(abs(n))

    grouped =
      digits
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    if n < 0, do: "-" <> grouped, else: grouped
  end

  def format_tps(nil), do: "—"
  def format_tps(n) when is_float(n), do: Float.round(n, 1) |> Float.to_string()
  def format_tps(n) when is_integer(n), do: to_string(n)

  def period_label("today"), do: "Hoy"
  def period_label("week"), do: "Esta semana"
  def period_label("month"), do: "Este mes"
  def period_label("30d"), do: "30 días"
  def period_label("90d"), do: "90 días"
  def period_label(_), do: "Hoy"

  def period_active?(current, target), do: current == target

  def has_data?([]), do: false
  def has_data?(_), do: true

  def format_ms(nil), do: "—"
  def format_ms(ms) when is_integer(ms), do: "#{format_number(ms)} ms"
  def format_ms(ms) when is_float(ms), do: "#{Float.round(ms)} ms"
  def format_ms(_), do: "—"

  @doc """
  Fecha-hora corta en la zona del usuario (`HH:MM:SS`); usada por la
  pestaña En vivo para timestamps del feed y última sincronización.
  """
  def format_dt(dt, tz \\ nil)

  def format_dt(nil, _tz), do: "—"

  def format_dt(%DateTime{} = dt, tz) do
    case DateTime.shift_zone(dt, tz || "Etc/UTC") do
      {:ok, local} -> Calendar.strftime(local, "%H:%M:%S")
      _ -> Calendar.strftime(dt, "%H:%M:%S")
    end
  end

  def format_dt(%NaiveDateTime{} = dt, _tz) do
    Calendar.strftime(dt, "%H:%M")
  end

  def format_percent(rate) when is_float(rate),
    do: "#{:erlang.float_to_binary(rate * 100, decimals: 1)}%"

  def format_percent(_), do: "—"

  @doc "Compute a total row from a breakdown list for display in table footers."
  def breakdown_total([]), do: nil

  def breakdown_total(rows) when is_list(rows) do
    %{
      request_count: Enum.reduce(rows, 0, &(&1.request_count + &2)),
      cost_usd: Enum.reduce(rows, Decimal.new(0), fn r, acc -> Decimal.add(acc, r.cost_usd) end),
      prompt_tokens: Enum.reduce(rows, 0, &(&1.prompt_tokens + &2)),
      completion_tokens: Enum.reduce(rows, 0, &(&1.completion_tokens + &2)),
      cache_read_tokens: Enum.reduce(rows, 0, &(Map.get(&1, :cache_read_tokens, 0) + &2))
    }
  end

  @doc "Count distinct providers (by model_provider_id) in a provider breakdown."
  def distinct_providers(rows) when is_list(rows) do
    rows |> Enum.map(& &1.model_provider_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()
  end

  @doc "Count distinct users (by user_email) in a member breakdown."
  def distinct_users(rows) when is_list(rows) do
    rows |> Enum.map(& &1.user_email) |> Enum.uniq() |> length()
  end

  def tier_badge_class("S"), do: "badge-success"
  def tier_badge_class("A"), do: "badge-info"
  def tier_badge_class("B"), do: "badge-warning"
  def tier_badge_class("C"), do: "badge-warning badge-outline"
  def tier_badge_class("D"), do: "badge-error"
  def tier_badge_class("alto"), do: "badge-error"
  def tier_badge_class("regular"), do: "badge-warning"
  def tier_badge_class("bajo"), do: "badge-ghost"
  def tier_badge_class(_), do: "badge-ghost"

  def hour_label(hour) when hour in 0..23, do: "#{pad2(hour)}:00"

  def error_class_label(status) when status >= 400 and status < 500, do: "4xx cliente"
  def error_class_label(status) when status >= 500, do: "5xx servidor"
  def error_class_label(_), do: "—"

  def error_class_badge(status) when status >= 400 and status < 500, do: "badge-warning"
  def error_class_badge(status) when status >= 500, do: "badge-error"
  def error_class_badge(_), do: "badge-ghost"

  def hour_usage_stacked_max(rows) do
    rows |> Enum.map(& &1.total_requests) |> Enum.max(fn -> 0 end)
  end

  @doc """
  Altura de barra en % usando escala raíz cuadrada.

  Las distribuciones por hora tienen picos muy marcados (horas laborales)
  y valles casi en cero (madrugada). Con escala lineal las barras chicas
  se vuelven invisibles; sqrt comprime los picos y levanta los valles,
  manteniendo el orden relativo.
  """
  def hour_usage_bar_height(requests, max) when max > 0 do
    pct = :math.sqrt(requests / max) * 100
    max(Float.round(pct, 1), 8.0)
  end

  def hour_usage_bar_height(_requests, _max), do: 0

  @doc """
  "Nice number" para ticks del eje Y (1, 2, 5 × 10^n).
  """
  def nice_ceiling(value) when value <= 0, do: 10

  def nice_ceiling(value) do
    exp = :math.log10(value) |> Float.floor() |> round()
    base = :math.pow(10, exp)
    fraction = value / base

    nice_fraction =
      cond do
        fraction <= 1 -> 1
        fraction <= 2 -> 2
        fraction <= 5 -> 5
        true -> 10
      end

    round(nice_fraction * base)
  end

  @doc "Genera `count` ticks (sin incluir 0) hasta un techo 'nice' para el eje Y."
  def y_axis_ticks(max, count \\ 3) do
    ceiling = nice_ceiling(max)

    1..count
    |> Enum.map(fn i -> round(ceiling * i / count) end)
    |> Enum.uniq()
  end

  @doc """
  Modelos pay_per_token para mostrar en el tooltip del hover de una barra.

  Filtra los models del hour_row por billing_mode != "included", los agrupa
  por nombre y los ordena por requests desc.
  """
  def ppt_models_for_tooltip(hour_row) do
    hour_row.models
    |> Enum.filter(&(&1.billing_mode != "included"))
    |> Enum.group_by(& &1.model)
    |> Enum.map(fn {model, entries} ->
      requests = Enum.reduce(entries, 0, &(&1.requests + &2))
      %{model: model, requests: requests}
    end)
    |> Enum.sort_by(& &1.requests, :desc)
  end

  @doc """
  Segmentos de barra para una hora: solo dos colores.

  - Gris (`bg-base-300/30`) = requests included
  - Morado (`bg-primary`) = requests pay_per_token (todos los models combinados)
  """
  def bar_segments(hour_row) do
    hour_total = hour_row.total_requests

    if hour_total <= 0 do
      []
    else
      included_segment =
        if hour_row.included_requests > 0 do
          pct = Float.round(hour_row.included_requests / hour_total * 100, 1)
          [%{height_pct: pct, color: "bg-base-300/30"}]
        else
          []
        end

      ppt_segment =
        if hour_row.pay_per_token_requests > 0 do
          pct = Float.round(hour_row.pay_per_token_requests / hour_total * 100, 1)
          [%{height_pct: pct, color: "bg-primary"}]
        else
          []
        end

      included_segment ++ ppt_segment
    end
  end

  @doc """
  Datos para la leyenda de la gráfica de uso por hora.

  - `included_requests` — total de requests included en el periodo (o la hora hovered)
  - `ppt_entries` — desglose por modelo de los requests pay_per_token, con costo
  """
  def legend_data(stacked_rows, hovered_hour) do
    source_rows =
      if hovered_hour do
        hour_row = Enum.find(stacked_rows, &(&1.hour == hovered_hour))
        if hour_row, do: hour_row.models, else: []
      else
        stacked_rows |> Enum.flat_map(& &1.models)
      end

    # Included total
    included_requests =
      source_rows
      |> Enum.filter(&(&1.billing_mode == "included"))
      |> Enum.reduce(0, &(&1.requests + &2))

    # Pay-per-token entries grouped by model
    # (includes unknown billing_mode, treated as pay_per_token)
    ppt_entries =
      source_rows
      |> Enum.filter(&(&1.billing_mode != "included"))
      |> Enum.group_by(& &1.model)
      |> Enum.map(fn {model, entries} ->
        requests = Enum.reduce(entries, 0, &(&1.requests + &2))

        cost =
          Enum.reduce(entries, Decimal.new(0), fn e, acc -> Decimal.add(acc, e.cost_usd) end)

        %{model: model, requests: requests, cost_usd: cost}
      end)
      |> Enum.sort_by(& &1.requests, :desc)

    total_requests = included_requests + Enum.reduce(ppt_entries, 0, &(&1.requests + &2))

    total_cost =
      Enum.reduce(ppt_entries, Decimal.new(0), fn e, acc -> Decimal.add(acc, e.cost_usd) end)

    %{
      included_requests: included_requests,
      ppt_entries: ppt_entries,
      total_requests: total_requests,
      total_cost_usd: total_cost,
      hovered_hour: hovered_hour
    }
  end

  def hour_bar_height(count, max) when max > 0, do: max(round(count / max * 100), 4)
  def hour_bar_height(_count, _max), do: 0

  # ── Model × provider stacked horizontal bar helpers ───────────────────────

  @doc "Total de requests del modelo con más requests (para escalar las barras)."
  def model_provider_max(rows) do
    rows |> Enum.map(& &1.total_requests) |> Enum.max(fn -> 0 end)
  end

  @provider_colors ~w(
    bg-blue-500
    bg-emerald-500
    bg-amber-500
    bg-rose-500
    bg-violet-500
    bg-cyan-500
    bg-orange-500
    bg-pink-500
    bg-teal-500
    bg-indigo-500
    bg-lime-500
    bg-fuchsia-500
    bg-sky-500
    bg-red-500
    bg-purple-500
    bg-green-500
  )

  @doc "Color de fondo para un proveedor por su índice en la leyenda."
  def provider_color(index) do
    Enum.at(@provider_colors, rem(index, length(@provider_colors)))
  end

  @doc """
  Color para un proveedor en la leyenda, buscando su índice por nombre.
  """
  def provider_legend_color(provider_name, legend) do
    idx =
      legend
      |> Enum.with_index()
      |> Enum.find_value(fn {entry, i} -> if entry.provider_name == provider_name, do: i end)

    provider_color(idx || 0)
  end

  @doc """
  Segmentos apilados por proveedor para una barra de modelo.

  Cada segmento tiene `width_pct` (ancho relativo al total del modelo) y
  `color` — un color distinto por proveedor, usando el mismo índice
  global de la leyenda para que barras y leyenda coincidan.
  """
  def provider_segments(model_row, legend) do
    total = model_row.total_requests

    if total <= 0 do
      []
    else
      model_row.providers
      |> Enum.map(fn p ->
        pct = Float.round(p.requests / total * 100, 1)

        %{
          provider_name: p.provider_name,
          requests: p.requests,
          cost_usd: p.cost_usd,
          billing_mode: p.billing_mode,
          width_pct: pct,
          color: provider_legend_color(p.provider_name, legend)
        }
      end)
    end
  end

  @doc """
  Leyenda de proveedores agregados: nombre, requests totales, costo total.
  Ordenada por requests desc.
  """
  def provider_legend(rows) do
    rows
    |> Enum.flat_map(& &1.providers)
    |> Enum.group_by(& &1.provider_name)
    |> Enum.map(fn {provider_name, entries} ->
      requests = Enum.reduce(entries, 0, &(&1.requests + &2))

      cost =
        Enum.reduce(entries, Decimal.new(0), fn e, acc ->
          Decimal.add(acc, e.cost_usd)
        end)

      %{provider_name: provider_name, requests: requests, cost_usd: cost}
    end)
    |> Enum.sort_by(& &1.requests, :desc)
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc """
  Cache hit percentage: cache_read_tokens / prompt_tokens × 100.
  Returns "—" when prompt_tokens is 0 or nil.
  """
  def cache_hit_pct(prompt_tokens, cache_read_tokens)
      when is_integer(prompt_tokens) and is_integer(cache_read_tokens) and prompt_tokens > 0 and
             cache_read_tokens > 0 do
    pct = cache_read_tokens / prompt_tokens * 100
    "#{:erlang.float_to_binary(Float.round(pct, 1), [:compact, {:decimals, 1}])}%"
  end

  def cache_hit_pct(_prompt_tokens, _cache_read_tokens), do: "—"

  # ── Drill-down sparkline helpers ─────────────────────────────────────────

  @doc """
  Pivot daily series rows into a day-bucketed map for the sparkline chart.

  Input rows: [%{date: DateTime, label: String, request_count: integer}]

  Output: %{
    days: [Date],           # ordered unique days
    series: %{
      "label" => %{date => count}
    }
  }
  """
  def pivot_daily_series(rows) when is_list(rows) do
    days =
      rows
      |> Enum.map(&DateTime.to_date(&1.date))
      |> Enum.uniq()
      |> Enum.sort()

    series =
      rows
      |> Enum.group_by(& &1.label)
      |> Map.new(fn {label, entries} ->
        by_date = Map.new(entries, &{DateTime.to_date(&1.date), &1.request_count})
        {label, by_date}
      end)

    %{days: days, series: series}
  end

  @doc "Max single-day count across all labels (for scaling the chart)."
  def daily_series_max(%{series: series}) do
    series
    |> Enum.flat_map(fn {_label, by_date} -> Map.values(by_date) end)
    |> Enum.max(fn -> 0 end)
  end

  @doc "Sparkline bar height in % using sqrt scale."
  def sparkline_bar_height(count, max) when max > 0 do
    pct = :math.sqrt(count / max) * 100
    max(Float.round(pct, 1), 4.0)
  end

  def sparkline_bar_height(_count, _max), do: 0.0

  @doc "Color for a sparkline label by index (reuses provider color palette)."
  def sparkline_color(index) do
    provider_color(index)
  end

  @doc "Total requests for a label across all days."
  def sparkline_label_total(by_date) do
    by_date |> Map.values() |> Enum.sum()
  end

  def accent_bg("primary"), do: "bg-primary/10"
  def accent_bg("success"), do: "bg-success/10"
  def accent_bg("accent"), do: "bg-accent/10"
  def accent_bg(_), do: "bg-base-300"

  def accent_text("primary"), do: "text-primary"
  def accent_text("success"), do: "text-success"
  def accent_text("accent"), do: "text-accent"
  def accent_text(_), do: "text-base-content/60"

  @doc "Sort a breakdown list by field and direction."
  def sort_rows([], _field, _direction), do: []

  def sort_rows(rows, field, direction) do
    Enum.sort_by(rows, &Map.get(&1, field), fn a, b ->
      case {a, b} do
        {nil, nil} ->
          true

        {nil, _} ->
          direction == :asc

        {_, nil} ->
          direction == :desc

        {a, b} ->
          if direction == :asc do
            compare_values(a, b) != :gt
          else
            compare_values(a, b) != :lt
          end
      end
    end)
  end

  defp compare_values(a, b) when is_struct(a, Decimal) and is_struct(b, Decimal),
    do: Decimal.compare(a, b)

  defp compare_values(a, b) when is_binary(a) and is_binary(b), do: if(a <= b, do: :lt, else: :gt)
  defp compare_values(a, b), do: if(a <= b, do: :lt, else: :gt)

  @doc "Sort indicator for table headers."
  def sort_icon(assigns) do
    ~H"""
    <span class="inline-block w-3 text-center">
      <%= if @current == @field do %>
        <%= if @direction == :asc do %>
          ▲
        <% else %>
          ▼
        <% end %>
      <% end %>
    </span>
    """
  end

  # ── Budget usage components (compartidos por todas las secciones) ──────

  @doc """
  Barra de uso de presupuesto (gasto vs límite del mes local). El tamaño
  lo pone `pct` (0-100+); el color cruza el 80%. `nil` en pct = sin
  límite (barra neutra). Reutilizada por En vivo, Resumen, Usuarios,
  Grupos y Servicios.
  """
  attr :spend, :any, required: true, doc: "Decimal — gasto del mes local"
  attr :limit, :any, default: nil, doc: "Decimal | nil — límite mensual (nil = ilimitado)"
  attr :pct, :any, default: nil, doc: "float | nil — 0-100+ ya calculado"
  attr :label, :string, default: "Mes", doc: "Prefijo del texto (Mes, Grupo, Servicio…)"
  attr :compact, :boolean, default: false, doc: "Versión mini para tablas"

  def budget_bar(assigns) do
    ~H"""
    <div class={if(@compact, do: "flex items-center gap-2", else: "space-y-1.5")}>
      <div class={[@compact && "flex-1", "w-full bg-base-300 rounded-full h-1.5 min-w-12"]}>
        <div
          class={[
            "h-1.5 rounded-full transition-all duration-500",
            budget_bar_color(@pct)
          ]}
          style={"width: #{budget_bar_width(@pct)}%"}
        >
        </div>
      </div>
      <span class={[
        "text-xs tabular-nums whitespace-nowrap",
        if(@compact, do: "text-base-content/60", else: "text-base-content/50")
      ]}>
        {format_decimal(@spend)}
        <span :if={@limit} class="text-base-content/40">
          / {format_decimal(@limit)}
        </span>
        <span :if={is_nil(@limit)} class="text-base-content/40"> · sin límite</span>
      </span>
    </div>
    """
  end

  defp budget_bar_color(nil), do: "bg-base-content/20"
  defp budget_bar_color(pct) when pct >= 100, do: "bg-error"
  defp budget_bar_color(pct) when pct >= 80, do: "bg-warning"
  defp budget_bar_color(_), do: "bg-success"

  defp budget_bar_width(nil), do: 0
  defp budget_bar_width(pct) when pct >= 100, do: 100
  defp budget_bar_width(pct) when pct < 1, do: 2
  defp budget_bar_width(pct), do: trunc(pct)

  @doc """
  Badge de estado de presupuesto para tablas: OK / ≥80% / agotado /
  sin límite.
  """
  attr :pct, :any, default: nil
  attr :exhausted?, :any, default: false

  def budget_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm whitespace-nowrap",
      cond do
        @exhausted? or (@pct != nil and @pct >= 100) -> "badge-error"
        @pct != nil and @pct >= 80 -> "badge-warning"
        @pct == nil -> "badge-ghost"
        true -> "badge-success"
      end
    ]}>
      <%= cond do %>
        <% @exhausted? or (@pct != nil and @pct >= 100) -> %>
          Agotado
        <% @pct != nil and @pct >= 80 -> %>
          ≥80%
        <% @pct == nil -> %>
          sin límite
        <% true -> %>
          OK
      <% end %>
    </span>
    """
  end
end
