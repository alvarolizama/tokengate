defmodule TokengateWeb.StatsLive.Provider do
  @moduledoc """
  Detalle de un proveedor (`/stats/providers/:provider_id`, action `:provider`).

  Es el "interior" del ranking de proveedores: las métricas del proveedor en el
  período, los modelos que sirve y los usuarios, servicios y grupos que lo usan.
  Todo respeta el período elegido en el selector del hub — el enlace de entrada
  arrastra `?period=` y el header lo mantiene a la vista.

  El tier/score/p95 salen de la misma clasificación que la tabla de proveedores
  (`Rollup.provider_ranking/2`), para que la fila de la tabla y el detalle no
  puedan decir cosas distintas.
  """
  use TokengateWeb, :html

  import TokengateWeb.KpiHelpers, only: [kpi_card: 1]

  alias TokengateWeb.StatsHelpers, as: Stats

  attr :provider, :any, required: true
  attr :provider_ranking, :any, required: true
  attr :provider_metrics, :any, required: true
  attr :breakdown_model, :any, required: true
  attr :breakdown_user, :any, required: true
  attr :breakdown_service, :any, required: true
  attr :show_services, :boolean, default: true
  attr :breakdown_group, :any, required: true
  attr :period, :any, required: true
  attr :per_page, :integer, default: 10
  attr :shown_counts, :map, required: true
  attr :stats_loading, :boolean, default: false

  def provider(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between flex-wrap gap-3">
        <.link
          patch={~p"/stats/providers?period=#{@period}"}
          class="btn btn-sm btn-ghost"
          id="provider-back"
        >
          <.icon name="hero-arrow-left" class="w-4 h-4" /> Proveedores
        </.link>
        <span class="text-xs text-base-content/60" id="provider-metrics-period">
          Período: {Stats.period_label(@period)}
        </span>
      </div>

      <%= if @provider == nil and not @stats_loading do %>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <p class="text-sm text-base-content/40 py-6 text-center" id="provider-not-found">
              Proveedor no encontrado.
            </p>
          </div>
        </div>
      <% end %>

      <%!-- El encabezado se pinta siempre; el nombre es null-safe porque el
           render estático (pre-async) todavía no trae :provider. --%>
      <% row = @provider && Enum.find(@provider_ranking, &(&1.provider_id == @provider.id)) %>
      <div class="flex items-center gap-3 flex-wrap" id="provider-detail-header">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-server-stack" class="w-5 h-5 text-base-content/60" />
          {if @provider, do: @provider.name, else: "…"}
        </h2>
        <span :if={row} class={["badge badge-sm", Stats.tier_badge_class(row.tier)]}>
          {row.tier}
        </span>
        <span :if={row && row.score} class="text-xs text-base-content/50">
          score {row.score}
        </span>
        <span :if={@provider && is_nil(row)} class="text-xs text-base-content/50">
          sin tráfico en el período
        </span>
      </div>

      <%= if @provider do %>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <.kpi_card id="provider-kpi-cost" label="Costo" icon="hero-currency-dollar" accent="accent">
            ${Stats.format_decimal(@provider_metrics.total_cost_usd)}
          </.kpi_card>

          <.kpi_card
            id="provider-kpi-requests"
            label="Requests"
            icon="hero-arrow-trending-up"
            accent="primary"
          >
            <:sub>
              {if row, do: "#{Stats.format_percent(row.error_rate)} fallos", else: "sin tráfico"}
            </:sub>
            {Stats.format_number(@provider_metrics.request_count)}
          </.kpi_card>

          <.kpi_card
            id="provider-kpi-tokens"
            label="Tokens"
            icon="hero-cpu-chip"
            accent="primary"
            title={
              "#{Stats.format_number(@provider_metrics.total_prompt_tokens)} in / #{Stats.format_number(@provider_metrics.total_completion_tokens)} out"
            }
          >
            <span class="flex items-baseline gap-2">
              {Stats.format_compact(@provider_metrics.total_prompt_tokens)}
              <span class="text-sm text-base-content/50">in</span>
              <span class="text-base-content/30">/</span>
              {Stats.format_compact(@provider_metrics.total_completion_tokens)}
              <span class="text-sm text-base-content/50">out</span>
            </span>
          </.kpi_card>

          <.kpi_card
            id="provider-kpi-latency"
            label="Latencia"
            icon="hero-clock"
            accent="warning"
            title={
              if row,
                do:
                  "media #{Stats.format_ms(row.avg_latency_ms)} · p95 #{Stats.format_ms(row.p95_latency_ms)} · TTFT #{Stats.format_ms(row.avg_ttft_ms)}"
            }
          >
            <:sub>{if row, do: "p95 #{Stats.format_ms(row.p95_latency_ms)}"}</:sub>
            {Stats.format_ms(@provider_metrics.avg_latency_ms)}
          </.kpi_card>
        </div>

        <%!-- Modelos que sirve este proveedor --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <h3 class="card-title text-base">
              <.icon name="hero-rectangle-stack" class="w-5 h-5 text-base-content/60" />
              Modelos que sirve
            </h3>
            <%= if Stats.has_data?(@breakdown_model) do %>
              <% model_total = Stats.breakdown_total(@breakdown_model) %>
              <% model_rows =
                Stats.shown_rows(@breakdown_model, "provider-models", @shown_counts, @per_page) %>
              <div class="overflow-x-auto mt-3">
                <table class="table table-sm" id="provider-models">
                  <thead>
                    <tr>
                      <th>Modelo</th>
                      <th class="text-right">Requests</th>
                      <th class="text-right">Tokens in</th>
                      <th class="text-right">Tokens out</th>
                      <th class="text-right">TPS</th>
                      <th class="text-right">Costo</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={row <- model_rows}
                      id={"provider-model-#{row.model_id || "unknown"}"}
                    >
                      <td class="font-medium">
                        <%= if row.model_id do %>
                          <.link
                            patch={~p"/stats/models?period=#{@period}&model_id=#{row.model_id}"}
                            class="link link-hover"
                          >
                            {row.model_name}
                          </.link>
                        <% else %>
                          {row.model_name}
                        <% end %>
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(row.request_count)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(row.prompt_tokens)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(row.completion_tokens)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_tps(row.avg_tps)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        ${Stats.format_decimal(row.cost_usd)}
                      </td>
                    </tr>
                  </tbody>
                  <tfoot>
                    <tr class="font-bold bg-base-200">
                      <td>Total · {length(@breakdown_model)} modelos</td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(model_total.request_count)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(model_total.prompt_tokens)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(model_total.completion_tokens)}
                      </td>
                      <td></td>
                      <td class="text-right font-mono tabular-nums">
                        ${Stats.format_decimal(model_total.cost_usd)}
                      </td>
                    </tr>
                  </tfoot>
                </table>
              </div>
              <Stats.show_more
                key="provider-models"
                id="provider-models-more"
                top={length(model_rows)}
                total={length(@breakdown_model)}
              />
            <% else %>
              <p class="text-sm text-base-content/40 py-6 text-center">
                Sin datos en este período.
              </p>
            <% end %>
          </div>
        </div>

        <%!-- Usuarios que lo usan --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <h3 class="card-title text-base">
              <.icon name="hero-users" class="w-5 h-5 text-base-content/60" /> Usuarios que lo usan
            </h3>
            <%= if Stats.has_data?(@breakdown_user) do %>
              <% user_total = Stats.breakdown_total(@breakdown_user) %>
              <% user_rows =
                Stats.shown_rows(@breakdown_user, "provider-users", @shown_counts, @per_page) %>
              <div class="overflow-x-auto mt-3">
                <table class="table table-sm" id="provider-users">
                  <thead>
                    <tr>
                      <th>Usuario</th>
                      <th>Grupos</th>
                      <th class="text-right">Requests</th>
                      <th class="text-right">Tokens in</th>
                      <th class="text-right">Tokens out</th>
                      <th class="text-right">TPS</th>
                      <th class="text-right">Costo</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={row <- user_rows} id={"provider-user-#{row.user_id}"}>
                      <td class="font-medium">
                        <.link navigate={~p"/stats/users/#{row.user_id}"} class="link link-hover">
                          {row.user_name || row.user_email}
                        </.link>
                        <div :if={row.user_name} class="text-xs text-base-content/50">
                          {row.user_email}
                        </div>
                      </td>
                      <td class="text-xs text-base-content/60">
                        <div class="flex flex-wrap gap-1">
                          <Stats.group_link
                            :for={group <- row.groups}
                            group_id={group.id}
                            name={group.name}
                            period={@period}
                            id={"provider-user-group-#{row.user_id}-#{group.id}"}
                          />
                          <span :if={row.groups == []} class="text-base-content/30">—</span>
                        </div>
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(row.request_count)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(row.prompt_tokens)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(row.completion_tokens)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_tps(row.avg_tps)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        ${Stats.format_decimal(row.cost_usd)}
                      </td>
                    </tr>
                  </tbody>
                  <tfoot>
                    <tr class="font-bold bg-base-200">
                      <td>Total · {length(@breakdown_user)} usuarios</td>
                      <td></td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(user_total.request_count)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(user_total.prompt_tokens)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(user_total.completion_tokens)}
                      </td>
                      <td></td>
                      <td class="text-right font-mono tabular-nums">
                        ${Stats.format_decimal(user_total.cost_usd)}
                      </td>
                    </tr>
                  </tfoot>
                </table>
              </div>
              <Stats.show_more
                key="provider-users"
                id="provider-users-more"
                top={length(user_rows)}
                total={length(@breakdown_user)}
              />
            <% else %>
              <p class="text-sm text-base-content/40 py-6 text-center">
                Sin datos en este período.
              </p>
            <% end %>
          </div>
        </div>

        <%!-- Servicios que lo usan (sólo admin: la sección Servicios es admin-only) --%>
        <%= if @show_services do %>
          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body">
              <h3 class="card-title text-base">
                <.icon name="hero-wrench-screwdriver" class="w-5 h-5 text-base-content/60" />
                Servicios que lo usan
              </h3>
              <%= if Stats.has_data?(@breakdown_service) do %>
                <% service_total = Stats.breakdown_total(@breakdown_service) %>
                <% service_rows =
                  Stats.shown_rows(
                    @breakdown_service,
                    "provider-services",
                    @shown_counts,
                    @per_page
                  ) %>
                <div class="overflow-x-auto mt-3">
                  <table class="table table-sm" id="provider-services">
                    <thead>
                      <tr>
                        <th>Servicio</th>
                        <th class="text-right">Requests</th>
                        <th class="text-right">Tokens in</th>
                        <th class="text-right">Tokens out</th>
                        <th class="text-right">TPS</th>
                        <th class="text-right">Costo</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={row <- service_rows} id={"provider-service-#{row.service_id}"}>
                        <td class="font-medium">
                          <.link
                            navigate={~p"/stats/services/#{row.service_id}"}
                            class="link link-hover"
                          >
                            {row.service_name}
                          </.link>
                        </td>
                        <td class="text-right font-mono tabular-nums">
                          {Stats.format_number(row.request_count)}
                        </td>
                        <td class="text-right font-mono tabular-nums">
                          {Stats.format_number(row.prompt_tokens)}
                        </td>
                        <td class="text-right font-mono tabular-nums">
                          {Stats.format_number(row.completion_tokens)}
                        </td>
                        <td class="text-right font-mono tabular-nums">
                          {Stats.format_tps(row.avg_tps)}
                        </td>
                        <td class="text-right font-mono tabular-nums">
                          ${Stats.format_decimal(row.cost_usd)}
                        </td>
                      </tr>
                    </tbody>
                    <tfoot>
                      <tr class="font-bold bg-base-200">
                        <td>Total · {length(@breakdown_service)} servicios</td>
                        <td class="text-right font-mono tabular-nums">
                          {Stats.format_number(service_total.request_count)}
                        </td>
                        <td class="text-right font-mono tabular-nums">
                          {Stats.format_number(service_total.prompt_tokens)}
                        </td>
                        <td class="text-right font-mono tabular-nums">
                          {Stats.format_number(service_total.completion_tokens)}
                        </td>
                        <td></td>
                        <td class="text-right font-mono tabular-nums">
                          ${Stats.format_decimal(service_total.cost_usd)}
                        </td>
                      </tr>
                    </tfoot>
                  </table>
                </div>
                <Stats.show_more
                  key="provider-services"
                  id="provider-services-more"
                  top={length(service_rows)}
                  total={length(@breakdown_service)}
                />
              <% else %>
                <p class="text-sm text-base-content/40 py-6 text-center">
                  Sin datos en este período.
                </p>
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Grupos que lo usan --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <h3 class="card-title text-base">
              <.icon name="hero-user-group" class="w-5 h-5 text-base-content/60" /> Grupos que lo usan
            </h3>
            <%= if Stats.has_data?(@breakdown_group) do %>
              <% group_total = Stats.breakdown_total(@breakdown_group) %>
              <% group_rows =
                Stats.shown_rows(@breakdown_group, "provider-groups", @shown_counts, @per_page) %>
              <div class="overflow-x-auto mt-3">
                <table class="table table-sm" id="provider-groups">
                  <thead>
                    <tr>
                      <th>Grupo</th>
                      <th class="text-right">Requests</th>
                      <th class="text-right">Tokens in</th>
                      <th class="text-right">Tokens out</th>
                      <th class="text-right">TPS</th>
                      <th class="text-right">Costo</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={row <- group_rows} id={"provider-group-#{row.group_id}"}>
                      <td class="font-medium">
                        <.link
                          patch={~p"/stats/groups/#{row.group_id}?period=#{@period}"}
                          class="link link-hover"
                        >
                          {row.group_name}
                        </.link>
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(row.request_count)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(row.prompt_tokens)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(row.completion_tokens)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_tps(row.avg_tps)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        ${Stats.format_decimal(row.cost_usd)}
                      </td>
                    </tr>
                  </tbody>
                  <tfoot>
                    <tr class="font-bold bg-base-200">
                      <td>Total · {length(@breakdown_group)} grupos</td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(group_total.request_count)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(group_total.prompt_tokens)}
                      </td>
                      <td class="text-right font-mono tabular-nums">
                        {Stats.format_number(group_total.completion_tokens)}
                      </td>
                      <td></td>
                      <td class="text-right font-mono tabular-nums">
                        ${Stats.format_decimal(group_total.cost_usd)}
                      </td>
                    </tr>
                  </tfoot>
                </table>
              </div>
              <Stats.show_more
                key="provider-groups"
                id="provider-groups-more"
                top={length(group_rows)}
                total={length(@breakdown_group)}
              />
            <% else %>
              <p class="text-sm text-base-content/40 py-6 text-center">
                Sin datos en este período.
              </p>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
