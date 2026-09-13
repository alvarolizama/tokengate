defmodule TokengateWeb.StatsLive.Member do
  @moduledoc """
  Sección member de /stats. Template renderizado por
  `TokengateWeb.StatsLive` vía `<.live_component>`; helpers de formato
  vía `TokengateWeb.StatsHelpers`.
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  attr :member, :any, required: true
  attr :member_models, :any, required: true
  attr :period, :any, required: true

  def member(assigns) do
    ~H"""
    <div class="space-y-6">
      <%= if @member do %>
        <div class="flex items-center justify-between flex-wrap gap-3">
          <div>
            <h1 class="text-xl font-bold">
              {@member.user.email}
            </h1>
            <p class="text-sm text-base-content/60">
              Grupo: {@member.group.name}
            </p>
          </div>
          <.link
            patch={~p"/stats/groups?period=#{@period}&group_id=#{@member.group_id}"}
            class="btn btn-sm btn-ghost"
            id="back-to-group"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" /> Volver al grupo
          </.link>
        </div>

        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body">
            <h2 class="card-title text-base">
              <.icon name="hero-rectangle-stack" class="w-5 h-5 text-base-content/60" />
              Modelos usados
            </h2>
            <%= if @member_models != [] do %>
              <div class="overflow-x-auto mt-3">
                <table class="table table-sm table-zebra">
                  <thead>
                    <tr>
                      <th>Modelo</th>
                      <th class="text-right">Requests</th>
                      <th class="text-right">Costo</th>
                      <th class="text-right">Tokens in</th>
                      <th class="text-right">Tokens out</th>
                      <th
                        class="text-right"
                        title="Porcentaje de prompt tokens con cache hit"
                      >
                        Cache %
                      </th>
                      <th class="text-right">TPS</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={row <- @member_models}
                      id={"member-model-#{row.model_id || "unknown"}"}
                    >
                      <td class="font-medium truncate max-w-[200px]">
                        <%= if row.model_id do %>
                          <.link
                            navigate={~p"/stats/models?period=#{@period}&model_id=#{row.model_id}"}
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
                </table>
              </div>
            <% else %>
              <p class="text-sm text-base-content/40 py-6 text-center">
                Sin actividad en este período.
              </p>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
