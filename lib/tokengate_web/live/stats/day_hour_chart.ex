defmodule TokengateWeb.StatsLive.DayHourChart do
  @moduledoc """
  Tarjeta "uso por hora del día, apilado por proveedor".

  Una sola tarjeta para las pestañas del hub, para que se lean como el
  mismo producto en vez de gráficas parecidas. Todas dibujan las 24 barras
  del día (zero-filled, para que el eje no desaparezca) y sólo cambian la
  ventana y las horas:

    * En vivo la dibuja sobre el día UTC en curso: la hora actual marcada y
      las horas que aún no llegan más apagadas.
    * El Resumen con "Hoy" dibuja ese MISMO día UTC — misma consulta y misma
      ventana que los KPI y el tope —, también con la hora en curso marcada:
      las horas ya completadas son las que traen tráfico y las que faltan se
      leen como lo que son.
    * El Resumen con ventanas de más de un día la dibuja sobre el perfil
      horario del período, en la hora local del usuario y sin marcas de
      "ahora" (`now_hour: nil`): un agregado de muchos días no tiene hora en
      curso.

  Todas reciben las 24 horas ya zero-filled con la misma forma
  (`%{hour, total_requests, total_cost_usd, providers}`), que devuelven
  `Tokengate.Logs.today_usage_by_hour_provider/0` (En vivo y el Resumen en
  "Hoy") y `Tokengate.Metrics.Rollup.usage_by_hour_of_day_by_provider/1` (el
  perfil horario del período).
  """
  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :title, :string, required: true
  attr :hint, :string, required: true
  # Sufijo de la hora en el tooltip: "UTC" en En vivo, "hora local" en el
  # perfil del período.
  attr :hour_suffix, :string, required: true
  attr :empty_note, :string, required: true
  # Hora en curso: se marca en la barra y apaga las etiquetas que aún no
  # llegan. `nil` en el perfil agregado del período, que no tiene "ahora".
  attr :now_hour, :integer, default: nil
  attr :class, :string, default: ""

  def day_hour_chart(assigns) do
    max = Stats.hour_usage_stacked_max(assigns.rows)
    legend = Stats.provider_legend(assigns.rows)

    assigns =
      assigns
      |> assign(:max, max)
      # Escala por el techo "nice" y no por el pico: los ticks se calculan
      # sobre el techo, así que con el pico como denominador el tick más alto
      # quedaría por encima del área de la gráfica.
      |> assign(:scale_max, Stats.nice_ceiling(max))
      |> assign(:legend, legend)
      |> assign(:has_data?, max > 0)
      |> assign(:total_requests, Enum.reduce(assigns.rows, 0, &(&1.total_requests + &2)))
      |> assign(
        :total_cost,
        Enum.reduce(assigns.rows, Decimal.new(0), fn r, acc ->
          Decimal.add(acc, r.total_cost_usd)
        end)
      )

    ~H"""
    <div class={["card bg-base-100 border border-base-300 shadow-sm", @class]} id={@id}>
      <div class="card-body p-4 gap-2">
        <div class="flex items-center justify-between flex-wrap gap-2">
          <h2 class="card-title text-base">
            <.icon name="hero-clock" class="w-5 h-5 text-base-content/60" />
            {@title}
          </h2>
          <span class="text-xs text-base-content/40 tabular-nums" id={"#{@id}-total"}>
            {total_label(@total_requests, @total_cost)}
          </span>
        </div>

        <%!-- Tipo de gráfica, unidad y ventana explícitos, como en las
             gráficas por minuto de En vivo. --%>
        <p class="text-[10px] text-base-content/40" id={"#{@id}-hint"}>
          {@hint}
        </p>

        <div class="flex gap-2 items-end mt-1">
          <%!-- Eje Y (con la escala √, los ticks se posicionan en √(tick/techo)) --%>
          <%= if @has_data? do %>
            <div class="relative h-40 w-10 shrink-0">
              <span
                :for={tick <- Stats.y_axis_ticks(@max)}
                class="absolute right-0 text-[9px] text-base-content/50 tabular-nums -translate-y-1/2"
                style={"bottom: #{y_tick_pct(tick, @scale_max)}%"}
              >
                {Stats.format_number(tick)}
              </span>
              <span class="absolute right-0 bottom-0 text-[9px] text-base-content/50 tabular-nums translate-y-1/2">
                0
              </span>
            </div>
          <% else %>
            <%!-- Sin tráfico: el hueco del eje se mantiene para que las barras
                 no se desalineen de las etiquetas de hora. --%>
            <div class="h-40 w-10 shrink-0"></div>
          <% end %>

          <div class="relative flex-1">
            <div :if={@has_data?} class="absolute inset-0 pointer-events-none">
              <div
                :for={tick <- Stats.y_axis_ticks(@max)}
                class="absolute left-0 right-0 border-t border-base-300/50 border-dashed"
                style={"bottom: #{y_tick_pct(tick, @scale_max)}%"}
              />
            </div>

            <div class="flex items-end gap-[3px] h-40 relative">
              <div
                :for={row <- @rows}
                class="relative flex-1 flex flex-col items-center justify-end h-full"
                id={"#{@id}-hour-#{row.hour}"}
                title={bar_title(row, @hour_suffix)}
              >
                <div
                  class={[
                    "w-full rounded-t overflow-hidden",
                    row.hour == @now_hour && row.total_requests > 0 && "ring-1 ring-primary/70"
                  ]}
                  style={"height: #{bar_height_pct(row.total_requests, @scale_max)}%"}
                >
                  <%= if bar_segments(row, @legend) == [] do %>
                    <div class="w-full h-full bg-base-300/20" />
                  <% else %>
                    <div class="flex flex-col-reverse h-full w-full">
                      <div
                        :for={seg <- bar_segments(row, @legend)}
                        class={["w-full", seg.color]}
                        style={"height: #{seg.height_pct}%"}
                      />
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Etiquetas de hora: una cada 3 horas, como en las gráficas por
             minuto. En En vivo las horas que aún no han llegado quedan más
             apagadas, para que la gráfica se lea como "el día hasta ahora". --%>
        <div class="flex gap-[3px] mt-1 ml-12" id={"#{@id}-hours"}>
          <span :for={row <- @rows} class="flex-1 text-center">
            <span
              :if={rem(row.hour, 3) == 0}
              class={[
                "text-[10px]",
                if(@now_hour && row.hour > @now_hour,
                  do: "text-base-content/20",
                  else: "text-base-content/40"
                )
              ]}
            >
              {Stats.hour_label(row.hour)}
            </span>
          </span>
        </div>

        <div class="flex items-center justify-between text-[10px] text-base-content/40">
          <span>{axis_start(@hour_suffix, @now_hour)}</span>
          <span :if={not @has_data?} class="text-base-content/30">
            {@empty_note}
          </span>
          <span>{axis_end(@hour_suffix, @now_hour)}</span>
        </div>

        <%!-- Leyenda: reparto de la ventana por proveedor. Top 6 por requests
             (una tarjeta a media fila no aguanta 16 colores legibles); el
             resto se resume en "+N más" — el tooltip de cada barra los sigue
             mostrando. --%>
        <div
          :if={@legend != []}
          class="flex flex-wrap items-center gap-x-3 gap-y-1 mt-1"
          id={"#{@id}-legend"}
        >
          <div :for={entry <- Enum.take(@legend, 6)} class="flex items-center gap-1.5">
            <span class={[
              "w-2 h-2 rounded-sm shrink-0",
              Stats.provider_legend_color(entry.provider_name, @legend)
            ]} />
            <Stats.provider_logo logo_url={entry.provider_logo_url} />
            <span
              class="text-[10px] text-base-content/60 truncate max-w-[110px]"
              title={entry.provider_name}
            >
              {entry.provider_name}
            </span>
            <span class="text-[10px] text-base-content/40 tabular-nums">
              {Stats.format_number(entry.requests)}
            </span>
          </div>
          <span :if={length(@legend) > 6} class="text-[10px] text-base-content/40">
            +{length(@legend) - 6} más
          </span>
        </div>
      </div>
    </div>
    """
  end

  # Total de la ventana (requests y costo) que va en la cabecera de la
  # tarjeta. Una sola cadena contigua: el HEEx parte el texto en nodos cuando
  # se interpola en varias líneas, y así el número y su unidad se leen (y se
  # asertan) como un valor único.
  defp total_label(requests, cost) do
    "#{Stats.format_number(requests)} req · $#{Stats.format_decimal(Decimal.round(cost, 4))}"
  end

  # Extremos del eje X. En En vivo el derecho es la hora en curso; en el
  # perfil del período la ventana son las 24 horas del día entero.
  defp axis_start(_suffix, nil), do: "00:00"
  defp axis_start(suffix, _now_hour), do: "00:00 #{suffix}"

  defp axis_end(_suffix, nil), do: "23:00"
  defp axis_end(suffix, now_hour), do: "ahora #{Stats.hour_label(now_hour)} #{suffix}"

  # Altura de la barra de una hora: como `Stats.hour_usage_bar_height/2` pero
  # sin el piso del 8% para las horas SIN tráfico — con el piso, una hora
  # vacía se dibujaría con la misma altura mínima que una con una request, es
  # decir tráfico inexistente.
  defp bar_height_pct(0, _max), do: 0
  defp bar_height_pct(_requests, 0), do: 0
  defp bar_height_pct(requests, max), do: Stats.hour_usage_bar_height(requests, max)

  # Posición (%) de un tick del eje Y en la misma escala √ que las barras.
  defp y_tick_pct(tick, scale_max) when scale_max > 0 do
    Float.round(:math.sqrt(tick / scale_max) * 100, 1)
  end

  # Segmentos apilados de una hora: cada proveedor ocupa su proporción del
  # total de la hora (la altura total de la barra ya viene escalada) y toma
  # el color de su índice global en la leyenda, para que barra y leyenda
  # coincidan.
  defp bar_segments(%{total_requests: total} = row, legend) when total > 0 do
    Enum.map(row.providers, fn provider ->
      %{
        provider_name: provider.provider_name,
        provider_logo_url: Map.get(provider, :provider_logo_url),
        height_pct: Float.round(provider.requests / total * 100, 1),
        color: Stats.provider_legend_color(provider.provider_name, legend)
      }
    end)
  end

  defp bar_segments(_row, _legend), do: []

  defp bar_title(%{hour: hour, total_requests: 0}, suffix) do
    "#{Stats.hour_label(hour)} #{suffix} · sin tráfico"
  end

  defp bar_title(%{hour: hour, total_requests: total} = row, suffix) do
    base =
      "#{Stats.hour_label(hour)} #{suffix} · #{Stats.format_number(total)} req · $" <>
        Stats.format_decimal(Decimal.round(row.total_cost_usd, 4))

    shown = Enum.take(row.providers, 4)
    extra = length(row.providers) - length(shown)

    providers =
      Enum.map_join(shown, " · ", fn p ->
        "#{p.provider_name} #{Stats.format_number(p.requests)}"
      end)

    providers = if extra > 0, do: providers <> " · +#{extra}", else: providers

    if providers == "", do: base, else: "#{base}\n#{providers}"
  end
end
