defmodule TokengateWeb.CalculatorLive do
  @moduledoc """
  Cost calculator: compare real provider spend vs an estimated cost
  using custom pricing parameters (input, cache, output price per
  million tokens, and cache hit-rate).

  Pulls hourly aggregated data for a selected model alias across ALL
  API keys (included + pay_per_token) and overlays it with a
  calculated estimate so operators can see whether they're paying more
  or less than expected.

  The real-cost totals use the same source as StatsLive
  (`Logs.cost_summary/1` with `model_alias_id` filter), so the numbers
  always match the stats page for the same period + timezone.
  """

  use TokengateWeb, :live_view

  alias Tokengate.Logs
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Periods
  alias Tokengate.Providers

  @periods ~w(today week 7d 30d 90d)

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    # Use the timezone already assigned by UserAuth on_mount — the sidebar
    # selector can change it dynamically, so prefer socket assigns over the
    # user record.
    timezone = socket.assigns[:timezone] || user && user.timezone || Periods.default_timezone()

    models =
      Providers.list_model_aliases()
      |> Enum.filter(fn m -> m.model_type == "llm" end)
      |> Enum.sort_by(& &1.name)

    socket =
      socket
      |> assign(:page_title, "Calculadora · Tokengate")
      |> assign(:is_admin, user && user.global_role == "admin")
      |> assign(:timezone, timezone)
      |> assign(:models, models)
      |> assign(:selected_model_id, nil)
      |> assign(:period, "7d")
      |> assign(:cost_input, "3.00")
      |> assign(:cost_cache, "0.30")
      |> assign(:cost_output, "15.00")
      |> assign(:hit_rate, "90")
      |> assign(:chart_data, [])
      |> assign(:summary, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("calculate", params, socket) do
    model_id = params["model_id"]
    period = params["period"] || "7d"
    cost_input = params["cost_input"] || "3.00"
    cost_cache = params["cost_cache"] || "0.30"
    cost_output = params["cost_output"] || "15.00"
    hit_rate_str = params["hit_rate"] || "90"

    socket =
      socket
      |> assign(:selected_model_id, model_id)
      |> assign(:period, period)
      |> assign(:cost_input, cost_input)
      |> assign(:cost_cache, cost_cache)
      |> assign(:cost_output, cost_output)
      |> assign(:hit_rate, hit_rate_str)

    socket =
      if model_id && model_id != "" do
        load_chart_data(socket, model_id, period, cost_input, cost_cache, cost_output, hit_rate_str)
      else
        socket
        |> assign(:chart_data, [])
        |> assign(:summary, nil)
      end

    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Data loading ──────────────────────────────────────────────────────────

  defp load_chart_data(
         socket,
         model_id,
         period,
         cost_input_str,
         cost_cache_str,
         cost_output_str,
         hit_rate_str
       ) do
    timezone = socket.assigns.timezone
    bounds = Periods.period_bounds(period, timezone)

    # Source of truth for totals: the same cost_summary that Stats uses,
    # with the same from/to/filter. This guarantees identical numbers.
    summary_data =
      Logs.cost_summary(%{
        model_alias_id: model_id,
        from: bounds.from,
        to: bounds.to
      })

    # Hourly series for the chart breakdown only.
    series =
      Rollup.hourly_series_for_model(model_id,
        from: bounds.from,
        to: bounds.to,
        timezone: timezone
      )

    cost_input = parse_decimal(cost_input_str, Decimal.new("3.00"))
    cost_cache = parse_decimal(cost_cache_str, Decimal.new("0.30"))
    cost_output = parse_decimal(cost_output_str, Decimal.new("15.00"))
    hit_rate = parse_float(hit_rate_str, 90.0) / 100.0

    # Per-million multiplier: price is per 1M tokens → cost = tokens * price * 1e-6
    per_million = Decimal.new("0.000001")

    chart_data =
      Enum.map(series, fn row ->
        # prompt_tokens in DB = non-cached input (normalizer subtracts cache).
        # cache_read_tokens = tokens served from cache at discount price.
        # cache_creation_tokens = tokens written to cache, charged at input price.
        prompt = row.prompt_tokens
        cache_read = row.cache_read_tokens
        cache_creation = row.cache_creation_tokens
        completion = row.completion_tokens

        # When the provider reports cache_read_tokens > 0, use them directly.
        # When it doesn't (0), simulate: hit_rate% of prompt_tokens would have
        # read from cache at the cache price instead of the full input price.
        {fresh_at_input_price, cache_at_cache_price} =
          if cache_read > 0 do
            {prompt, cache_read}
          else
            sim_cache = trunc(prompt * hit_rate)
            {prompt - sim_cache, sim_cache}
          end

        # cache_creation_tokens are input tokens → charged at input price.
        total_at_input_price = fresh_at_input_price + cache_creation

        est_input =
          cost_input
          |> Decimal.mult(Decimal.new(total_at_input_price))
          |> Decimal.mult(per_million)

        est_cache =
          cost_cache
          |> Decimal.mult(Decimal.new(cache_at_cache_price))
          |> Decimal.mult(per_million)

        est_output =
          cost_output
          |> Decimal.mult(Decimal.new(completion))
          |> Decimal.mult(per_million)

        estimated_cost =
          [est_input, est_cache, est_output]
          |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
          |> Decimal.round(6)

        %{
          hour: row.hour,
          request_count: row.request_count,
          real_cost: row.cost_usd,
          estimated_cost: estimated_cost,
          prompt_tokens: prompt,
          completion_tokens: completion,
          cache_read_tokens: cache_read,
          cache_creation_tokens: cache_creation
        }
      end)

    # Total estimated cost (sum of per-hour estimates)
    total_estimated =
      Enum.reduce(chart_data, Decimal.new(0), fn row, acc ->
        Decimal.add(acc, row.estimated_cost)
      end)
      |> Decimal.round(4)

    # Total real cost from cost_summary (same source as Stats)
    total_real = Decimal.round(summary_data.total_cost_usd, 4)

    difference = Decimal.sub(total_estimated, total_real) |> Decimal.round(4)

    summary = %{
      total_real: total_real,
      total_estimated: total_estimated,
      difference: difference,
      total_requests: summary_data.request_count,
      total_prompt: summary_data.total_prompt_tokens,
      total_completion: summary_data.total_completion_tokens,
      total_cache: summary_data.total_cache_read_tokens
    }

    socket
    |> assign(:chart_data, chart_data)
    |> assign(:summary, summary)
  end

  # ── Parsing helpers ────────────────────────────────────────────────────────

  defp parse_decimal(str, default) do
    case Decimal.parse(str || "") do
      {d, ""} -> d
      _ -> default
    end
  end

  defp parse_float(str, default) do
    case Float.parse(str || "") do
      {f, ""} -> f
      _ -> default
    end
  end

  # ── Template helpers ──────────────────────────────────────────────────────

  def period_label("today"), do: "Hoy"
  def period_label("week"), do: "Esta semana"
  def period_label("7d"), do: "7 días"
  def period_label("30d"), do: "30 días"
  def period_label("90d"), do: "90 días"
  def period_label(_), do: "—"

  def format_cost(%Decimal{} = d) do
    d
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
  end

  def format_cost(_), do: "0.00"

  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3, 3, [])
    |> Enum.join(",")
    |> String.reverse()
  end

  def format_number(_), do: "0"

  # ── Chart helpers ──────────────────────────────────────────────────────────

  # Build SVG dual-line chart. Returns a map with point strings and axis info.
  def chart_points(chart_data) do
    if chart_data == [] do
      %{real_points: "", est_points: "", max_val: 0.0, y_ticks: [], x_labels: []}
    else
      width = 800
      height = 220
      pad_left = 70
      pad_right = 20
      pad_top = 10
      pad_bottom = 35

      plot_w = width - pad_left - pad_right
      plot_h = height - pad_top - pad_bottom
      count = length(chart_data)

      max_val =
        chart_data
        |> Enum.map(fn row ->
          max(Decimal.to_float(row.real_cost), Decimal.to_float(row.estimated_cost))
        end)
        |> Enum.max()
        |> max(0.01)
        |> (&(&1 * 1.1)).()

      step_x = if count > 1, do: plot_w / (count - 1), else: 0.0

      points =
        chart_data
        |> Enum.with_index()
        |> Enum.map(fn {row, i} ->
          x = pad_left + i * step_x
          real_y = pad_top + plot_h - (Decimal.to_float(row.real_cost) / max_val * plot_h)
          est_y = pad_top + plot_h - (Decimal.to_float(row.estimated_cost) / max_val * plot_h)

          {Float.round(x, 1), Float.round(real_y, 1), Float.round(est_y, 1)}
        end)

      real_pts = points |> Enum.map(fn {x, y, _} -> "#{x},#{y}" end) |> Enum.join(" ")
      est_pts = points |> Enum.map(fn {x, _, y} -> "#{x},#{y}" end) |> Enum.join(" ")

      # Real cost area path (for fill)
      {first_x, _first_y, _} = List.first(points)
      {last_x, _, _} = List.last(points)
      real_area = "M#{first_x},#{pad_top + plot_h} L#{real_pts} L#{last_x},#{pad_top + plot_h} Z"

      y_ticks = build_y_ticks(max_val, plot_h, pad_top, pad_left)
      x_labels = build_x_labels(chart_data, pad_left, plot_w)

      %{
        real_points: real_pts,
        est_points: est_pts,
        real_area: real_area,
        max_val: max_val,
        y_ticks: y_ticks,
        x_labels: x_labels,
        pad_top: pad_top,
        pad_bottom: pad_bottom,
        plot_h: plot_h
      }
    end
  end

  defp build_y_ticks(max_val, plot_h, pad_top, pad_left) do
    for i <- 0..4 do
      val = max_val * i / 4
      y = pad_top + plot_h - (val / max_val * plot_h)
      %{value: format_tick(val), y: Float.round(y, 1), x: pad_left}
    end
  end

  defp format_tick(val) do
    cond do
      val >= 1.0 -> :erlang.float_to_binary(val, decimals: 1)
      val > 0 -> :erlang.float_to_binary(val, decimals: 4)
      true -> "0"
    end
  end

  defp build_x_labels(chart_data, pad_left, plot_w) do
    count = length(chart_data)
    step = max(div(count, 6), 1)

    chart_data
    |> Enum.with_index()
    |> Enum.filter(fn {_row, i} -> rem(i, step) == 0 end)
    |> Enum.map(fn {row, i} ->
      label = format_hour_label(row.hour)
      x = pad_left + (if count > 1, do: i / (count - 1) * plot_w, else: 0)
      %{label: label, x: Float.round(x, 1)}
    end)
  end

  defp format_hour_label(%DateTime{} = dt) do
    Calendar.strftime(dt, "%d/%m %H:%M")
  end

  defp format_hour_label(_), do: "—"

  def difference_class(%Decimal{} = d) do
    cond do
      Decimal.compare(d, 0) == :gt -> "text-error"
      Decimal.compare(d, 0) == :lt -> "text-success"
      true -> "text-base-content/50"
    end
  end

  def difference_sign(%Decimal{sign: -1}), do: "−"
  def difference_sign(_), do: "+"

  def abs_decimal(%Decimal{} = d), do: Decimal.abs(d) |> Decimal.to_string(:normal)

  def periods, do: @periods
end