defmodule TokengateWeb.StatsLive.DailyStackedChart do
  @moduledoc """
  Shared responsive stacked daily bar chart for drill-down views
  (`StatsLive.Model` and `StatsLive.Groups`).

  Places the legend below the chart with `flex-wrap` (matching `DayHourChart`)
  so narrow/mobile viewports keep the full width for the bars.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :period, :string, required: true
  attr :series, :list, required: true
  attr :labels, :list, required: true
  attr :show_logos, :boolean, default: false
  attr :metric, :string, default: "requests", values: ~w(requests cost)
  attr :toggle_event, :string, default: nil

  def daily_stacked_chart(assigns) do
    metric_atom = if assigns.metric == "cost", do: :cost, else: :requests
    pivoted = Stats.pivot_daily_series(assigns.series, metric_atom)

    assigns =
      assigns
      |> assign(:metric_atom, metric_atom)
      |> assign(:cost_mode?, metric_atom == :cost)
      |> assign(:pivoted, pivoted)
      |> assign(:spark_max, Stats.daily_series_max(pivoted))

    ~H"""
    <div :if={@series != []} class="card bg-base-100 border border-base-300 shadow-sm" id={@id}>
      <div class="card-body p-4 gap-2">
        <div class="flex items-center justify-between gap-2 flex-wrap">
          <h2 class="card-title text-base">
            <.icon name="hero-chart-bar" class="w-5 h-5 text-base-content/60" />
            {@title}
          </h2>
          <div class="flex items-center gap-2">
            <span class="text-[10px] text-base-content/40 hidden sm:inline">
              {Stats.period_label(@period)}
            </span>
            <div :if={@toggle_event} class="join" id={@id && "#{@id}-metric-toggle"}>
              <button
                type="button"
                phx-click={@toggle_event}
                phx-value-metric="requests"
                class={[
                  "btn btn-xs join-item",
                  if(!@cost_mode?, do: "btn-primary", else: "btn-ghost")
                ]}
              >
                {gettext("Requests")}
              </button>
              <button
                type="button"
                phx-click={@toggle_event}
                phx-value-metric="cost"
                class={["btn btn-xs join-item", if(@cost_mode?, do: "btn-primary", else: "btn-ghost")]}
              >
                {gettext("Cost")}
              </button>
            </div>
          </div>
        </div>

        <div class="mt-2">
          <div class="flex items-end gap-px h-32 relative">
            <div
              :for={day <- @pivoted.days}
              class="flex-1 flex flex-col items-center justify-end h-full group relative"
            >
              <%!-- Tooltip --%>
              <div class="hidden group-hover:block absolute -top-1 -translate-y-full left-1/2 -translate-x-1/2 z-20 pointer-events-none">
                <div class="bg-base-300 text-base-content text-[10px] rounded-md px-2 py-1 shadow-lg whitespace-nowrap">
                  <div class="font-semibold">
                    {Calendar.strftime(day, "%d %b")}
                  </div>
                  <div :for={label <- @labels} class="flex justify-between gap-2">
                    <span class="truncate max-w-[100px]">{label}</span>
                    <span class="tabular-nums">
                      {format_series_val(Map.get(@pivoted.series[label] || %{}, day, 0), @cost_mode?)}
                    </span>
                  </div>
                </div>
              </div>

              <%!-- Stacked bar --%>
              <div class="w-full flex flex-col-reverse rounded-t overflow-hidden">
                <div
                  :for={label <- @labels}
                  class={[
                    "w-full",
                    Stats.sparkline_color(Enum.find_index(@labels, &(&1 == label)) || 0)
                  ]}
                  style={"height: #{Stats.sparkline_bar_height(Map.get(@pivoted.series[label] || %{}, day, 0), @spark_max)}%"}
                  title={"#{label}: #{format_series_val(Map.get(@pivoted.series[label] || %{}, day, 0), @cost_mode?)}"}
                />
              </div>
            </div>
          </div>

          <%!-- Day labels --%>
          <% day_count = length(@pivoted.days) %>
          <% label_step = if day_count > 16, do: div(day_count, 10) + 1, else: 1 %>
          <div class="flex gap-px mt-1">
            <span
              :for={{day, idx} <- Enum.with_index(@pivoted.days)}
              class="flex-1 text-center text-[9px] text-base-content/40 tabular-nums"
            >
              <span :if={rem(idx, label_step) == 0 or idx == day_count - 1}>
                {Calendar.strftime(day, "%d")}
              </span>
            </span>
          </div>
        </div>

        <%!-- Legend below the chart --%>
        <div
          :if={@labels != []}
          class="flex flex-wrap items-center gap-x-4 gap-y-1.5 mt-2 pt-2 border-t border-base-300/60"
          id={@id && "#{@id}-legend"}
        >
          <div :for={{label, idx} <- Enum.with_index(@labels)} class="flex items-center gap-1.5">
            <span class={["w-2 h-2 rounded-sm shrink-0", Stats.sparkline_color(idx)]} />
            <Stats.provider_logo :if={@show_logos} logo_url={Map.get(@pivoted.logos, label)} />
            <span class="text-[10px] text-base-content/70 truncate max-w-[140px]" title={label}>
              {label}
            </span>
            <span class="text-[10px] text-base-content/50 tabular-nums">
              {format_series_val(
                Stats.sparkline_label_total(@pivoted.series[label] || %{}),
                @cost_mode?
              )}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_series_val(val, true) when is_number(val) do
    val |> Float.round(4) |> Decimal.from_float() |> Stats.money()
  end

  defp format_series_val(val, false), do: Stats.format_number(val)
  defp format_series_val(_val, true), do: "$0.00"
end
