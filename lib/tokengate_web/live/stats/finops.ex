defmodule TokengateWeb.StatsLive.Finops do
  @moduledoc """
  Pestaña FinOps (`/stats/finops`): la economía del gasto del período.

  Compara Usuarios contra Servicios (cuánto ponen y cuánto consumen), enseña
  a dónde fue cada dólar (útil, impuesto de pensamiento, desperdicio por
  error, overhead del router), qué capacidad lo consumió y quién lo gastó.

  Todas las cifras salen de los agregados de `Tokengate.Metrics.Rollup`
  cargados por `TokengateWeb.StatsLive`:

    * `finops_overview`       — `Rollup.finops_overview/1`
    * `finops_series`         — `Rollup.finops_subject_series/1`
    * `finops_request_types`  — `Rollup.finops_request_type_breakdown/1`
    * `finops_scatter`        — `Rollup.finops_subject_scatter/1`
    * `finops_models`         — `Rollup.finops_entity_scatter(:model, ...)`
    * `finops_providers`      — `Rollup.finops_entity_scatter(:provider, ...)`

  Orden de la página: quién paga (proporción + marcadores), a dónde fue cada
  dólar (anatomía), cuándo (tendencia), qué tan eficiente es cada quien
  (mapas de sujetos y de modelos/proveedores), quién gastó más (tops) y qué
  capacidad lo consumió (barras).

  Las gráficas viven en `TokengateWeb.StatsLive.FinopsCharts`.
  """

  use TokengateWeb, :html

  alias TokengateWeb.StatsHelpers, as: Stats
  alias TokengateWeb.StatsLive.FinopsCharts

  attr :overview, :any, default: nil
  attr :series, :list, default: []
  attr :request_types, :list, default: []
  attr :scatter, :list, default: []
  attr :models, :list, default: []
  attr :providers, :list, default: []
  attr :entity, :string, default: "models"
  attr :entity_metric, :string, default: "cpr"
  attr :metric, :string, default: "cost"
  attr :scatter_y, :string, default: "cpr"
  # Filtros activos (llegan de la URL) + sus opciones para los selects.
  attr :model_filter, :any, default: nil
  attr :provider_filter, :any, default: nil
  attr :user_filter, :any, default: nil
  attr :service_filter, :any, default: nil
  attr :period, :any, required: true

  def finops(assigns) do
    overview = assigns.overview || empty_overview()
    overall = overview.overall
    users = overview.users
    services = overview.services

    total_cost = overall.cost_usd
    total_requests = overall.requests

    users_cost_share = Stats.cost_share_pct(users.cost_usd, total_cost)
    services_cost_share = Stats.cost_share_pct(services.cost_usd, total_cost)
    users_req_share = Stats.share_pct(users.requests, total_requests)
    services_req_share = Stats.share_pct(services.requests, total_requests)

    top_users =
      assigns.scatter
      |> Enum.filter(&(&1.subject_type == "user"))
      |> Enum.take(5)

    top_services =
      assigns.scatter
      |> Enum.filter(&(&1.subject_type == "service"))
      |> Enum.take(5)

    hourly? = assigns.period in ["today", "yesterday"]

    model_options = Enum.map(assigns.models, &{&1.entity_id, &1.label})
    provider_options = Enum.map(assigns.providers, &{&1.entity_id, &1.label})

    user_options =
      assigns.scatter
      |> Enum.filter(&(&1.subject_type == "user"))
      |> Enum.map(&{&1.subject_id, &1.label})

    service_options =
      assigns.scatter
      |> Enum.filter(&(&1.subject_type == "service"))
      |> Enum.map(&{&1.subject_id, &1.label})

    active_filters =
      [
        {"model", assigns.model_filter, model_options},
        {"provider", assigns.provider_filter, provider_options},
        {"user", assigns.user_filter, user_options},
        {"service", assigns.service_filter, service_options}
      ]
      |> Enum.filter(fn {_kind, value, _options} -> not is_nil(value) end)
      |> Enum.map(fn {kind, value, options} ->
        label =
          case List.keyfind(options, value, 0) do
            {_, label} -> label
            nil -> value
          end

        {kind, label}
      end)

    assigns =
      assigns
      |> assign(:model_options, model_options)
      |> assign(:provider_options, provider_options)
      |> assign(:user_options, user_options)
      |> assign(:service_options, service_options)
      |> assign(:active_filters, active_filters)

    assigns =
      assigns
      |> assign(:overall, overall)
      |> assign(:users, users)
      |> assign(:services, services)
      |> assign(:total_cost, total_cost)
      |> assign(:total_requests, total_requests)
      |> assign(:users_cost_share, users_cost_share)
      |> assign(:services_cost_share, services_cost_share)
      |> assign(:users_req_share, users_req_share)
      |> assign(:services_req_share, services_req_share)
      |> assign(:top_users, top_users)
      |> assign(:top_services, top_services)
      |> assign(:hourly?, hourly?)

    ~H"""
    <div id="finops-stats" class="space-y-6">
      <div class="flex items-center justify-between flex-wrap gap-2">
        <div>
          <h2 class="text-sm font-semibold text-base-content/70 uppercase tracking-wide">
            {gettext("FinOps")}
          </h2>
          <p class="text-xs text-base-content/50">
            {gettext("Where the spend goes, who generates it and what it buys · %{period}",
              period: Stats.period_label(@period)
            )}
          </p>
        </div>
        <a
          href={"/stats/export?type=finops&period=#{@period}"}
          id="csv-finops"
          class="btn btn-xs btn-ghost"
          download
        >
          <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> {gettext("CSV")}
        </a>
      </div>

      <%!-- Filtros: bajar de una burbuja (o de un select) a "quién gastó en
           esto". Viven en la URL para compartir la vista y sobrevivir al
           selector de período. --%>
      <form
        id="finops-filter-form"
        phx-change="finops_filter"
        class="flex flex-wrap items-end gap-2"
      >
        <.filter_select
          id="finops-filter-model"
          name="model_id"
          label={gettext("Model")}
          value={@model_filter}
          options={@model_options}
          empty_label={gettext("All models")}
        />
        <.filter_select
          id="finops-filter-provider"
          name="provider_id"
          label={gettext("Provider")}
          value={@provider_filter}
          options={@provider_options}
          empty_label={gettext("All providers")}
        />
        <.filter_select
          id="finops-filter-user"
          name="user_id"
          label={gettext("User")}
          value={@user_filter}
          options={@user_options}
          empty_label={gettext("All users")}
        />
        <.filter_select
          id="finops-filter-service"
          name="service_id"
          label={gettext("Service")}
          value={@service_filter}
          options={@service_options}
          empty_label={gettext("All services")}
        />
      </form>

      <div
        :if={@active_filters != []}
        id="finops-filter-active"
        class="flex flex-wrap items-center gap-2"
      >
        <span class="text-[10px] uppercase tracking-wide text-base-content/40">
          {gettext("Filtered by")}
        </span>
        <span
          :for={{kind, label} <- @active_filters}
          id={"finops-chip-#{kind}"}
          class="badge badge-sm badge-primary badge-outline"
        >
          {label}
        </span>
        <.link
          patch={"/stats/finops?period=#{@period}"}
          id="finops-filter-clear"
          class="text-xs link link-hover"
        >
          {gettext("Clear")}
        </.link>
      </div>

      <%!-- Proporción Usuarios vs Servicios: quién paga el período --%>
      <div
        class="card bg-base-100 border border-base-300 shadow-sm"
        id="finops-proportion"
      >
        <div class="card-body p-4 gap-3">
          <div class="flex items-center justify-between flex-wrap gap-2">
            <h2 class="card-title text-base">
              <.icon name="hero-scale" class="w-5 h-5 text-base-content/60" />
              {gettext("Users vs services")}
            </h2>
            <span class="text-xs text-base-content/50 tabular-nums">
              {Stats.money(@total_cost)} · {Stats.format_number(@total_requests)} req
            </span>
          </div>

          <div class="space-y-2">
            <div>
              <div class="flex items-center justify-between text-[11px] text-base-content/60">
                <span>{gettext("Share of spend")}</span>
                <span class="tabular-nums">
                  {gettext("Users %{users}% · Services %{services}%",
                    users: @users_cost_share,
                    services: @services_cost_share
                  )}
                </span>
              </div>
              <div
                class="flex h-2.5 w-full overflow-hidden rounded-full bg-base-300/30 mt-1"
                id="finops-proportion-spend"
              >
                <div class="h-full bg-primary" style={"width: #{@users_cost_share}%"} />
                <div class="h-full bg-warning" style={"width: #{@services_cost_share}%"} />
              </div>
            </div>

            <div>
              <div class="flex items-center justify-between text-[11px] text-base-content/60">
                <span>{gettext("Share of requests")}</span>
                <span class="tabular-nums">
                  {gettext("Users %{users}% · Services %{services}%",
                    users: @users_req_share,
                    services: @services_req_share
                  )}
                </span>
              </div>
              <div
                class="flex h-2.5 w-full overflow-hidden rounded-full bg-base-300/30 mt-1"
                id="finops-proportion-requests"
              >
                <div class="h-full bg-primary" style={"width: #{@users_req_share}%"} />
                <div class="h-full bg-warning" style={"width: #{@services_req_share}%"} />
              </div>
            </div>
          </div>

          <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-[10px] text-base-content/50">
            <span class="flex items-center gap-1.5">
              <span class="w-2 h-2 rounded-sm bg-primary" /> {gettext("Users")}
            </span>
            <span class="flex items-center gap-1.5">
              <span class="w-2 h-2 rounded-sm bg-warning" /> {gettext("Services")}
            </span>
          </div>
        </div>
      </div>

      <%!-- Doble marcador: la misma economía, lado a lado --%>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4" id="finops-scorecards">
        <.scorecard
          id="finops-users-card"
          icon="hero-users"
          label={gettext("Users")}
          block={@users}
          total_cost={@total_cost}
          total_requests={@total_requests}
          per_subject_label={gettext("$/active user")}
        />
        <.scorecard
          id="finops-services-card"
          icon="hero-wrench-screwdriver"
          label={gettext("Services")}
          block={@services}
          total_cost={@total_cost}
          total_requests={@total_requests}
          per_subject_label={gettext("$/active service")}
        />
      </div>

      <FinopsCharts.spend_anatomy_bar
        id="finops-anatomy"
        overview={@overview}
        title={gettext("Where every dollar went")}
      />

      <FinopsCharts.dual_trend_chart
        id="finops-trend-chart"
        title={gettext("Spend trend")}
        hint={
          if @hourly?,
            do: gettext("hourly buckets · users vs services · the money of the period"),
            else: gettext("daily buckets · users vs services · the money of the period")
        }
        series={@series}
        metric={@metric}
        toggle_event="set_finops_metric"
      />

      <%!-- Mapas de costo unitario: SUJETOS (usuarios/servicios) y ENTIDADES
           (modelos/proveedores) lado a lado. Las líneas punteadas son la
           mediana de cada grupo: referencia, no meta. --%>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4" id="finops-efficiency">
        <FinopsCharts.efficiency_scatter
          id="finops-scatter"
          rows={@scatter}
          y_metric={@scatter_y}
          toggle_event="set_finops_scatter_y"
          period={@period}
          title={gettext("Unit cost map")}
        />

        <FinopsCharts.efficiency_scatter
          id="finops-entity-scatter"
          rows={if @entity == "models", do: @models, else: @providers}
          y_metric={@entity_metric}
          y_options={[
            {"cpr", gettext("$/req")},
            {"think", gettext("Reasoning %")}
          ]}
          toggle_event="set_finops_entity_metric"
          entity_toggle_event="set_finops_entity"
          entity_value={@entity}
          period={@period}
          title={
            if @entity == "models",
              do: gettext("Unit cost · models"),
              else: gettext("Unit cost · providers")
          }
        />
      </div>

      <%!-- La letra chica, a la vista: qué mide cada cosa y qué NO mide. Sin
           esto el mapa se lee como un veredicto de "eficiencia" que no es. --%>
      <.finops_glossary />

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4" id="finops-top">
        <.top_subjects_table
          id="finops-top-users"
          title={gettext("Top 5 users by cost")}
          subject="user"
          rows={@top_users}
          period={@period}
        />
        <.top_subjects_table
          id="finops-top-services"
          title={gettext("Top 5 services by cost")}
          subject="service"
          rows={@top_services}
          period={@period}
        />
      </div>

      <FinopsCharts.capability_bars
        id="finops-capabilities"
        rows={@request_types}
        title={gettext("Cost by capability")}
      />
    </div>
    """
  end

  ## Qué mide esta sección ---------------------------------------------------

  # Glosario visible: cada elemento del FinOps con su definición y su fórmula.
  # Existe porque el mapa se leía como un veredicto de "eficiencia" y no lo es:
  # mide costo unitario y las palancas que lo mueven. La fórmula va literal
  # (notación, no prosa) para que no se traduzca ni se desincronice del query.
  def finops_glossary(assigns) do
    rows = [
      {
        gettext("Axis X · billable requests"),
        gettext(
          "Calls that actually cost money. A local-cache hit costs $0 and stays off this axis."
        ),
        "COUNT(*) where cost > 0"
      },
      {
        gettext("Axis Y · $ per request"),
        gettext("Unit cost: what one billable call costs on average."),
        "cost ÷ billable requests"
      },
      {
        gettext("Axis Y · cache hit %"),
        gettext(
          "How much prompt context the provider served from its cache instead of re-reading it."
        ),
        "cache_read_tokens ÷ prompt_tokens × 100"
      },
      {
        gettext("Axis Y · reasoning %"),
        gettext(
          "How much of the spend went to thinking tokens the user never sees, billed as output."
        ),
        "thinking cost ÷ total cost × 100"
      },
      {
        gettext("Bubble size"),
        gettext(
          "The whole spend of that subject in the period. Big means expensive, not inefficient."
        ),
        "SUM(provider_cost_usd)"
      },
      {
        gettext("Dotted halo"),
        gettext(
          "That subject had at least one request answered by TokenGate's own cache at $0. It does not mean it uses the provider's prompt cache well."
        ),
        "local_cache_hits > 0"
      },
      {
        gettext("Dashed lines"),
        gettext(
          "The median of each group, each one against its own kind (users vs services, models vs providers), labeled with its value. A reference to see who sits above or below its own tribe — never a target."
        ),
        "median of X and Y, per group"
      },
      {
        gettext("Shaded corner"),
        gettext(
          "Subjects with more requests AND lower $/req than the median of their own group. Being here only means that: better positioned than its group's midpoint, not that the spend was worth it."
        ),
        "X > median X and Y < median Y"
      },
      {
        gettext("Cheapest per request"),
        gettext(
          "Lowest unit cost among those that clear the minimum volume. Absolute: it does not move when another subject enters or leaves the period."
        ),
        "order by $/req asc, ≥ N billable"
      },
      {
        gettext("Users vs services"),
        gettext("How the spend splits between people and machine traffic."),
        "group spend ÷ total spend"
      },
      {
        gettext("Thinking tax"),
        gettext("Money burned on internal reasoning tokens, billed as output."),
        "cost of rows with think / effort"
      },
      {
        gettext("Error waste"),
        gettext("Money paid for answers that came back as an error."),
        "SUM(cost) where status ≥ 400"
      },
      {
        gettext("Router overhead"),
        gettext(
          "What the SmartRouter classifier costs. Counted once, never mixed with served traffic."
        ),
        "cost of router_decision rows"
      },
      {
        gettext("Local cache $0"),
        gettext(
          "Requests TokenGate answered from its own ETS cache (same API key, model and body): the provider is never called and they cost $0. Different thing from the provider's prompt cache."
        ),
        "served from local cache"
      },
      {
        gettext("Capabilities"),
        gettext("Spend and volume per request type: chat, embeddings, audio, images."),
        "GROUP BY request_type"
      }
    ]

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <section id="finops-glossary" class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body p-4 gap-2">
        <h2 class="card-title text-base">
          <.icon name="hero-information-circle" class="w-5 h-5 text-base-content/60" />
          {gettext("What this section measures")}
        </h2>

        <p class="text-xs text-base-content/60">
          {gettext(
            "All of it is cost, volume and the levers that move them. There is no efficiency score: nothing here judges whether a call was worth it."
          )}
        </p>

        <dl class="grid grid-cols-1 md:grid-cols-[15rem_1fr_11rem] gap-x-4 gap-y-1.5 text-xs">
          <div :for={{concept, meaning, formula} <- @rows} class="contents">
            <dt class="text-base-content/80 font-medium">{concept}</dt>
            <dd class="text-base-content/60">{meaning}</dd>
            <dd class="font-mono text-[10px] text-base-content/40 md:text-right">{formula}</dd>
          </div>
        </dl>

        <p class="text-[11px] text-base-content/50 border-t border-base-300/60 pt-2">
          {gettext(
            "Not measured: answer quality, latency, user satisfaction or a single efficiency score. A subject that looks cheap here is only that — cheap per request. The levers this page does measure are cache hit %, error waste and thinking tax."
          )}
        </p>
      </div>
    </section>
    """
  end

  ## Select de filtro --------------------------------------------------------

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, required: true
  attr :empty_label, :string, required: true

  defp filter_select(assigns) do
    ~H"""
    <label class="flex flex-col gap-1">
      <span class="text-[10px] uppercase tracking-wide text-base-content/40">{@label}</span>
      <select id={@id} name={@name} class="select select-sm select-bordered max-w-52">
        <option value="" selected={is_nil(@value)}>{@empty_label}</option>
        <option :for={{value, label} <- @options} value={value} selected={value == @value}>
          {label}
        </option>
      </select>
    </label>
    """
  end

  ## Marcador (usuarios / servicios) ---------------------------------------

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :block, :any, required: true
  attr :total_cost, :any, required: true
  attr :total_requests, :integer, required: true
  attr :per_subject_label, :string, required: true

  defp scorecard(assigns) do
    block = assigns.block

    assigns =
      assigns
      |> assign(:cost_share, Stats.cost_share_pct(block.cost_usd, assigns.total_cost))
      |> assign(:req_share, Stats.share_pct(block.requests, assigns.total_requests))
      |> assign(:per_subject, per_active(block.cost_usd, block.active_subjects))
      |> assign(:avg_in, avg_tokens(block.prompt_tokens, block.requests))
      |> assign(:avg_out, avg_tokens(block.completion_tokens, block.requests))

    ~H"""
    <div id={@id} class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body p-4 gap-3">
        <div class="flex items-center justify-between gap-2">
          <h2 class="card-title text-base">
            <.icon name={@icon} class="w-5 h-5 text-base-content/60" />
            {@label}
          </h2>
          <span class="text-[10px] text-base-content/40">
            {gettext("%{count} active", count: Stats.format_number(@block.active_subjects))}
          </span>
        </div>

        <div class="flex items-baseline gap-2">
          <span class="text-2xl font-bold tabular-nums">{Stats.money(@block.cost_usd)}</span>
          <span class="text-xs text-base-content/50 tabular-nums">
            {gettext("%{share}% of spend", share: @cost_share)}
          </span>
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-1">
          <.score_row label={gettext("Requests")} value={Stats.format_number(@block.requests)} />
          <.score_row
            label={gettext("Share of requests")}
            value={"#{@req_share}%"}
          />
          <.score_row
            label={gettext("$/req")}
            value={Stats.cost_per_request(@block.cost_usd, @block.requests)}
          />
          <.score_row
            label={gettext("$/1M tok")}
            value={
              Stats.effective_cost_per_1m(
                @block.cost_usd,
                @block.prompt_tokens,
                @block.completion_tokens
              )
            }
          />
          <.score_row
            label={gettext("Out/In")}
            value={Stats.out_in_ratio(@block.completion_tokens, @block.prompt_tokens)}
          />
          <.score_row label={gettext("Avg in tokens/req")} value={@avg_in} />
          <.score_row label={gettext("Avg out tokens/req")} value={@avg_out} />
          <.score_row
            label={@per_subject_label}
            value={@per_subject}
          />
          <.score_row
            label={gettext("Cache hit %")}
            value={Stats.cache_hit_pct(@block.prompt_tokens, @block.cache_read_tokens)}
          />
          <.score_row
            label={gettext("Error waste")}
            value={Stats.money(@block.error_cost_usd)}
            class="text-error"
          />
          <.score_row
            label={gettext("Thinking tax")}
            value={Stats.money(@block.think_cost_usd)}
            class="text-accent"
          />
        </div>

        <p class="text-[10px] text-base-content/40 tabular-nums">
          {gettext("%{errors} failed of %{total} requests · %{recovered} recovered",
            errors: Stats.format_number(@block.error_requests),
            total: Stats.format_number(@block.requests),
            recovered: Stats.format_number(@block.fallback_recovered_count)
          )}
        </p>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :class, :string, default: nil

  defp score_row(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-2 text-xs">
      <span class="text-base-content/50 truncate">{@label}</span>
      <span class={["font-medium tabular-nums shrink-0", @class]}>{@value}</span>
    </div>
    """
  end

  ## Top 5 ----------------------------------------------------------------

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subject, :string, required: true
  attr :rows, :list, required: true
  attr :period, :any, required: true

  defp top_subjects_table(assigns) do
    ~H"""
    <div id={@id} class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body p-4 gap-2">
        <h2 class="card-title text-sm">{@title}</h2>

        <p :if={@rows == []} class="text-sm text-base-content/40 py-4 text-center">
          {gettext("No data in this period.")}
        </p>

        <div :if={@rows != []} class="overflow-x-auto">
          <table class="table table-xs" id={"#{@id}-table"}>
            <thead>
              <tr>
                <th>{if @subject == "user", do: gettext("User"), else: gettext("Service")}</th>
                <th class="text-right">{gettext("Cost")}</th>
                <th class="text-right">{gettext("$/req")}</th>
                <th class="text-right">{gettext("Cache %")}</th>
                <th class="text-right">{gettext("Error waste")}</th>
                <th class="text-right">{gettext("Top-ups")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{row, index} <- Enum.with_index(@rows, 1)} id={"#{@id}-row-#{index}"}>
                <td class="max-w-[180px] truncate">
                  <a
                    :if={row.subject_id}
                    href={subject_href(row, @period)}
                    class="link link-hover"
                    title={row.label}
                  >
                    {row.label}
                  </a>
                  <span :if={!row.subject_id}>{row.label}</span>
                </td>
                <td class="text-right tabular-nums">{Stats.money(row.cost_usd)}</td>
                <td class="text-right tabular-nums">
                  {Stats.cost_per_request(row.cost_usd, row.request_count)}
                </td>
                <td class="text-right tabular-nums">
                  {Stats.cache_hit_pct(row.prompt_tokens, row.cache_read_tokens)}
                </td>
                <td class="text-right tabular-nums text-error">
                  {Stats.money(row.error_cost_usd)}
                </td>
                <td class="text-right tabular-nums">{Stats.money(row.topup_cost_usd)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  ## Helpers ---------------------------------------------------------------

  defp per_active(_cost, active) when active in [0, nil], do: "—"

  defp per_active(cost, active) do
    cost |> Decimal.div(Decimal.new(active)) |> Stats.money()
  end

  defp avg_tokens(_tokens, requests) when requests in [0, nil], do: "—"

  defp avg_tokens(tokens, requests) do
    tokens |> div(requests) |> Stats.format_compact()
  end

  defp subject_href(%{subject_type: "user", subject_id: id}, period) when is_binary(id),
    do: "/stats/users/#{id}?period=#{period}"

  defp subject_href(%{subject_type: "service", subject_id: id}, period) when is_binary(id),
    do: "/stats/services/#{id}?period=#{period}"

  defp subject_href(_row, _period), do: "#"

  defp empty_overview do
    zero = zero_block()

    %{
      overall: zero,
      users: Map.put(zero, :active_subjects, 0),
      services: Map.put(zero, :active_subjects, 0)
    }
  end

  defp zero_block do
    %{
      requests: 0,
      cost_usd: Decimal.new(0),
      prompt_tokens: 0,
      completion_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
      error_requests: 0,
      error_cost_usd: Decimal.new(0),
      fallback_recovered_count: 0,
      think_requests: 0,
      think_cost_usd: Decimal.new(0),
      local_cache_hits: 0,
      router_decision_cost_usd: Decimal.new(0),
      prompt_tokens_saved_est: 0,
      topup_requests: 0,
      topup_cost_usd: Decimal.new(0)
    }
  end
end
