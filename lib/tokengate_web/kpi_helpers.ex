defmodule TokengateWeb.KpiHelpers do
  @moduledoc """
  Shared KPI card data loading and component for pages that want the
  4-card metrics summary (Costo, Requests, Tokens, TPS) without
  reimplementing the query logic in every LiveView.

  Usage in a LiveView:

      alias TokengateWeb.KpiHelpers

      # in mount or handle_params:
      socket = KpiHelpers.assign_kpi_metrics(socket, user,
        period: "today", timezone: socket.assigns[:timezone])

  Then in the template:
      <.live_component module={KpiHelpers} id="kpi-cards" metrics={@kpi_metrics} />
  Or simply call the function component:
      <KpiHelpers.kpi_cards metrics={@kpi_metrics} />
  """

  use Phoenix.Component

  import TokengateWeb.CoreComponents, only: [icon: 1]

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Metrics.DashboardCache
  alias Tokengate.Periods

  @doc """
  Assigns the 4-card KPI metrics for a calendar `period` ("today", "7d",
  "30d", "90d") computed against the user's local timezone.

  The underlying cost aggregates are served through the shared
  `Tokengate.Metrics.DashboardCache` ETS (5s TTL, keyed per user + period +
  timezone), so several connected pages sharing a scope only recompute
  once per TTL window.

      socket = KpiHelpers.assign_kpi_metrics(socket, user,
        period: "today", timezone: socket.assigns[:timezone])
  """
  def assign_kpi_metrics(socket, user, opts) do
    period = Keyword.get(opts, :period, "today")
    timezone = Keyword.get(opts, :timezone) || user.timezone || "Etc/UTC"
    %{from: from} = Periods.period_bounds(period, timezone)

    summary =
      if user.global_role == "admin" do
        DashboardCache.fetch_or_compute({:kpi_summary, :admin, period, timezone}, fn ->
          Logs.cost_summary(%{from: from})
        end)
      else
        member_ids = Accounts.scope_member_ids(user)

        cond do
          member_ids == [] ->
            empty_summary()

          true ->
            DashboardCache.fetch_or_compute({:kpi_summary, user.id, period, timezone}, fn ->
              Logs.cost_summary_for_members(member_ids, %{from: from})
            end)
        end
      end

    metrics = %{
      requests_total: summary.request_count,
      cost_usd: Map.get(summary, :total_cost_usd, Decimal.new(0)),
      prompt_tokens: summary.total_prompt_tokens,
      completion_tokens: summary.total_completion_tokens,
      cache_read_tokens: Map.get(summary, :total_cache_read_tokens, 0),
      cache_creation_tokens: Map.get(summary, :total_cache_creation_tokens, 0),
      avg_tps: Map.get(summary, :avg_tps)
    }

    assign(socket, :kpi_metrics, metrics)
  end

  def empty_metrics do
    %{
      requests_total: 0,
      cost_usd: Decimal.new(0),
      prompt_tokens: 0,
      completion_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      avg_tps: nil
    }
  end

  defp empty_summary do
    %{
      total_cost_usd: Decimal.new(0),
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_cache_read_tokens: 0,
      total_cache_creation_tokens: 0,
      request_count: 0,
      avg_tps: nil
    }
  end

  # ---------------------------------------------------------------------
  # Function component: renders the 4 KPI cards
  # ---------------------------------------------------------------------

  attr :metrics, :map, required: true
  attr :deltas, :map, default: nil

  def kpi_cards(assigns) do
    ~H"""
    <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
      <div id="kpi-cost" class="card bg-base-100 border border-base-300 shadow-sm">
        <div class="card-body p-5">
          <div class="flex items-center justify-between">
            <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Costo
            </span>
            <span class="flex items-center justify-center w-9 h-9 rounded-lg bg-accent/10">
              <.icon name="hero-currency-dollar" class="w-5 h-5 text-accent" />
            </span>
          </div>
          <p class="mt-2 text-2xl font-bold text-base-content">
            {format_decimal(@metrics.cost_usd)}
          </p>
          <div class="text-xs text-base-content/40 mt-1 flex items-center gap-1.5">
            <span>Reportado por el proveedor</span>
            <span
              :if={@deltas && @deltas[:cost_usd] != nil}
              class={[
                "font-medium tabular-nums",
                delta_color(@deltas[:cost_usd])
              ]}
            >
              {delta_arrow(@deltas[:cost_usd])} {abs_float(@deltas[:cost_usd])}%
            </span>
          </div>
        </div>
      </div>

      <div id="kpi-requests" class="card bg-base-100 border border-base-300 shadow-sm">
        <div class="card-body p-5">
          <div class="flex items-center justify-between">
            <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Requests
            </span>
            <span class="flex items-center justify-center w-9 h-9 rounded-lg bg-primary/10">
              <.icon name="hero-arrow-trending-up" class="w-5 h-5 text-primary" />
            </span>
          </div>
          <p class="mt-2 text-2xl font-bold text-base-content">
            {format_number(@metrics.requests_total)}
          </p>
          <div class="text-xs text-base-content/40 mt-1">
            <span
              :if={@deltas && @deltas[:requests_total] != nil}
              class={[
                "font-medium tabular-nums",
                delta_color(@deltas[:requests_total])
              ]}
            >
              {delta_arrow(@deltas[:requests_total])} {abs_float(@deltas[:requests_total])}%
            </span>
            <span :if={!@deltas || @deltas[:requests_total] == nil} class="text-base-content/40">
              vs período anterior
            </span>
          </div>
        </div>
      </div>

      <div id="kpi-tokens" class="card bg-base-100 border border-base-300 shadow-sm">
        <div class="card-body p-5">
          <div class="flex items-center justify-between">
            <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Tokens
            </span>
            <span class="flex items-center justify-center w-9 h-9 rounded-lg bg-primary/10">
              <.icon name="hero-cpu-chip" class="w-5 h-5 text-primary" />
            </span>
          </div>
          <div class="mt-2 flex items-baseline gap-3">
            <div>
              <p
                class="text-lg font-bold text-base-content"
                title={format_number(@metrics.prompt_tokens)}
              >
                {format_compact(@metrics.prompt_tokens)}
              </p>
              <p class="text-xs text-base-content/50">in</p>
            </div>
            <span class="text-base-content/30">/</span>
            <div>
              <p
                class="text-lg font-bold text-base-content"
                title={format_number(@metrics.completion_tokens)}
              >
                {format_compact(@metrics.completion_tokens)}
              </p>
              <p class="text-xs text-base-content/50">out</p>
            </div>
            <span class="text-base-content/30">/</span>
            <div>
              <p
                class="text-lg font-bold text-base-content"
                title={
                  format_number(
                    (@metrics.cache_read_tokens || 0) +
                      (@metrics.cache_creation_tokens || 0)
                  )
                }
              >
                {format_cache_value(
                  @metrics.cache_read_tokens,
                  @metrics.cache_creation_tokens
                )}
              </p>
              <p class="text-xs text-base-content/50">
                cache · {format_hit_rate(
                  cache_hit_rate(@metrics.cache_read_tokens, @metrics.prompt_tokens)
                )} hit
              </p>
            </div>
          </div>
          <div class="text-xs text-base-content/40 mt-1 flex items-center gap-2">
            <span
              :if={@deltas && @deltas[:prompt_tokens] != nil}
              class={[
                "font-medium tabular-nums",
                delta_color(@deltas[:prompt_tokens])
              ]}
            >
              {delta_arrow(@deltas[:prompt_tokens])} {abs_float(@deltas[:prompt_tokens])}% in
            </span>
            <span
              :if={@deltas && @deltas[:completion_tokens] != nil}
              class={[
                "font-medium tabular-nums",
                delta_color(@deltas[:completion_tokens])
              ]}
            >
              {delta_arrow(@deltas[:completion_tokens])} {abs_float(@deltas[:completion_tokens])}% out
            </span>
          </div>
        </div>
      </div>

      <div id="kpi-tps" class="card bg-base-100 border border-base-300 shadow-sm">
        <div class="card-body p-5">
          <div class="flex items-center justify-between">
            <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              TPS promedio
            </span>
            <span class="flex items-center justify-center w-9 h-9 rounded-lg bg-accent/10">
              <.icon name="hero-bolt" class="w-5 h-5 text-accent" />
            </span>
          </div>
          <p class="mt-2 text-2xl font-bold text-base-content">
            {format_tps(@metrics.avg_tps)}
          </p>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------
  # Formatting helpers (shared across pages)
  # ---------------------------------------------------------------------

  def format_decimal(%Decimal{} = d) do
    d
    |> Decimal.round(4)
    |> Decimal.to_string()
  end

  def format_decimal(n) when is_number(n), do: to_string(n)
  def format_decimal(_), do: "0"

  def format_number(n) when is_integer(n) do
    Integer.to_string(abs(n))
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
    |> then(fn s -> if n < 0, do: "-" <> s, else: s end)
  end

  def format_number(n) when is_float(n), do: Float.to_string(n)
  def format_number(_), do: "0"

  def format_compact(n) when is_integer(n) and n >= 1_000_000_000,
    do: "#{Float.round(n / 1_000_000_000, 1)}B"

  def format_compact(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  def format_compact(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  def format_compact(n) when is_integer(n), do: Integer.to_string(n)
  def format_compact(n) when is_float(n), do: format_compact(trunc(n))
  def format_compact(_), do: "0"

  def format_tps(nil), do: "—"
  def format_tps(n) when is_float(n), do: Float.round(n, 1) |> Float.to_string()
  def format_tps(n) when is_integer(n), do: to_string(n)

  @doc "Color class for a delta value: green for up, red for down."
  def delta_color(nil), do: ""
  def delta_color(delta) when is_number(delta) and delta >= 0, do: "text-success"
  def delta_color(delta) when is_number(delta), do: "text-error"

  @doc "Arrow symbol for a delta value: ↑ for up, ↓ for down."
  def delta_arrow(nil), do: ""
  def delta_arrow(delta) when is_number(delta) and delta >= 0, do: "↑"
  def delta_arrow(_delta), do: "↓"

  @doc "Absolute value of a float, formatted to 1 decimal place."
  def abs_float(nil), do: ""
  def abs_float(n) when is_float(n), do: Float.round(abs(n), 1) |> Float.to_string()
  def abs_float(n) when is_integer(n), do: abs(n) |> Integer.to_string()

  @doc """
  Cache hit rate: percentage of input tokens served from cache
  (`cache_read / prompt_tokens`). `prompt_tokens` is the provider's raw
  total and INCLUDES cached tokens (OpenAI convention), so it is the full
  input denominator. Cache creation tokens are excluded — they are a write
  cost, not a hit.

  Returns `nil` when there is no input traffic at all, so callers can
  render "—" instead of a misleading 0.0%.
  """
  def cache_hit_rate(read, prompt) when is_integer(read) and is_integer(prompt) do
    if prompt > 0 do
      Float.round(read / prompt * 100, 1)
    end
  end

  def cache_hit_rate(_, _), do: nil

  @doc "Formats a cache hit rate for display, e.g. \"42.5%\" or \"—\"."
  def format_hit_rate(nil), do: "—"
  def format_hit_rate(rate) when is_float(rate), do: "#{rate}%"
  def format_hit_rate(rate) when is_integer(rate), do: "#{rate}.0%"

  @doc """
  Compact value for the cache KPI: shows the sum (read + creation) when
  either is > 0, otherwise returns "—" so the slot stays visually empty.
  """
  def format_cache_value(read, creation)
      when read in [nil, 0] and creation in [nil, 0],
      do: "—"

  def format_cache_value(read, creation) do
    format_compact((read || 0) + (creation || 0))
  end
end
