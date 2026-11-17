defmodule TokengateWeb.CalculatorLive do
  @moduledoc """
  Cost calculator: contrasts the REAL spend reported by the upstream with an
  ESTIMATE computed from the selected lane's prices (or from hand-typed ones).

  A model opens up into lanes (`Providers.list_model_providers/1`): picking a
  lane prefills its four prices and narrows the real spend to that lane; when
  the lane lives in a pool, the operator can narrow down to ONE of its keys.
  With no lane selected the real spend is the sum of every provider of the
  model.

  The real number uses the same source as StatsLive (`Logs.cost_summary/1`,
  with `model_id`/`model_provider_id`/`credential_id`), and the hourly series
  comes from `Rollup.hourly_series_for_model/2` with the SAME filters, so the
  numbers match the stats page for the same period and timezone.

  A lane that does not bill tokens (`Pricing.token_unit?/1` false: per request,
  per image, per minute…) has no estimable cost: the form warns and the
  estimate card/line/column are not rendered. The real number still renders.

  The estimate always applies the four typed rates. `CostCalculator` has a
  fallback that prices the whole prompt at the input rate when a lane declares
  no cache price; this page does not replicate it, so a lane without a cache
  price prefills 0.00 and the operator types the real cache rate.
  """

  use TokengateWeb, :live_view
  alias Tokengate.Logs
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Periods
  alias Tokengate.Providers
  alias Tokengate.Providers.Pricing

  import TokengateWeb.KpiHelpers, only: [kpi_card: 1, format_compact: 1]

  @periods ~w(today week 7d 30d last_month)
  @default_prices %{input: "3.00", cache: "0.30", cache_write: "0.00", output: "15.00"}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    # Use the timezone already assigned by UserAuth on_mount — the sidebar
    # selector can change it dynamically, so prefer socket assigns over the
    # user record.
    timezone = socket.assigns[:timezone] || (user && user.timezone) || Periods.default_timezone()

    models =
      Providers.list_models()
      |> Enum.filter(fn m -> m.model_type == "llm" end)
      |> Enum.sort_by(& &1.name)

    socket =
      socket
      |> assign(:page_title, "Calculadora · Tokengate")
      |> assign(:is_admin, user && user.global_role == "admin")
      |> assign(:timezone, timezone)
      |> assign(:models, models)
      |> assign(:selected_model_id, nil)
      |> assign(:lanes, [])
      |> assign(:selected_lane_id, nil)
      |> assign(:selected_credential_id, nil)
      |> assign(:lane_unit, "per_1m_tokens")
      |> assign(:lane_non_token, false)
      |> assign(:period, "7d")
      |> assign(:cost_input, @default_prices.input)
      |> assign(:cost_cache, @default_prices.cache)
      |> assign(:cost_output, @default_prices.output)
      |> assign(:cost_cache_write, @default_prices.cache_write)
      |> assign(:chart_data, [])
      |> assign(:summary, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("calculate", params, socket) do
    model_id = params["model_id"] || ""
    period = params["period"] || socket.assigns.period

    model_changed = model_id != (socket.assigns.selected_model_id || "")

    lanes =
      cond do
        not model_changed -> socket.assigns.lanes
        model_id == "" -> []
        true -> Providers.list_model_providers(model_id)
      end

    # Changing the model repaints the lane select: the previous model's lane
    # (and the key hanging from it) no longer exists.
    lane_id = if model_changed, do: "", else: params["lane_id"] || ""
    lane_changed = lane_id != (socket.assigns.selected_lane_id || "")

    socket =
      socket
      |> assign(:selected_model_id, model_id)
      |> assign(:period, period)
      |> assign(:lanes, lanes)

    socket =
      if model_changed or lane_changed do
        # Picking a lane (or changing the model) REPLACES the typed prices: the
        # lane brings its own. Without a change, typed prices survive every
        # phx-change.
        apply_lane(socket, Enum.find(lanes, &(&1.id == lane_id)))
      else
        keep_typed_prices(socket, params)
      end

    # The key can only be a member of the selected lane's pool; any other id
    # (or a lane without a pool) is dropped.
    credential_id =
      if model_changed or lane_changed, do: "", else: params["credential_id"] || ""

    socket =
      assign(
        socket,
        :selected_credential_id,
        pool_credential_id(lanes, socket.assigns.selected_lane_id, credential_id)
      )

    socket =
      if model_id != "" do
        load_chart_data(
          socket,
          model_id,
          period,
          current_prices(socket),
          socket.assigns.selected_lane_id,
          socket.assigns.selected_credential_id
        )
      else
        socket
        |> assign(:chart_data, [])
        |> assign(:summary, nil)
      end

    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Lane selection ────────────────────────────────────────────────────────

  # No lane: the typed prices belonged to a lane that is gone, so the form
  # returns to the defaults along with the unit (a previous per_request lane
  # cannot leave the whole model without an estimate).
  defp apply_lane(socket, nil) do
    socket
    |> assign(:selected_lane_id, nil)
    |> assign(:lane_unit, "per_1m_tokens")
    |> assign(:lane_non_token, false)
    |> assign(:cost_input, @default_prices.input)
    |> assign(:cost_cache, @default_prices.cache)
    |> assign(:cost_cache_write, @default_prices.cache_write)
    |> assign(:cost_output, @default_prices.output)
  end

  defp apply_lane(socket, lane) do
    unit = lane.pricing_unit || "per_1m_tokens"
    non_token = not Pricing.token_unit?(unit)

    {cost_input, cost_cache, cost_output, cost_cache_write} =
      if non_token do
        # The four `*_cost_per_million` fields mean nothing under a non-token
        # unit (the lane bills `unit_cost`): do not overwrite whatever the
        # operator typed, because the estimate does not apply.
        {socket.assigns.cost_input, socket.assigns.cost_cache, socket.assigns.cost_output,
         socket.assigns.cost_cache_write}
      else
        {price_string(lane.input_cost_per_million), price_string(lane.cache_cost_per_million),
         price_string(lane.output_cost_per_million),
         price_string(lane.cache_write_cost_per_million)}
      end

    socket
    |> assign(:selected_lane_id, lane.id)
    |> assign(:lane_unit, unit)
    |> assign(:lane_non_token, non_token)
    |> assign(:cost_input, cost_input)
    |> assign(:cost_cache, cost_cache)
    |> assign(:cost_output, cost_output)
    |> assign(:cost_cache_write, cost_cache_write)
  end

  defp keep_typed_prices(socket, params) do
    socket
    |> assign(:cost_input, params["cost_input"] || socket.assigns.cost_input)
    |> assign(:cost_cache, params["cost_cache"] || socket.assigns.cost_cache)
    |> assign(:cost_output, params["cost_output"] || socket.assigns.cost_output)
    |> assign(:cost_cache_write, params["cost_cache_write"] || socket.assigns.cost_cache_write)
  end

  defp current_prices(socket) do
    %{
      input: socket.assigns.cost_input,
      cache: socket.assigns.cost_cache,
      cache_write: socket.assigns.cost_cache_write,
      output: socket.assigns.cost_output
    }
  end

  # The key is only valid when it belongs to the selected lane's pool.
  defp pool_credential_id(_lanes, _lane_id, ""), do: nil

  defp pool_credential_id(lanes, lane_id, credential_id) do
    with %{pool: %{members: members}} when is_list(members) <-
           Enum.find(lanes, &(&1.id == lane_id)),
         true <- Enum.any?(members, &(&1.credential_id == credential_id)) do
      credential_id
    else
      _ -> nil
    end
  end

  # ── Data loading ──────────────────────────────────────────────────────────

  defp load_chart_data(socket, model_id, period, prices, lane_id, credential_id) do
    timezone = socket.assigns.timezone
    lane_unit = socket.assigns.lane_unit
    lane_non_token = socket.assigns.lane_non_token
    bounds = Periods.period_bounds(period, timezone)

    # Source of truth for totals: the same cost_summary that Stats uses, with
    # the same from/to/filter. This guarantees identical numbers.
    filters =
      %{model_id: model_id, from: bounds.from, to: bounds.to}
      |> put_filter(:model_provider_id, lane_id)
      |> put_filter(:credential_id, credential_id)

    summary_data = Logs.cost_summary(filters)

    # Hourly series for the chart breakdown only — same lane/key filters.
    series =
      Rollup.hourly_series_for_model(model_id,
        from: bounds.from,
        to: bounds.to,
        timezone: timezone,
        model_provider_id: nilify(lane_id),
        credential_id: nilify(credential_id)
      )

    cost_input = parse_decimal(prices.input, Decimal.new("3.00"))
    cost_cache = parse_decimal(prices.cache, Decimal.new("0.30"))
    cost_cache_write = parse_decimal(prices.cache_write, Decimal.new("0.00"))
    cost_output = parse_decimal(prices.output, Decimal.new("15.00"))

    # The price is in the lane's unit (1M, 1K or a plain unit): one formula
    # `quantity × price / divisor`, with Pricing's divisor.
    divisor = Decimal.new(Pricing.divisor(lane_unit))

    chart_data =
      Enum.map(series, fn row ->
        prompt = row.prompt_tokens
        completion = row.completion_tokens
        cached = row.cache_read_tokens
        cache_creation = row.cache_creation_tokens
        non_cached = max(prompt - cached, 0)

        # 4 ADDITIVE terms: non-cached × input + cache read × cache + cache
        # write × write + completion × output.
        estimated_cost =
          if lane_non_token do
            nil
          else
            cost_input
            |> Decimal.mult(Decimal.new(non_cached))
            |> Decimal.add(Decimal.mult(cost_cache, Decimal.new(cached)))
            |> Decimal.add(Decimal.mult(cost_cache_write, Decimal.new(cache_creation)))
            |> Decimal.add(Decimal.mult(cost_output, Decimal.new(completion)))
            |> Decimal.div(divisor)
            |> Decimal.round(6)
          end

        %{
          hour: row.hour,
          request_count: row.request_count,
          real_cost: row.cost_usd,
          estimated_cost: estimated_cost,
          prompt_tokens: prompt,
          completion_tokens: completion,
          cache_read_tokens: cached,
          cache_creation_tokens: cache_creation
        }
      end)

    # Total estimated cost (sum of per-hour estimates)
    total_estimated =
      if lane_non_token do
        nil
      else
        chart_data
        |> Enum.reduce(Decimal.new(0), fn row, acc -> Decimal.add(acc, row.estimated_cost) end)
        |> Decimal.round(4)
      end

    # Total real cost from cost_summary (same source as Stats)
    total_real = Decimal.round(summary_data.total_cost_usd, 4)

    difference =
      if total_estimated do
        Decimal.sub(total_estimated, total_real) |> Decimal.round(4)
      end

    summary = %{
      total_real: total_real,
      total_estimated: total_estimated,
      difference: difference,
      total_requests: summary_data.request_count,
      total_prompt: summary_data.total_prompt_tokens,
      total_completion: summary_data.total_completion_tokens,
      total_cache_read: summary_data.total_cache_read_tokens,
      total_cache_creation: summary_data.total_cache_creation_tokens
    }

    socket
    |> assign(:chart_data, chart_data)
    |> assign(:summary, summary)
  end

  defp put_filter(filters, _key, nil), do: filters
  defp put_filter(filters, _key, ""), do: filters
  defp put_filter(filters, key, value), do: Map.put(filters, key, value)

  defp nilify(""), do: nil
  defp nilify(nil), do: nil
  defp nilify(value), do: value

  # ── Parsing helpers ────────────────────────────────────────────────────────

  defp parse_decimal(str, default) do
    case Decimal.parse(str || "") do
      {d, ""} -> d
      _ -> default
    end
  end

  # Lane price as a decimal string that keeps the lane's precision: per_1K
  # prices are stored as 0.0035, so rounding to 2 decimals would zero them.
  # Trailing zeros are trimmed but at least two decimals stay.
  defp price_string(nil), do: "0.00"

  defp price_string(%Decimal{} = d), do: d |> Decimal.round(6) |> decimal_price_string()

  defp price_string(value) when is_number(value) do
    value |> Decimal.from_float() |> Decimal.round(6) |> decimal_price_string()
  end

  defp decimal_price_string(%Decimal{} = d) do
    case String.split(Decimal.to_string(d, :normal), ".") do
      [int, dec] ->
        dec = String.trim_trailing(dec, "0")
        dec = if String.length(dec) < 2, do: String.pad_trailing(dec, 2, "0"), else: dec
        int <> "." <> dec

      [int] ->
        int <> ".00"
    end
  end

  # ── Template helpers ──────────────────────────────────────────────────────

  def period_label("today"), do: "Hoy"
  def period_label("week"), do: "Esta semana"
  def period_label("7d"), do: gettext("7 days")
  def period_label("30d"), do: gettext("30 days")
  def period_label("last_month"), do: gettext("Last month")
  def period_label(_), do: "—"

  @doc """
  Lane label: `provider — provider_model (P<priority>)`, and when the lane
  lives in a pool, `· Pool <name> (<n> keys)`.
  """
  def lane_label(lane) do
    provider = lane_provider(lane)
    provider_name = if provider, do: provider.name, else: "—"

    base = "#{provider_name} — #{lane.provider_model} (P#{lane.priority || 0})"

    case lane.pool do
      %{name: name, members: members} when is_list(members) ->
        base <> " · Pool #{name} (#{length(members)} keys)"

      _ ->
        base
    end
  end

  defp lane_provider(%{credential: %{provider: %{} = provider}}), do: provider

  defp lane_provider(%{pool: %{members: [%{credential: %{provider: %{} = provider}} | _]}}),
    do: provider

  defp lane_provider(_lane), do: nil

  @doc """
  The selected lane, only when it lives in a pool (nil otherwise). A pool
  ALWAYS has at least one member, so the pool's presence is what decides
  whether the form offers narrowing down to a key.
  """
  def selected_pool_lane(lanes, lane_id) do
    case Enum.find(lanes, &(&1.id == lane_id)) do
      %{pool_id: pool_id} = lane when is_binary(pool_id) -> lane
      _ -> nil
    end
  end

  @doc "Pool keys of a lane, in the order the pool keeps them."
  def pool_credentials(%{pool: %{members: members}}) when is_list(members) do
    Enum.map(members, & &1.credential)
  end

  def pool_credentials(_lane), do: []

  def credential_label(%{name: name}) when is_binary(name) and name != "", do: name

  def credential_label(%{id: id}) when is_binary(id), do: "key #{String.slice(id, 0, 8)}"

  def credential_label(_cred), do: "key"

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
          max(Decimal.to_float(row.real_cost), est_float(row.estimated_cost))
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
          real_y = pad_top + plot_h - Decimal.to_float(row.real_cost) / max_val * plot_h
          est_y = pad_top + plot_h - est_float(row.estimated_cost) / max_val * plot_h

          {Float.round(x, 1), Float.round(real_y, 1), Float.round(est_y, 1)}
        end)

      real_pts = points |> Enum.map(fn {x, y, _} -> "#{x},#{y}" end) |> Enum.join(" ")
      est_pts = points |> Enum.map(fn {x, _, y} -> "#{x},#{y}" end) |> Enum.join(" ")

      # Real cost area path (for fill)
      {first_x, _, _} = List.first(points)
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

  # A lane that does not bill tokens has no estimate (nil): the axis scales
  # from the real number alone.
  defp est_float(nil), do: 0.0
  defp est_float(%Decimal{} = d), do: Decimal.to_float(d)

  defp build_y_ticks(max_val, plot_h, pad_top, pad_left) do
    for i <- 0..4 do
      val = max_val * i / 4
      y = pad_top + plot_h - val / max_val * plot_h
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
      x = pad_left + if count > 1, do: i / (count - 1) * plot_w, else: 0.0
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

  def difference_class(_), do: "text-base-content/50"

  def difference_sign(%Decimal{sign: -1}), do: "−"
  def difference_sign(_), do: "+"

  def abs_decimal(%Decimal{} = d), do: Decimal.abs(d) |> Decimal.to_string(:normal)
  def abs_decimal(_), do: "0.00"

  # Same criterion as difference_class/1: positive means paying more than the
  # estimate (error accent); everything else keeps the primary accent.
  def difference_accent(d) do
    if difference_class(d) == "text-error", do: "error", else: "primary"
  end

  def difference_pct(%{difference: nil}), do: nil

  def difference_pct(%{difference: diff, total_real: real}) do
    if Decimal.equal?(real, Decimal.new(0)) do
      nil
    else
      diff
      |> Decimal.div(real)
      |> Decimal.mult(100)
      |> Decimal.round(1)
      |> Decimal.to_string(:normal)
    end
  end

  def periods, do: @periods
end
