defmodule TokengateWeb.BenchmarksLive do
  @moduledoc """
  Providers Benchmarks — real-usage report built from `request_logs`.

  Pick a model alias and a window (7 / 30 / 60 days) and the page aggregates
  the durable logs per **provider** (never per credential): request count,
  error rate, avg TTFT, avg/p95 latency, tokens-per-second and cost. No
  synthetic prompt runs — everything shown already happened through the
  proxy.
  """

  use TokengateWeb, :live_view

  alias Tokengate.Metrics.Rollup
  alias Tokengate.Periods
  alias Tokengate.Providers

  @periods ~w(7d 30d 60d)
  @default_period "30d"

  @impl true
  def mount(_params, _session, socket) do
    model_aliases =
      Providers.list_model_aliases()
      |> Enum.filter(&(&1.model_type == "llm"))
      |> Enum.sort_by(& &1.name)

    socket =
      socket
      |> assign(:page_title, "Providers Benchmarks · Tokengate")
      |> assign(:model_aliases, model_aliases)
      |> assign(:periods, @periods)
      |> assign(:selected_alias, nil)
      |> assign(:period, @default_period)
      |> assign(:report, [])

    {:ok, socket}
  end

  # ── Filters ───────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_alias", %{"alias_id" => ""}, socket) do
    {:noreply,
     socket
     |> assign(:selected_alias, nil)
     |> assign(:report, [])}
  end

  def handle_event("select_alias", %{"alias_id" => alias_id}, socket) do
    selected = Enum.find(socket.assigns.model_aliases, &(&1.id == alias_id))

    {:noreply,
     socket
     |> assign(:selected_alias, selected)
     |> load_report()}
  end

  def handle_event("set_period", %{"period" => period}, socket)
      when period in @periods do
    {:noreply,
     socket
     |> assign(:period, period)
     |> load_report()}
  end

  # ── Report loading ────────────────────────────────────────────────────

  defp load_report(socket) do
    case socket.assigns.selected_alias do
      nil ->
        assign(socket, :report, [])

      alias_ ->
        %{from: from, to: to} = period_bounds(socket.assigns.period)
        report = Rollup.benchmark_by_provider_for_model(alias_.id, from: from, to: to)
        assign(socket, :report, report)
    end
  end

  defp period_bounds(period) do
    days = String.to_integer(String.trim_trailing(period, "d"))
    %{from: Periods.start_of_n_days_ago_utc(days - 1), to: Periods.now_utc()}
  end

  # ── Helpers for template ──────────────────────────────────────────────

  def selected_alias?(%{id: id}, %{id: id}), do: true
  def selected_alias?(_, _), do: false

  def period_active?(period, active), do: period == active

  def fmt_period(period), do: "#{String.trim_trailing(period, "d")} días"

  @doc """
  Best row per metric: min TTFT, min avg latency, min p95, max TPS, min
  error rate. Ties keep the first row (report is sorted by provider name).
  """
  def best_row(report, key, direction) do
    comparable =
      Enum.filter(report, fn row ->
        case Map.fetch!(row, key) do
          nil -> false
          value -> is_number(value)
        end
      end)

    case comparable do
      [] ->
        nil

      rows ->
        sorter =
          if direction == :max, do: &(&1 >= &2), else: &(&1 <= &2)

        rows
        |> Enum.reduce(fn row, best ->
          if sorter.(Map.fetch!(row, key), Map.fetch!(best, key)), do: row, else: best
        end)
    end
  end

  def max_metric(report, key) do
    report
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 0 end)
  end

  def bar_width(value, max_value) when is_number(value) and max_value > 0 do
    Float.round(value / max_value * 100, 1)
  end

  def bar_width(_, _), do: 0.0

  def fmt_ms(ms) when is_number(ms), do: "#{round(ms)}ms"
  def fmt_ms(_), do: "—"

  def fmt_tps(tps) when is_number(tps), do: "#{Float.round(tps, 1)} t/s"
  def fmt_tps(_), do: "—"

  def fmt_cost(nil), do: "—"

  def fmt_cost(%Decimal{} = d),
    do: "$#{d |> Decimal.to_float() |> Float.round(4)}"

  def fmt_pct(rate) when is_number(rate), do: "#{rate}%"
  def fmt_pct(_), do: "—"

  def error_badge(rate) when rate > 25.0, do: "badge-error"
  def error_badge(rate) when rate > 5.0, do: "badge-warning"
  def error_badge(_), do: "badge-success"
end
