defmodule TokengateWeb.StatsLive.Groups do
  @moduledoc """
  Sección groups de /stats. Template renderizado por
  `TokengateWeb.StatsLive` vía `<.live_component>`; helpers de formato
  vía `TokengateWeb.StatsHelpers`.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  import TokengateWeb.KpiHelpers,
    only: [cache_hit_rate: 2, format_cache_value: 2, format_hit_rate: 1]

  import TokengateWeb.StatsHelpers, only: [sort_icon: 1]

  attr :metrics, :any, required: true
  attr :breakdown_group, :any, required: true
  attr :breakdown_member, :any, required: true
  attr :breakdown_model, :any, required: true
  attr :breakdown_service, :any, required: true
  attr :drilldown_series, :any, required: true
  attr :drilldown_series_labels, :any, required: true
  attr :group_filter, :any, required: true
  attr :group, :any, default: nil
  attr :period, :any, required: true
  attr :sort_field, :any, required: true
  attr :sort_direction, :any, required: true

  def groups(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-end flex-wrap gap-3">
        <.link
          href={
            if @group_filter,
              do: "/stats/export?type=groups&period=#{@period}&group_id=#{@group_filter}",
              else: "/stats/export?type=groups&period=#{@period}"
          }
          class="btn btn-sm btn-ghost"
          id="csv-groups"
        >
          <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> CSV
        </.link>
      </div>

      <%= if @group_filter do %>
        <div class="space-y-6">
          <%!-- Breadcrumb — el hub vive en /stats/groups/:id (action :group);
               el drill-down ?group_id= de :groups usa el mismo template --%>
          <div class="flex items-center gap-2 text-xs text-base-content/60">
            <.link navigate={~p"/stats/groups?period=#{@period}"} class="hover:underline">
              Grupos
            </.link>
            <span>›</span>
            <span class="font-medium text-base-content/80">
              <%!-- null-safe: el render estático (pre-async) aún no trae :group --%>
              {if @group, do: @group.name, else: "…"}
            </span>
          </div>

          <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
            <div
              id="group-kpi-cost"
              class="card bg-base-100 border border-base-300 shadow-sm"
            >
              <div class="card-body p-5">
                <div class="flex items-center justify-between">
                  <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">Costo</span>
                  <span class={[
                    "flex items-center justify-center w-9 h-9 rounded-lg",
                    Stats.accent_bg("accent")
                  ]}>
                    <.icon
                      name="hero-currency-dollar"
                      class={["w-5 h-5", Stats.accent_text("accent")]}
                    />
                  </span>
                </div>
                <p class="mt-2 text-2xl font-bold">
                  ${Stats.format_decimal(@metrics.cost_usd)}
                </p>
              </div>
            </div>
            <div
              id="group-kpi-requests"
              class="card bg-base-100 border border-base-300 shadow-sm"
            >
              <div class="card-body p-5">
                <div class="flex items-center justify-between">
                  <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">Requests</span>
                  <span class={[
                    "flex items-center justify-center w-9 h-9 rounded-lg",
                    Stats.accent_bg("primary")
                  ]}>
                    <.icon
                      name="hero-arrow-trending-up"
                      class={["w-5 h-5", Stats.accent_text("primary")]}
                    />
                  </span>
                </div>
                <p class="mt-2 text-2xl font-bold">
                  {Stats.format_number(@metrics.requests_total)}
                </p>
              </div>
            </div>
            <div
              id="group-kpi-tokens"
              class="card bg-base-100 border border-base-300 shadow-sm"
            >
              <div class="card-body p-5">
                <div class="flex items-center justify-between">
                  <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">Tokens</span>
                  <span class={[
                    "flex items-center justify-center w-9 h-9 rounded-lg",
                    Stats.accent_bg("primary")
                  ]}>
                    <.icon name="hero-cpu-chip" class={["w-5 h-5", Stats.accent_text("primary")]} />
                  </span>
                </div>
                <div class="mt-2 flex items-baseline gap-3">
                  <div>
                    <p
                      class="text-lg font-bold"
                      title={Stats.format_number(@metrics.prompt_tokens)}
                    >
                      {Stats.format_compact(@metrics.prompt_tokens)}
                    </p>
                    <p class="text-xs text-base-content/50">in</p>
                  </div>
                  <span class="text-base-content/30">/</span>
                  <div>
                    <p
                      class="text-lg font-bold"
                      title={Stats.format_number(@metrics.completion_tokens)}
                    >
                      {Stats.format_compact(@metrics.completion_tokens)}
                    </p>
                    <p class="text-xs text-base-content/50">out</p>
                  </div>
                  <span class="text-base-content/30">/</span>
                  <div>
                    <p
                      class="text-lg font-bold"
                      title={
                        Stats.format_number(
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
              </div>
            </div>
            <div
              id="group-kpi-tps"
              class="card bg-base-100 border border-base-300 shadow-sm"
            >
              <div class="card-body p-5">
                <div class="flex items-center justify-between">
                  <span class="text-xs font-medium text-base-content/60 uppercase tracking-wide">TPS</span>
                  <span class={[
                    "flex items-center justify-center w-9 h-9 rounded-lg",
                    Stats.accent_bg("accent")
                  ]}>
                    <.icon name="hero-bolt" class={["w-5 h-5", Stats.accent_text("accent")]} />
                  </span>
                </div>
                <p class="mt-2 text-2xl font-bold">
                  {Stats.format_tps(@metrics.avg_tps)}
                </p>
              </div>
            </div>
          </div>

          <%!-- Daily usage sparkline: models over time --%>
          <%= if @drilldown_series != [] do %>
            <% pivoted = Stats.pivot_daily_series(@drilldown_series) %>
            <% spark_max = Stats.daily_series_max(pivoted) %>
            <% labels = @drilldown_series_labels %>

            <div class="card bg-base-100 border border-base-300 shadow-sm">
              <div class="card-body p-4 gap-2">
                <div class="flex items-center justify-between">
                  <h2 class="card-title text-base">
                    <.icon name="hero-chart-bar" class="w-5 h-5 text-base-content/60" />
                    Uso diario por modelo
                  </h2>
                  <span class="text-[10px] text-base-content/40 hidden sm:inline">
                    {Stats.period_label(@period)}
                  </span>
                </div>

                <div class="flex gap-4 mt-2">
                  <%!-- Chart area --%>
                  <div class="flex-1">
                    <div class="flex items-end gap-px h-32 relative">
                      <div
                        :for={day <- pivoted.days}
                        class="flex-1 flex flex-col items-center justify-end h-full group relative"
                      >
                        <%!-- Tooltip --%>
                        <div class="hidden group-hover:block absolute -top-1 -translate-y-full left-1/2 -translate-x-1/2 z-20 pointer-events-none">
                          <div class="bg-base-300 text-base-content text-[10px] rounded-md px-2 py-1 shadow-lg whitespace-nowrap">
                            <div class="font-semibold">
                              {Calendar.strftime(day, "%d %b")}
                            </div>
                            <div :for={label <- labels} class="flex justify-between gap-2">
                              <span class="truncate max-w-[100px]">{label}</span>
                              <span class="tabular-nums">
                                {Stats.format_number(Map.get(pivoted.series[label] || %{}, day, 0))}
                              </span>
                            </div>
                          </div>
                        </div>

                        <%!-- Stacked bar --%>
                        <div class="w-full flex flex-col-reverse rounded-t overflow-hidden">
                          <div
                            :for={label <- labels}
                            class={[
                              "w-full",
                              Stats.sparkline_color(Enum.find_index(labels, &(&1 == label)) || 0)
                            ]}
                            style={"height: #{Stats.sparkline_bar_height(Map.get(pivoted.series[label] || %{}, day, 0), spark_max)}%"}
                            title={"#{label}: #{Stats.format_number(Map.get(pivoted.series[label] || %{}, day, 0))}"}
                          />
                        </div>
                      </div>
                    </div>

                    <%!-- Day labels --%>
                    <div class="flex gap-px mt-1">
                      <span
                        :for={day <- pivoted.days}
                        class="flex-1 text-center text-[9px] text-base-content/40"
                      >
                        {Calendar.strftime(day, "%d")}
                      </span>
                    </div>
                  </div>

                  <%!-- Legend --%>
                  <div class="w-40 shrink-0 border-l border-base-300 pl-3">
                    <div class="text-[10px] font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                      Modelos
                    </div>
                    <div class="space-y-1.5">
                      <div
                        :for={{label, idx} <- Enum.with_index(labels)}
                        class="flex items-center gap-1.5"
                      >
                        <span class={["w-2 h-2 rounded-sm shrink-0", Stats.sparkline_color(idx)]} />
                        <span class="text-[10px] truncate flex-1">{label}</span>
                        <span class="text-[9px] text-base-content/50 shrink-0">
                          {Stats.format_number(
                            Stats.sparkline_label_total(pivoted.series[label] || %{})
                          )}
                        </span>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          <% end %>

          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-base">
                <.icon name="hero-rectangle-stack" class="w-5 h-5 text-base-content/60" />
                Modelos usados
              </h2>
              <%= if Stats.has_data?(@breakdown_model) do %>
                <% model_total = Stats.breakdown_total(@breakdown_model) %>
                <div class="overflow-x-auto mt-3">
                  <table class="table table-sm table-zebra">
                    <thead>
                      <tr>
                        <th>
                          <button
                            phx-click="sort"
                            phx-value-field="model_name"
                            class="flex items-center gap-1 hover:text-primary"
                          >
                            Modelo
                            <.sort_icon
                              field={:model_name}
                              current={@sort_field}
                              direction={@sort_direction}
                            />
                          </button>
                        </th>
                        <th class="text-right">
                          <button
                            phx-click="sort"
                            phx-value-field="request_count"
                            class="flex items-center justify-end gap-1 hover:text-primary"
                          >
                            Requests
                            <.sort_icon
                              field={:request_count}
                              current={@sort_field}
                              direction={@sort_direction}
                            />
                          </button>
                        </th>
                        <th class="text-right">
                          <button
                            phx-click="sort"
                            phx-value-field="cost_usd"
                            class="flex items-center justify-end gap-1 hover:text-primary"
                          >
                            Costo
                            <.sort_icon
                              field={:cost_usd}
                              current={@sort_field}
                              direction={@sort_direction}
                            />
                          </button>
                        </th>
                        <th class="text-right">
                          <button
                            phx-click="sort"
                            phx-value-field="prompt_tokens"
                            class="flex items-center justify-end gap-1 hover:text-primary"
                          >
                            Tokens in
                            <.sort_icon
                              field={:prompt_tokens}
                              current={@sort_field}
                              direction={@sort_direction}
                            />
                          </button>
                        </th>
                        <th class="text-right">
                          <button
                            phx-click="sort"
                            phx-value-field="completion_tokens"
                            class="flex items-center justify-end gap-1 hover:text-primary"
                          >
                            Tokens out
                            <.sort_icon
                              field={:completion_tokens}
                              current={@sort_field}
                              direction={@sort_direction}
                            />
                          </button>
                        </th>
                        <th
                          class="text-right"
                          title="Porcentaje de prompt tokens con cache hit"
                        >
                          Cache %
                        </th>
                        <th class="text-right">
                          <button
                            phx-click="sort"
                            phx-value-field="avg_tps"
                            class="flex items-center justify-end gap-1 hover:text-primary"
                          >
                            TPS
                            <.sort_icon
                              field={:avg_tps}
                              current={@sort_field}
                              direction={@sort_direction}
                            />
                          </button>
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        :for={row <- @breakdown_model}
                        id={"bd-group-model-#{row.model_id || "unknown"}"}
                      >
                        <td class="font-medium">
                          <%= if row.model_id do %>
                            <.link
                              patch={~p"/stats/models?period=#{@period}&model_id=#{row.model_id}"}
                              class="link link-hover"
                            >{row.model_name}</.link>
                          <% else %>
                            {row.model_name}
                          <% end %>
                        </td>
                        <td class="text-right font-mono">
                          {Stats.format_number(row.request_count)}
                        </td>
                        <td class="text-right font-mono">
                          ${Stats.format_decimal(row.cost_usd)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.format_number(row.prompt_tokens)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.format_number(row.completion_tokens)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.cache_hit_pct(
                            row.prompt_tokens,
                            Map.get(row, :cache_read_tokens, 0)
                          )}
                        </td>
                        <td class="text-right font-mono">{Stats.format_tps(row.avg_tps)}</td>
                      </tr>
                    </tbody>
                    <tfoot>
                      <tr class="font-bold bg-base-200">
                        <td>Total · {length(@breakdown_model)} modelos</td>
                        <td class="text-right font-mono">
                          {Stats.format_number(model_total.request_count)}
                        </td>
                        <td class="text-right font-mono">
                          ${Stats.format_decimal(model_total.cost_usd)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.format_number(model_total.prompt_tokens)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.format_number(model_total.completion_tokens)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.cache_hit_pct(
                            model_total.prompt_tokens,
                            model_total.cache_read_tokens
                          )}
                        </td>
                        <td></td>
                      </tr>
                    </tfoot>
                  </table>
                </div>
              <% else %>
                <p class="text-sm text-base-content/40 py-6 text-center">
                  Sin datos para este periodo.
                </p>
              <% end %>
            </div>
          </div>
          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-base">
                <.icon name="hero-user" class="w-5 h-5 text-base-content/60" /> Miembros del grupo
              </h2>
              <%= if Stats.has_data?(@breakdown_member) do %>
                <% member_total = Stats.breakdown_total(@breakdown_member) %>
                <div class="overflow-x-auto mt-3">
                  <table class="table table-sm table-zebra">
                    <thead>
                      <tr>
                        <th>
                          <button
                            phx-click="sort"
                            phx-value-field="user_email"
                            class="flex items-center gap-1 hover:text-primary"
                          >
                            Usuario
                            <.sort_icon
                              field={:user_email}
                              current={@sort_field}
                              direction={@sort_direction}
                            />
                          </button>
                        </th>
                        <th class="text-right">
                          <button
                            phx-click="sort"
                            phx-value-field="request_count"
                            class="flex items-center justify-end gap-1 hover:text-primary"
                          >
                            Requests
                            <.sort_icon
                              field={:request_count}
                              current={@sort_field}
                              direction={@sort_direction}
                            />
                          </button>
                        </th>
                        <th class="text-right">
                          <button
                            phx-click="sort"
                            phx-value-field="cost_usd"
                            class="flex items-center justify-end gap-1 hover:text-primary"
                          >
                            Costo
                            <.sort_icon
                              field={:cost_usd}
                              current={@sort_field}
                              direction={@sort_direction}
                            />
                          </button>
                        </th>
                        <th class="text-right">
                          <button
                            phx-click="sort"
                            phx-value-field="prompt_tokens"
                            class="flex items-center justify-end gap-1 hover:text-primary"
                          >
                            Tokens in
                            <.sort_icon
                              field={:prompt_tokens}
                              current={@sort_field}
                              direction={@sort_direction}
                            />
                          </button>
                        </th>
                        <th class="text-right">
                          <button
                            phx-click="sort"
                            phx-value-field="completion_tokens"
                            class="flex items-center justify-end gap-1 hover:text-primary"
                          >
                            Tokens out
                            <.sort_icon
                              field={:completion_tokens}
                              current={@sort_field}
                              direction={@sort_direction}
                            />
                          </button>
                        </th>
                        <th
                          class="text-right"
                          title="Porcentaje de prompt tokens con cache hit"
                        >
                          Cache %
                        </th>
                        <th class="text-right">
                          <button
                            phx-click="sort"
                            phx-value-field="avg_tps"
                            class="flex items-center justify-end gap-1 hover:text-primary"
                          >
                            TPS
                            <.sort_icon
                              field={:avg_tps}
                              current={@sort_field}
                              direction={@sort_direction}
                            />
                          </button>
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        :for={row <- @breakdown_member}
                        id={"bd-group-member-#{row.group_member_id}"}
                      >
                        <td class="font-mono text-sm">
                          <.link
                            navigate={~p"/stats/users/#{row.user_id}"}
                            class="link link-hover"
                          >
                            {row.user_email}
                          </.link>
                        </td>
                        <td class="text-right font-mono">
                          {Stats.format_number(row.request_count)}
                        </td>
                        <td class="text-right font-mono">
                          ${Stats.format_decimal(row.cost_usd)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.format_number(row.prompt_tokens)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.format_number(row.completion_tokens)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.cache_hit_pct(
                            row.prompt_tokens,
                            Map.get(row, :cache_read_tokens, 0)
                          )}
                        </td>
                        <td class="text-right font-mono">{Stats.format_tps(row.avg_tps)}</td>
                      </tr>
                    </tbody>
                    <tfoot>
                      <tr class="font-bold bg-base-200">
                        <td>Total · {Stats.distinct_users(@breakdown_member)} usuarios</td>
                        <td class="text-right font-mono">
                          {Stats.format_number(member_total.request_count)}
                        </td>
                        <td class="text-right font-mono">
                          ${Stats.format_decimal(member_total.cost_usd)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.format_number(member_total.prompt_tokens)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.format_number(member_total.completion_tokens)}
                        </td>
                        <td class="text-right font-mono">
                          {Stats.cache_hit_pct(
                            member_total.prompt_tokens,
                            member_total.cache_read_tokens
                          )}
                        </td>
                        <td></td>
                      </tr>
                    </tfoot>
                  </table>
                </div>
              <% else %>
                <p class="text-sm text-base-content/40 py-6 text-center">
                  Sin datos para este periodo.
                </p>
              <% end %>
            </div>
          </div>
          <button
            phx-click="clear_group_filter"
            class="btn btn-sm btn-ghost"
            id="clear-group-filter"
          >
            <.icon name="hero-x-mark" class="w-4 h-4" /> Quitar filtro de grupo
          </button>
        </div>
      <% else %>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">
              <.icon name="hero-user-group" class="w-5 h-5 text-base-content/60" /> Todos los grupos
            </h2>
            <%= if Stats.has_data?(@breakdown_group) do %>
              <% group_total = Stats.breakdown_total(@breakdown_group) %>
              <div class="overflow-x-auto mt-3">
                <table class="table table-sm table-zebra">
                  <thead>
                    <tr>
                      <th>
                        <button
                          phx-click="sort"
                          phx-value-field="group_name"
                          class="flex items-center gap-1 hover:text-primary"
                        >
                          Grupo
                          <.sort_icon
                            field={:group_name}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th class="text-right">
                        <button
                          phx-click="sort"
                          phx-value-field="request_count"
                          class="flex items-center justify-end gap-1 hover:text-primary"
                        >
                          Requests
                          <.sort_icon
                            field={:request_count}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th class="text-right">
                        <button
                          phx-click="sort"
                          phx-value-field="cost_usd"
                          class="flex items-center justify-end gap-1 hover:text-primary"
                        >
                          Costo
                          <.sort_icon
                            field={:cost_usd}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th class="text-right">
                        <button
                          phx-click="sort"
                          phx-value-field="prompt_tokens"
                          class="flex items-center justify-end gap-1 hover:text-primary"
                        >
                          Tokens in
                          <.sort_icon
                            field={:prompt_tokens}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th class="text-right">
                        <button
                          phx-click="sort"
                          phx-value-field="completion_tokens"
                          class="flex items-center justify-end gap-1 hover:text-primary"
                        >
                          Tokens out
                          <.sort_icon
                            field={:completion_tokens}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                      <th
                        class="text-right"
                        title="Porcentaje de prompt tokens con cache hit"
                      >
                        Cache %
                      </th>
                      <th class="text-right">
                        <button
                          phx-click="sort"
                          phx-value-field="avg_tps"
                          class="flex items-center justify-end gap-1 hover:text-primary"
                        >
                          TPS
                          <.sort_icon
                            field={:avg_tps}
                            current={@sort_field}
                            direction={@sort_direction}
                          />
                        </button>
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={row <- @breakdown_group} id={"bd-group-#{row.group_id}"}>
                      <td class="font-medium">
                        <.link
                          patch={~p"/stats/groups/#{row.group_id}?period=#{@period}"}
                          class="link link-hover"
                        >{row.group_name}</.link>
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(row.request_count)}
                      </td>
                      <td class="text-right font-mono">
                        ${Stats.format_decimal(row.cost_usd)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(row.prompt_tokens)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(row.completion_tokens)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.cache_hit_pct(
                          row.prompt_tokens,
                          Map.get(row, :cache_read_tokens, 0)
                        )}
                      </td>
                      <td class="text-right font-mono">{Stats.format_tps(row.avg_tps)}</td>
                    </tr>
                  </tbody>
                  <tfoot>
                    <tr class="font-bold bg-base-200">
                      <td>Total · {length(@breakdown_group)} grupos</td>
                      <td class="text-right font-mono">
                        {Stats.format_number(group_total.request_count)}
                      </td>
                      <td class="text-right font-mono">
                        ${Stats.format_decimal(group_total.cost_usd)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(group_total.prompt_tokens)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.format_number(group_total.completion_tokens)}
                      </td>
                      <td class="text-right font-mono">
                        {Stats.cache_hit_pct(
                          group_total.prompt_tokens,
                          group_total.cache_read_tokens
                        )}
                      </td>
                      <td></td>
                    </tr>
                  </tfoot>
                </table>
              </div>
            <% else %>
              <p class="text-sm text-base-content/40 py-6 text-center">
                Sin datos para este periodo.
              </p>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
