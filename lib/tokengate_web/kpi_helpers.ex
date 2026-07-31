defmodule TokengateWeb.KpiHelpers do
  @moduledoc """
  Shared KPI card data loading and component for pages that want the
  4-card metrics summary (Costo, Requests, Tokens, TPS) without
  reimplementing the query logic in every LiveView.

  Usage in a LiveView:

      alias TokengateWeb.KpiHelpers

      # in mount or handle_params:
      socket = KpiHelpers.assign_kpi_metrics(socket, user, hours: 24)

  Then in the template:
      <.live_component module={KpiHelpers} id="kpi-cards" metrics={@kpi_metrics} />
  Or simply call the function component:
      <KpiHelpers.kpi_cards metrics={@kpi_metrics} />
  """

  use Phoenix.Component

  import TokengateWeb.CoreComponents, only: [icon: 1]

  alias Tokengate.Accounts
  alias Tokengate.Logs

  def assign_kpi_metrics(socket, user, opts) do
    hours = Keyword.get(opts, :hours, 24)
    from = hours_ago_dt(hours)

    summary =
      cond do
        user.global_role == "admin" ->
          Logs.cost_summary(%{from: from})

        true ->
          member_ids = Accounts.scope_member_ids(user)
          if member_ids == [] do
            empty_summary()
          else
            Logs.cost_summary_for_members(member_ids, %{from: from})
          end
      end

    metrics = %{
      requests_total: summary.request_count,
      cost_usd: Map.get(summary, :total_cost_usd, Decimal.new(0)),
      prompt_tokens: summary.total_prompt_tokens,
      completion_tokens: summary.total_completion_tokens,
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
      avg_tps: nil
    }
  end

  defp empty_summary do
    %{
      total_cost_usd: Decimal.new(0),
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      request_count: 0,
      avg_tps: nil
    }
  end

  defp hours_ago_dt(hours) do
    DateTime.utc_now()
    |> DateTime.add(-hours * 3600, :second)
    |> DateTime.truncate(:second)
  end

  # ---------------------------------------------------------------------
  # Function component: renders the 4 KPI cards
  # ---------------------------------------------------------------------

  attr :metrics, :map, required: true

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
          <p class="text-xs text-base-content/40 mt-1">
            Reportado por el proveedor
          </p>
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
              <p class="text-lg font-bold text-base-content" title={format_number(@metrics.prompt_tokens)}>
                {format_compact(@metrics.prompt_tokens)}
              </p>
              <p class="text-xs text-base-content/50">in</p>
            </div>
            <span class="text-base-content/30">/</span>
            <div>
              <p class="text-lg font-bold text-base-content" title={format_number(@metrics.completion_tokens)}>
                {format_compact(@metrics.completion_tokens)}
              </p>
              <p class="text-xs text-base-content/50">out</p>
            </div>
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
end
