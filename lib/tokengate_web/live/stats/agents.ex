defmodule TokengateWeb.StatsLive.Agents do
  @moduledoc """
  Sección agents de /stats — ranking de gasto por agente de código
  (identidad normalizada en lectura desde `client_agent` / `agent_type`).
  """
  use TokengateWeb, :html

  alias Tokengate.Agents
  alias Tokengate.Metrics.StatsQueries
  alias TokengateWeb.StatsHelpers, as: Stats

  attr :agent_ranking, :any, required: true
  attr :period, :any, required: true
  attr :sort_field, :any, required: true
  attr :sort_direction, :any, required: true
  attr :list_search, :any, default: ""
  attr :per_page, :integer, default: 10
  attr :shown_counts, :map, required: true

  def agents(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 border border-base-300 shadow-sm" id="agent-ranking">
        <div class="card-body">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div class="min-w-0">
              <h2 class="card-title text-base">
                <.icon name="hero-command-line" class="w-5 h-5 text-base-content/60 shrink-0" />
                {gettext("Agents")}
              </h2>
              <p class="text-xs text-base-content/60 mt-1">
                {gettext(
                  "One row per coding agent identified from its client identity (X-Agent-Type / User-Agent), with its consumption for the period (%{period}).",
                  period: Stats.period_label(@period)
                )}
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-2 shrink-0">
              <Stats.list_search
                :if={Stats.has_data?(@agent_ranking)}
                id="agent-list-search"
                value={@list_search}
                placeholder={gettext("Filter by agent…")}
              />
              <.link
                href={"/stats/export?type=agents&period=#{@period}"}
                class="btn btn-sm btn-ghost"
                id="csv-agents"
              >
                <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> CSV
              </.link>
            </div>
          </div>

          <% ranks =
            @agent_ranking
            |> Enum.sort(&agent_before?/2)
            |> Enum.map(& &1.key)
            |> Enum.with_index(1)
            |> Map.new() %>
          <% rows =
            Enum.filter(
              @agent_ranking,
              &Stats.matches?(@list_search, [&1.label, &1.family, &1.key])
            ) %>
          <% list_rows = Stats.shown_rows(rows, "agent-list", @shown_counts, @per_page) %>
          <div class="mt-3 overflow-x-auto">
            <.table
              id="agents-table"
              rows={list_rows}
              row_id={fn row -> "agent-row-#{row.key}" end}
              sort_field={@sort_field}
              sort_direction={@sort_direction}
              sort_event="sort"
            >
              <:col :let={row} label={gettext("Rank")} align="center">
                <span class="inline-flex w-6 justify-center">
                  <%= if rank = Map.get(ranks, row.key) do %>
                    <Stats.medal rank={rank} />
                  <% end %>
                </span>
              </:col>
              <:col :let={row} label={gettext("Agent")} field={:label}>
                <div class="flex items-center gap-2 min-w-0">
                  <img
                    :if={row.logo}
                    src={row.logo}
                    alt=""
                    class="w-5 h-5 object-contain shrink-0"
                  />
                  <.icon
                    :if={!row.logo}
                    name={row.icon}
                    class="w-5 h-5 opacity-70 shrink-0"
                  />
                  <div class="min-w-0">
                    <.link
                      patch={~p"/stats/agents/#{row.key}?period=#{@period}"}
                      class="link link-hover font-medium truncate block"
                      id={"agent-link-#{row.key}"}
                      title={row.key}
                    >
                      {row.label}
                    </.link>
                    <div class="text-[10px] uppercase tracking-wide text-base-content/40">
                      {row.family}
                    </div>
                  </div>
                </div>
              </:col>
              <:col :let={row} label={gettext("Requests")} field={:request_count} align="right">
                <span class="font-mono tabular-nums">
                  {Stats.format_number(row.request_count)}
                </span>
              </:col>
              <:col :let={row} label={gettext("Cost")} field={:cost_usd} align="right">
                <span class="font-mono tabular-nums">
                  {Stats.money(row.cost_usd)}
                </span>
              </:col>
              <:col
                :let={row}
                label={gettext("Share")}
                field={:share}
                align="right"
                tooltip={gettext("Share of the period's cost")}
              >
                <span class="font-mono tabular-nums">{Stats.format_percent(row.share)}</span>
              </:col>
              <:col :let={row} label={gettext("Cost / req")} align="right">
                <span class="font-mono tabular-nums text-base-content/70">
                  {Stats.cost_per_request(row.cost_usd, row.request_count)}
                </span>
              </:col>
              <:col
                :let={row}
                label={gettext("Cache %")}
                align="right"
                tooltip={gettext("Percentage of prompt tokens with cache hit")}
              >
                <span class="font-mono tabular-nums">
                  {Stats.cache_hit_pct(row.prompt_tokens, Map.get(row, :cache_read_tokens, 0))}
                </span>
              </:col>
              <:col
                :let={row}
                label={gettext("Tokens in")}
                field={:prompt_tokens}
                align="right"
              >
                <span class="font-mono tabular-nums">
                  {Stats.format_number(row.prompt_tokens)}
                </span>
              </:col>
              <:col
                :let={row}
                label={gettext("Tokens out")}
                field={:completion_tokens}
                align="right"
              >
                <span class="font-mono tabular-nums">
                  {Stats.format_number(row.completion_tokens)}
                </span>
              </:col>
              <:col
                :let={row}
                label={gettext("Latency")}
                field={:avg_latency_ms}
                align="right"
              >
                <span class="font-mono tabular-nums">
                  {Stats.format_ms(row.avg_latency_ms)}
                </span>
              </:col>
              <:col :let={row} label={gettext("Errors")} field={:error_rate} align="right">
                <span class={[
                  "font-mono tabular-nums",
                  row.error_count > 0 && "text-error"
                ]}>
                  {Stats.format_number(row.error_count)}
                </span>
                <span class="ml-1 text-[10px] text-base-content/40">
                  {Stats.format_percent(row.error_rate)}
                </span>
              </:col>
              <:empty>
                <div id="agent-empty">
                  <.icon
                    name={
                      if(Stats.has_data?(@agent_ranking),
                        do: "hero-magnifying-glass",
                        else: "hero-command-line"
                      )
                    }
                    class="w-10 h-10 mx-auto mb-2 opacity-40"
                  />
                  <p>
                    {if(Stats.has_data?(@agent_ranking),
                      do: gettext("No matches."),
                      else: gettext("No agent traffic in this period.")
                    )}
                  </p>
                </div>
              </:empty>
            </.table>
          </div>
          <div
            id="agents-table-totals"
            class="mt-3 flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1 text-xs"
          >
            <span class="font-semibold text-base-content/70">
              {gettext("Total · %{count} agents", count: length(rows))}
            </span>
            <%= if totals = Stats.breakdown_total(rows) do %>
              <div class="flex flex-wrap items-baseline gap-x-5 gap-y-1 font-mono tabular-nums text-base-content/80">
                <span>
                  <span class="text-base-content/40">{gettext("Requests")}</span>
                  <span class="ml-1">{Stats.format_number(totals.request_count)}</span>
                </span>
                <span>
                  <span class="text-base-content/40">{gettext("Cost")}</span>
                  <span class="ml-1">{Stats.money(totals.cost_usd)}</span>
                </span>
                <span>
                  <span class="text-base-content/40">{gettext("Tokens in")}</span>
                  <span class="ml-1">{Stats.format_number(totals.prompt_tokens)}</span>
                </span>
                <span>
                  <span class="text-base-content/40">{gettext("Tokens out")}</span>
                  <span class="ml-1">{Stats.format_number(totals.completion_tokens)}</span>
                </span>
              </div>
            <% end %>
          </div>
          <Stats.show_more
            key="agent-list"
            id="agent-list-more"
            top={length(list_rows)}
            total={length(rows)}
          />
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Normaliza la identidad cruda de cada bucket de `StatsQueries.agent_ranking/1`
  y los mergea por `key` canónica, ordenados por costo descendente.
  """
  def build_ranking(opts) do
    StatsQueries.agent_ranking(opts)
    |> Enum.group_by(fn bucket ->
      Agents.identify(bucket.client_agent, bucket.agent_type).key
    end)
    |> Enum.map(fn {_key, buckets} -> merge_agent_buckets(buckets) end)
    |> with_agent_shares()
    |> Enum.sort(&agent_before?/2)
  end

  defp merge_agent_buckets([first | _] = buckets) do
    identity = Agents.identify(first.client_agent, first.agent_type)
    request_count = Enum.reduce(buckets, 0, &(&1.request_count + &2))
    error_count = Enum.reduce(buckets, 0, &(&1.error_count + &2))
    latency_count = Enum.reduce(buckets, 0, &(&1.latency_count + &2))

    latency_sum =
      Enum.reduce(buckets, Decimal.new(0), fn bucket, acc ->
        case bucket.avg_latency_ms do
          nil ->
            acc

          avg ->
            Decimal.add(acc, Decimal.mult(agent_decimal(avg), Decimal.new(bucket.latency_count)))
        end
      end)

    %{
      key: identity.key,
      label: identity.label,
      family: identity.family,
      version: identity.version,
      logo: identity.logo,
      icon: identity.icon,
      request_count: request_count,
      error_count: error_count,
      error_rate: if(request_count > 0, do: error_count / request_count, else: 0.0),
      cost_usd:
        Enum.reduce(buckets, Decimal.new(0), fn bucket, acc ->
          Decimal.add(acc, agent_decimal(bucket.cost_usd))
        end),
      prompt_tokens: Enum.reduce(buckets, 0, &(&1.prompt_tokens + &2)),
      completion_tokens: Enum.reduce(buckets, 0, &(&1.completion_tokens + &2)),
      cache_read_tokens: Enum.reduce(buckets, 0, &(Map.get(&1, :cache_read_tokens, 0) + &2)),
      avg_latency_ms: weighted_latency(latency_sum, latency_count)
    }
  end

  defp with_agent_shares([]), do: []

  defp with_agent_shares(rows) do
    total = Enum.reduce(rows, Decimal.new(0), fn row, acc -> Decimal.add(acc, row.cost_usd) end)

    Enum.map(rows, fn row ->
      share =
        if Decimal.compare(total, Decimal.new(0)) == :gt do
          row.cost_usd
          |> Decimal.div(total)
          |> Decimal.round(4, :half_up)
          |> Decimal.to_float()
        else
          0.0
        end

      Map.put(row, :share, share)
    end)
  end

  defp agent_before?(a, b) do
    case Decimal.compare(a.cost_usd, b.cost_usd) do
      :gt ->
        true

      :lt ->
        false

      :eq ->
        if a.request_count == b.request_count,
          do: a.label <= b.label,
          else: a.request_count > b.request_count
    end
  end

  defp weighted_latency(_sum, 0), do: nil

  defp weighted_latency(sum, count) do
    sum
    |> Decimal.div(Decimal.new(count))
    |> Decimal.round(0, :half_up)
    |> Decimal.to_integer()
  end

  defp agent_decimal(%Decimal{} = d), do: d
  defp agent_decimal(nil), do: Decimal.new(0)
  defp agent_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp agent_decimal(n) when is_float(n), do: Decimal.from_float(n)
end
