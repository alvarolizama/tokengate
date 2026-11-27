defmodule TokengateWeb.StatsExportController do
  @moduledoc """
  CSV export endpoint for stats data.

  Accepts query params:
    * `type`   — `models`, `groups`, `providers`, `services`, `users`, `agents`,
      `errors`, `logs`, `finops` or `router` (omitted = `models`)
    * `period` — a canonical period: `today`, `yesterday`, `week`, `30d`
      (default: `week`; any other value — an old `month`/`last_month`/`7d`
      bookmark — degrades to the default instead of 500ing)
    * `model_id` — filter by model (for models type only)
    * `group_id`  — filter by group (for groups type only)
    * `view`     — `use_cases` (default) or `models` (for router type only)
    * `sort` / `direction` — optional ordering of the exported rows, with the
      same field vocabulary the tables use (`requests`, `cost`, `tokens_in`,
      `latency`, …); direction is `desc` unless `asc`. The DB-cursor exports
      (logs/errors) keep their chronological order — they are never buffered
      in memory just to be sorted.

  An UNKNOWN `type` is a `400` with
  `{"error" => "tipo de exportación desconocido"}`, never a silent models CSV:
  a download that says `models` in the filename and in the columns is a wrong
  answer, not a fallback. An omitted (or empty) `type` still defaults to
  `models` — that default was the documented behaviour, not an accident.

  The filename carries the window and the day
  (`estadisticas_proveedores_<period>_<date>.csv`), so two exports of
  different periods no longer overwrite each other in the browser.

  ## Streaming

  The response is written with `send_chunked/2` as the rows are produced:

    * the log/error exports go through `Logs.stream_logs_for_export/1` — ONE
      cursor query (`Repo.stream/2`) with the member/group/provider identity
      resolved by joins, so a 30d window no longer materializes up to 50k rows
      (plus every preloaded association) in memory;
    * the aggregate exports (models, groups, providers, services) are already
      one row per dimension, so they are chunked from the list the rollup
      returns.

  There is no row cap: a cap made the file LOOK complete while it silently
  dropped the tail. The window (`period`) is the bound, and the DB cursor and
  its transaction carry an explicit budget (ten minutes) so a long window is
  not aborted mid-file by the default DBConnection timeout.

  Returns a CSV file download with `Content-Disposition: attachment`.
  """

  use TokengateWeb, :controller
  import Ecto.Query
  require Logger

  alias Tokengate.Accounts
  alias Tokengate.Accounts.ApiKey
  alias Tokengate.Logs
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Metrics.StatsQueries
  alias Tokengate.Periods
  alias Tokengate.Repo
  alias Tokengate.SmartRouter.Analytics
  alias TokengateWeb.StatsHelpers
  alias TokengateWeb.StatsLive.Agents, as: AgentsStats
  alias TokengateWeb.TimezoneHelper

  # Rows per DB cursor fetch, and lines per socket chunk.
  @chunk_rows 500

  # Explicit budget for one export: the cursor fetch and the transaction that
  # owns it. The default 15s DBConnection timeout aborts a long window halfway
  # through the file.
  @export_timeout_ms 600_000

  # Query-param vocabulary for `sort`: the SAME names the tables expose as
  # sortable columns, mapped to the key each row map carries. A field that is
  # not here (or missing from a row) leaves the exported order untouched —
  # never a `String.to_atom/1` on user input.
  @sort_fields %{
    "requests" => :request_count,
    "request_count" => :request_count,
    "cost" => :cost_usd,
    "cost_usd" => :cost_usd,
    "share" => :share,
    "tokens_in" => :prompt_tokens,
    "prompt_tokens" => :prompt_tokens,
    "tokens_out" => :completion_tokens,
    "completion_tokens" => :completion_tokens,
    "tps" => :avg_tps,
    "avg_tps" => :avg_tps,
    "errors" => :error_count,
    "error_count" => :error_count,
    "failures" => :error_rate,
    "error_rate" => :error_rate,
    "latency" => :avg_latency_ms,
    "avg_latency_ms" => :avg_latency_ms,
    "p95" => :p95_latency_ms,
    "p95_latency_ms" => :p95_latency_ms,
    "ttft" => :avg_ttft_ms,
    "avg_ttft_ms" => :avg_ttft_ms,
    "score" => :score
  }

  def export(conn, params) do
    user = conn.assigns[:current_user]
    timezone = (user && user.timezone) || "Etc/UTC"

    period = parse_period(params["period"])
    %{from: from, to: to} = Periods.period_bounds(period, timezone)
    opts = [from: from, to: to]

    type = params["type"] || "models"

    # `?type=` (blank) is an omitted type, not a typo: the default is `models`.
    type = if type == "", do: "models", else: type

    case build_csv(user, type, params, opts, timezone, period) do
      {:ok, {filename, header, source}} ->
        stream_csv(conn, filename, header, source)

      {:error, :forbidden} ->
        json_error(conn, 403, "no autorizado")

      {:error, :unknown_type} ->
        json_error(conn, 400, "tipo de exportación desconocido")
    end
  end

  defp json_error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => message}))
  end

  ## Chunked CSV writer -----------------------------------------------------

  # Each export is `{:ok, {filename, header_cells, source}}` where source is
  # either a DB cursor (`{:db, query, row_fun}`) or an in-memory list already
  # bounded by its dimension (`{:mem, rows, row_fun}`). `row_fun` takes
  # `(row, api_key_labels)` and returns the CSV cells for that row.
  defp stream_csv(conn, filename, header, source) do
    conn =
      conn
      |> put_resp_content_type("text/csv", "utf-8")
      |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
      |> send_chunked(200)

    conn = chunk_line(conn, header)

    case source do
      {:db, query, row_fun} ->
        transaction =
          Repo.transaction(
            fn ->
              stream = Repo.stream(query, max_rows: @chunk_rows, timeout: @export_timeout_ms)
              write_rows(conn, stream, row_fun)
            end,
            timeout: @export_timeout_ms
          )

        case transaction do
          {:ok, conn} ->
            conn

          {:error, reason} ->
            # The status and the first rows are already on the wire: the file
            # is truncated and there is no way to turn it into an error page.
            # Log it loudly — a half CSV that nobody notices is the old silent
            # truncation in a new dress.
            Logger.error("stats export failed mid-stream: #{inspect(reason)}")
            conn
        end

      {:mem, rows, row_fun} ->
        write_rows(conn, rows, row_fun)
    end
  end

  defp write_rows(conn, rows, row_fun) do
    {conn, _labels} =
      rows
      |> Stream.chunk_every(@chunk_rows)
      |> Enum.reduce_while({conn, %{}}, fn batch, {conn, labels} ->
        labels = merge_api_key_labels(batch, labels)

        chunk =
          batch
          |> Enum.map(fn row -> row_fun.(row, labels) end)
          |> Enum.map_join("\n", &Enum.join(&1, ","))

        case Plug.Conn.chunk(conn, chunk <> "\n") do
          {:ok, conn} -> {:cont, {conn, labels}}
          {:error, _reason} -> {:halt, {conn, labels}}
        end
      end)

    conn
  end

  defp chunk_line(conn, cells) do
    case Plug.Conn.chunk(conn, Enum.join(cells, ",") <> "\n") do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  # The `api_key` column names the key that authenticated the request: the live
  # key's label when `api_key_id` is set, and the historical prefix when the log
  # predates the id column. ONE query per batch of new ids — never one per row,
  # and the cache survives the cursor's batches.
  defp merge_api_key_labels(rows, labels) do
    ids =
      rows
      |> Enum.map(&Map.get(&1, :api_key_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(labels, &1))

    case ids do
      [] -> labels
      ids -> Map.merge(labels, api_key_labels_by_id(ids))
    end
  end

  defp api_key_labels_by_id(ids) do
    Repo.all(from ak in ApiKey, where: ak.id in ^ids, select: {ak.id, ak.label, ak.key_prefix})
    |> Map.new(fn {id, label, prefix} -> {id, label || prefix || id} end)
  end

  defp csv_api_key(%{api_key_id: id} = row, key_labels) do
    label = id && Map.get(key_labels, id)
    csv_escape(label || Map.get(row, :api_key_prefix))
  end

  defp csv_api_key(row, _key_labels), do: csv_escape(Map.get(row, :api_key_prefix))

  defp build_csv(user, "groups", params, opts, timezone, period) do
    group_id = params["group_id"]

    cond do
      group_id && not group_export_allowed?(user, group_id) ->
        {:error, :forbidden}

      is_nil(group_id) && not admin?(user) ->
        # Sin `group_id` el export es la tabla completa
        # (`Rollup.breakdown_by_group/1`), que agrega org-wide sin filtrar por
        # `member_ids` — la MISMA razón por la que el hub no le pinta el
        # desglose de perfiles a un no-admin.
        {:error, :forbidden}

      true ->
        {:ok, build_groups_csv(user, group_id, timezone, opts, period, params)}
    end
  end

  # La tabla de proveedores es la única sección admin-only del hub (la ruta vive
  # en la live_session :admin) y su ranking NO admite scoping por miembro —
  # `Rollup.provider_ranking/2` agrega por proveedor sin filtrar por
  # `member_ids`. Un manager exportaría, entonces, el tráfico de la
  # organización entera; el mismo criterio que el drill-down de perfiles de límites: si no
  # eres admin, no baja.
  defp build_csv(user, "providers", params, opts, timezone, period) do
    if admin?(user) do
      {:ok, build_providers_csv(opts, timezone, period, params)}
    else
      {:error, :forbidden}
    end
  end

  defp build_csv(user, "errors", params, opts, timezone, period) do
    {:ok, build_errors_csv(user, params, opts, timezone, period)}
  end

  # La tabla de servicios es admin-only en el hub (la ruta vive en la
  # live_session :admin) y su agregado (`Rollup.breakdown_by_service/1`)
  # rankea por servicio sin filtrar por `member_ids`: un manager exportaría
  # el tráfico de servicios de la organización entera. Mismo criterio que el
  # ranking de proveedores: si no eres admin, no baja.
  defp build_csv(user, "services", params, opts, timezone, period) do
    if admin?(user) do
      {:ok, build_services_csv(opts, timezone, period, params)}
    else
      {:error, :forbidden}
    end
  end

  # La tabla de usuarios es admin-only en el hub (live_session :admin) y
  # `StatsQueries.breakdown_by_user/1` agrega org-wide sin filtrar por
  # `member_ids`: si no eres admin, no baja.
  defp build_csv(user, "users", params, opts, timezone, period) do
    if admin?(user) do
      {:ok, build_users_csv(opts, timezone, period, params)}
    else
      {:error, :forbidden}
    end
  end

  defp build_csv(user, "agents", params, opts, timezone, period) do
    {:ok, build_agents_csv(user, opts, timezone, period, params)}
  end

  defp build_csv(user, "logs", params, opts, timezone, period) do
    {:ok, build_logs_csv(user, params, opts, timezone, period)}
  end

  # FinOps: la economía por sujeto (usuario/servicio) del período. El agregado
  # es org-wide (`Rollup.finops_subject_scatter/1`), así que sólo admin.
  defp build_csv(user, "finops", params, opts, timezone, period) do
    if admin?(user) do
      {:ok, build_finops_csv(opts, timezone, period, params)}
    else
      {:error, :forbidden}
    end
  end

  # Router: el desglose de `SmartRouter.Analytics` sobre la misma ventana. Es
  # org-wide (no conoce scoping por miembro), así que sólo admin.
  defp build_csv(user, "router", params, opts, timezone, period) do
    if admin?(user) do
      {:ok, build_router_csv(params, opts, timezone, period)}
    else
      {:error, :forbidden}
    end
  end

  defp build_csv(user, "models", params, opts, timezone, period) do
    {:ok, build_models_csv(user, params["model_id"], timezone, opts, period, params)}
  end

  # Cualquier otro `type` (typo, bookmark viejo, param forjado) es un 400
  # explícito: el fallback silencioso a `models` devolvía un archivo que decía
  # `models` en el nombre y en las columnas — una respuesta equivocada
  # presentada como correcta.
  defp build_csv(_user, _type, _params, _opts, _timezone, _period), do: {:error, :unknown_type}

  # A group drill-down exposes every member's email and consumption, so only
  # admins may export it.
  defp group_export_allowed?(%{global_role: "admin"}, _group_id), do: true
  defp group_export_allowed?(_, _), do: false

  defp admin?(%{global_role: "admin"}), do: true
  defp admin?(_), do: false

  ## Providers CSV ---------------------------------------------------------

  # Mismo desglose que la tabla de proveedores: una fila por proveedor con su
  # tier/score y su información básica del período. Sale del MISMO agregado que
  # pinta la tabla (`Rollup.provider_ranking/2`), así el CSV y la pantalla no
  # pueden decir cosas distintas — igual que el detalle de un proveedor.
  defp build_providers_csv(opts, timezone, period, params) do
    rows = Rollup.provider_ranking(nil, opts) |> maybe_sort(params)

    header = ~w(proveedor tier score requests fallos latencia_ms p95_ms ttft_ms)

    {export_filename("estadisticas_proveedores", period, timezone), header,
     {:mem, rows, &row_to_csv_provider/2}}
  end

  defp row_to_csv_provider(row, _labels) do
    [
      csv_escape(row.provider_name),
      csv_escape(Map.get(row, :tier, "—")),
      csv_score(Map.get(row, :score)),
      row.request_count,
      csv_percent(Map.get(row, :error_rate)),
      csv_ms(Map.get(row, :avg_latency_ms)),
      csv_ms(Map.get(row, :p95_latency_ms)),
      csv_ms(Map.get(row, :avg_ttft_ms))
    ]
  end

  # Menos de 10 requests no tiene tier ni score (misma regla que la tabla):
  # se exporta vacío, no un cero que se leería como "pésimo".
  defp csv_score(nil), do: ""
  defp csv_score(score), do: to_string(score)

  defp csv_percent(nil), do: ""
  defp csv_percent(rate), do: Float.to_string(Float.round(rate * 100, 1))

  defp csv_ms(nil), do: ""
  defp csv_ms(ms), do: to_string(round(ms))

  ## Services CSV ---------------------------------------------------------

  # Una fila por servicio, del MISMO agregado que pinta la tabla del hub
  # (`Rollup.breakdown_by_service/1`): el CSV y la pantalla no pueden decir
  # cosas distintas — igual que proveedores.
  defp build_services_csv(opts, timezone, period, params) do
    rows = Rollup.breakdown_by_service(opts) |> maybe_sort(params)

    header = ~w(servicio requests costo tokens_in tokens_out tps latencia_ms)

    {export_filename("estadisticas_servicios", period, timezone), header,
     {:mem, rows, &row_to_csv_service/2}}
  end

  defp row_to_csv_service(row, _labels) do
    [
      csv_escape(row.service_name),
      row.request_count,
      decimal_to_csv(Map.get(row, :cost_usd)),
      Map.get(row, :prompt_tokens, 0),
      Map.get(row, :completion_tokens, 0),
      tps_to_csv(Map.get(row, :avg_tps)),
      latency_to_csv(Map.get(row, :avg_latency_ms))
    ]
  end

  # Sin muestras de latencia la celda va vacía, no un 0 que se leería como
  # "instantáneo" (misma regla que el score de proveedores).
  defp latency_to_csv(nil), do: ""
  defp latency_to_csv(%Decimal{} = d), do: d |> Decimal.round(0) |> Decimal.to_string()

  defp latency_to_csv(n) when is_float(n),
    do: n |> Float.round(0) |> trunc() |> Integer.to_string()

  defp latency_to_csv(n) when is_integer(n), do: Integer.to_string(n)

  ## Users CSV ------------------------------------------------------------

  defp build_users_csv(opts, timezone, period, params) do
    rows = StatsQueries.breakdown_by_user(opts) |> maybe_sort(params)

    header = ~w(usuario nombre perfiles requests costo tokens_in tokens_out tps)

    {export_filename("estadisticas_usuarios", period, timezone), header,
     {:mem, rows, &row_to_csv_user/2}}
  end

  defp row_to_csv_user(row, _labels) do
    groups =
      row
      |> Map.get(:groups, [])
      |> Enum.map_join("; ", & &1.name)

    [
      csv_escape(row.user_email),
      csv_escape(Map.get(row, :user_name) || ""),
      csv_escape(groups),
      row.request_count,
      decimal_to_csv(Map.get(row, :cost_usd)),
      Map.get(row, :prompt_tokens, 0),
      Map.get(row, :completion_tokens, 0),
      tps_to_csv(Map.get(row, :avg_tps))
    ]
  end

  ## Agents CSV -----------------------------------------------------------

  defp build_agents_csv(user, opts, timezone, period, params) do
    opts = Keyword.put(opts, :member_ids, Accounts.scope_member_ids(user))
    rows = AgentsStats.build_ranking(opts) |> maybe_sort(params)

    header =
      ~w(agente familia requests costo share_pct tokens_in tokens_out latencia_ms errores error_pct)

    {export_filename("estadisticas_agentes", period, timezone), header,
     {:mem, rows, &row_to_csv_agent/2}}
  end

  defp row_to_csv_agent(row, _labels) do
    [
      csv_escape(row.label),
      csv_escape(row.family),
      row.request_count,
      decimal_to_csv(Map.get(row, :cost_usd)),
      csv_percent(Map.get(row, :share)),
      Map.get(row, :prompt_tokens, 0),
      Map.get(row, :completion_tokens, 0),
      csv_ms(Map.get(row, :avg_latency_ms)),
      Map.get(row, :error_count, 0),
      csv_percent(Map.get(row, :error_rate))
    ]
  end

  ## Models CSV -----------------------------------------------------------

  defp build_models_csv(user, model_id, timezone, opts, period, params) do
    # Scoping: non-admin users only export consumption of their own scope
    # (managed groups for managers, own memberships for regular users).
    opts = Keyword.put(opts, :member_ids, Accounts.scope_member_ids(user))

    rows =
      if model_id do
        # Drill-down: per-provider breakdown for this model
        Rollup.breakdown_by_provider_for_model(model_id, opts)
      else
        # Full table: all models
        Rollup.breakdown_by_model(nil, opts)
      end

    rows = maybe_sort(rows, params)

    header =
      if model_id do
        ~w(proveedor_modelo requests costo tokens_in tokens_out tps)
      else
        ~w(modelo requests costo tokens_in tokens_out tps)
      end

    suffix = if model_id, do: "_modelo", else: ""

    {export_filename("estadisticas_models", period, timezone, suffix), header,
     {:mem, rows, &row_to_csv/2}}
  end

  ## Groups CSV ------------------------------------------------------------

  defp build_groups_csv(user, group_id, timezone, opts, period, params) do
    rows =
      if group_id do
        # Drill-down: members of this group
        Rollup.breakdown_by_member(group_id, opts)
      else
        # Full table: all groups the user can see
        load_group_breakdown(user, opts)
      end

    rows = maybe_sort(rows, params)

    header =
      if group_id do
        ~w(usuario perfil requests costo tokens_in tokens_out tps)
      else
        ~w(perfil requests costo tokens_in tokens_out tps)
      end

    suffix = if group_id, do: "_perfil_limites", else: ""

    {export_filename("estadisticas_perfiles", period, timezone, suffix), header,
     {:mem, rows, &row_to_csv_group/2}}
  end

  ## FinOps CSV ------------------------------------------------------------

  # Una fila por SUJETO activo del período (usuario o servicio) con su economía
  # unitaria: costo por request, cache hit, gasto desperdiciado en errores y el
  # sobrecosto de thinking/topups. Sale del MISMO agregado que la pestaña
  # FinOps (`Rollup.finops_subject_scatter/1`), así el archivo y la pantalla no
  # pueden contar dos historias.
  defp build_finops_csv(opts, timezone, period, params) do
    rows = Rollup.finops_subject_scatter(opts) |> maybe_sort(params)

    header =
      ~w(tipo sujeto requests costo_usd cost_per_req tokens_in tokens_out cache_pct errores error_waste_usd thinking_cost_usd topup_cost_usd)

    {export_filename("estadisticas_finops", period, timezone), header,
     {:mem, rows, &row_to_csv_finops/2}}
  end

  defp row_to_csv_finops(row, _labels) do
    request_count = Map.get(row, :request_count, 0)

    [
      csv_escape(row.subject_type),
      csv_escape(Map.get(row, :label)),
      request_count,
      decimal_to_csv(Map.get(row, :cost_usd)),
      unit_cost_csv(Map.get(row, :cost_usd), request_count),
      Map.get(row, :prompt_tokens, 0),
      Map.get(row, :completion_tokens, 0),
      csv_pct(cache_hit_pct(row)),
      Map.get(row, :error_count, 0),
      decimal_to_csv(Map.get(row, :error_cost_usd)),
      decimal_to_csv(Map.get(row, :think_cost_usd)),
      decimal_to_csv(Map.get(row, :topup_cost_usd))
    ]
  end

  # Costo por request a la resolución del dinero (6 decimales, la misma de
  # `provider_cost_usd`). Sin requests no hay unidad que dividir: celda vacía,
  # no un 0 que se leería como "gratis".
  defp unit_cost_csv(_cost, count) when count in [0, nil], do: ""

  defp unit_cost_csv(%Decimal{} = cost, count) do
    cost
    |> Decimal.div(Decimal.new(count))
    |> Decimal.round(6)
    |> Decimal.to_string(:normal)
  end

  defp unit_cost_csv(cost, count) when is_number(cost),
    do: unit_cost_csv(Decimal.from_float(cost * 1.0), count)

  defp unit_cost_csv(_cost, _count), do: ""

  defp cache_hit_pct(%{prompt_tokens: prompt, cache_read_tokens: hit})
       when is_integer(prompt) and prompt > 0 and is_integer(hit) and hit >= 0 do
    hit / prompt * 100
  end

  defp cache_hit_pct(_row), do: nil

  # Porcentaje YA en escala 0..100 (las columnas de `SmartRouter.Analytics` y el
  # cache hit de FinOps vienen así: `percent/2` multiplica por 100). `nil` es
  # «no hay denominador», y se exporta vacío — no un 0 falso.
  defp csv_pct(nil), do: ""
  defp csv_pct(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string(:normal)
  defp csv_pct(n) when is_float(n), do: Float.to_string(Float.round(n, 2))
  defp csv_pct(n) when is_integer(n), do: Integer.to_string(n)
  defp csv_pct(_), do: ""

  # Número suelto (throughput, tokens/request, ms de decisión): sin redondear a
  # entero, que en `tokens/seg` borraría la diferencia entre 3 y 3.9.
  defp csv_number(nil), do: ""
  defp csv_number(%Decimal{} = d), do: Decimal.to_string(d)
  defp csv_number(n) when is_float(n), do: Float.to_string(Float.round(n, 2))
  defp csv_number(n) when is_integer(n), do: Integer.to_string(n)
  defp csv_number(_), do: ""

  ## Router CSV ------------------------------------------------------------

  # `SmartRouter.Analytics` sobre la MISMA ventana del selector: el desglose por
  # caso de uso × effort tier (`use_case_breakdown/1`) o el rendimiento por
  # modelo (`model_performance/1`). Ambos son org-wide — de ahí el admin-only.
  defp build_router_csv(params, opts, timezone, period) do
    case router_view(params["view"]) do
      :models -> router_models_csv(opts, timezone, period)
      :use_cases -> router_use_cases_csv(opts, timezone, period)
    end
  end

  defp router_view(view) when view in ["models", "model_perf", "modelos"], do: :models
  defp router_view(_), do: :use_cases

  defp router_use_cases_csv(opts, timezone, period) do
    rows = Analytics.use_case_breakdown(opts)

    header =
      ~w(caso_uso effort_tier requests share_pct costo_usd costo_decision_usd baseline_usd ahorro_usd ahorro_pct cache_pct error_pct fallback_pct escalation_pct prompt_tokens completion_tokens decision_ms)

    {export_filename("estadisticas_router", period, timezone), header,
     {:mem, rows, &row_to_csv_router_use_case/2}}
  end

  defp row_to_csv_router_use_case(row, _labels) do
    [
      csv_escape(Map.get(row, :use_case_key)),
      csv_escape(Map.get(row, :effort_tier)),
      Map.get(row, :request_count, 0),
      csv_pct(Map.get(row, :share_pct)),
      decimal_to_csv(Map.get(row, :total_cost_usd)),
      decimal_to_csv(Map.get(row, :decision_cost_usd)),
      decimal_to_csv(Map.get(row, :baseline_cost_usd)),
      decimal_to_csv(Map.get(row, :net_savings_usd)),
      csv_pct(Map.get(row, :savings_pct)),
      csv_pct(Map.get(row, :cache_read_pct)),
      csv_pct(Map.get(row, :error_rate_pct)),
      csv_pct(Map.get(row, :fallback_rate_pct)),
      csv_pct(Map.get(row, :escalation_pct)),
      Map.get(row, :prompt_tokens, 0),
      Map.get(row, :completion_tokens, 0),
      csv_number(Map.get(row, :avg_decision_ms))
    ]
  end

  defp router_models_csv(opts, timezone, period) do
    rows = Analytics.model_performance(opts)

    header =
      ~w(modelo requests costo_usd decision_usd ahorro_usd tokens_por_segundo ttft_p50_ms ttft_p95_ms latencia_p50_ms latencia_p95_ms tokens_por_request cache_pct error_pct fallback_pct)

    {export_filename("estadisticas_router", period, timezone, "_modelos"), header,
     {:mem, rows, &row_to_csv_router_model/2}}
  end

  defp row_to_csv_router_model(row, _labels) do
    [
      csv_escape(Map.get(row, :model_name)),
      Map.get(row, :request_count, 0),
      decimal_to_csv(Map.get(row, :total_cost_usd)),
      decimal_to_csv(Map.get(row, :decision_cost_usd)),
      decimal_to_csv(Map.get(row, :net_savings_usd)),
      csv_number(Map.get(row, :tokens_per_sec)),
      csv_number(Map.get(row, :ttft_p50_ms)),
      csv_number(Map.get(row, :ttft_p95_ms)),
      csv_number(Map.get(row, :latency_p50_ms)),
      csv_number(Map.get(row, :latency_p95_ms)),
      csv_number(Map.get(row, :tokens_per_request)),
      csv_pct(Map.get(row, :cache_read_pct)),
      csv_pct(Map.get(row, :error_rate_pct)),
      csv_pct(Map.get(row, :fallback_rate_pct))
    ]
  end

  ## Export naming / ordering ----------------------------------------------

  # `estadisticas_<tipo>[_<sufijo>]_<period>_<día>.csv`: la ventana va en el
  # nombre, así dos exports de períodos distintos no se pisan en Descargas (el
  # nombre anterior sólo llevaba el día).
  defp export_filename(base, period, timezone, suffix \\ "") do
    "#{base}#{suffix}_#{period}_#{Periods.local_today(timezone)}.csv"
  end

  # Ordena las filas EN MEMORIA con el mismo vocabulario (y el mismo helper)
  # de las tablas, para que el CSV pueda salir en el orden que el usuario ve.
  # Sin `sort` válido el orden del agregado queda intacto — nunca se ordena
  # "en silencio" por otra columna.
  defp maybe_sort(rows, params) do
    case sort_field(params) do
      nil -> rows
      field -> StatsHelpers.sort_rows(rows, field, sort_direction(params))
    end
  end

  defp sort_field(params) do
    case Map.get(params, "sort") do
      field when is_binary(field) -> Map.get(@sort_fields, String.downcase(field))
      _ -> nil
    end
  end

  defp sort_direction(params) do
    case Map.get(params, "direction") do
      "asc" -> :asc
      _ -> :desc
    end
  end

  ## Errors CSV -----------------------------------------------------------

  defp build_errors_csv(user, params, opts, timezone, period) do
    filters =
      opts
      |> Map.new()
      |> apply_export_log_filters(params, timezone)
      |> Map.put(:status_class, "errors")
      |> Map.put(:group_member_ids, Accounts.scope_member_ids(user))

    header =
      ~w(fecha estado modelo proveedor usuario perfil api_key error_reason prov_status latencia_ms costo_usd)

    {export_filename("errores", period, timezone), header,
     {:db, Logs.stream_logs_for_export(filters), &row_to_csv_error/2}}
  end

  ## Logs CSV (full export) -----------------------------------------------

  defp build_logs_csv(user, params, opts, timezone, period) do
    filters =
      opts
      |> Map.new()
      |> apply_export_log_filters(params, timezone)
      |> Map.put(:group_member_ids, Accounts.scope_member_ids(user))

    header =
      ~w(fecha estado modelo usuario perfil agente api_key proveedor prov_key prov_status error_reason error_message streaming think effort effort_applied tokens_in tokens_out cache_read cache_creation latencia_ms ttft_ms costo_usd)

    {"logs_#{period}_#{Periods.local_today(timezone)}.csv", header,
     {:db, Logs.stream_logs_for_export(filters), &row_to_csv_log/2}}
  end

  defp apply_export_log_filters(base, params, timezone) do
    base
    |> put_param(params, "status_class", :status_class)
    |> put_param(params, "model_search", :model_search)
    |> put_param(params, "subject_type", :subject_type)
    |> put_param(params, "error_reason", :error_reason)
    |> put_param(params, "agent_type", :agent_type)
    |> put_bool_param(params, "streaming", :streaming)
    |> put_uuid_param(params, "group_id", :group_id)
    |> put_uuid_param(params, "api_key_id", :api_key_id)
    |> put_date_param(params, "from", :from, timezone, :start_of_day)
    |> put_date_param(params, "to", :to, timezone, :end_of_day)
  end

  defp put_param(acc, params, key, field) do
    case Map.get(params, key) do
      v when is_binary(v) and v != "" -> Map.put(acc, field, v)
      _ -> acc
    end
  end

  defp put_bool_param(acc, params, key, field) do
    case Map.get(params, key) do
      "true" -> Map.put(acc, field, true)
      "false" -> Map.put(acc, field, false)
      _ -> acc
    end
  end

  defp put_uuid_param(acc, params, key, field) do
    with v when is_binary(v) and v != "" <- Map.get(params, key),
         {:ok, uuid} <- Ecto.UUID.cast(v) do
      Map.put(acc, field, uuid)
    else
      _ -> acc
    end
  end

  defp put_date_param(acc, params, key, field, timezone, mode) do
    with v when is_binary(v) and v != "" <- Map.get(params, key),
         %DateTime{} = dt <- TimezoneHelper.parse_local_date(v, timezone, mode) do
      Map.put(acc, field, dt)
    else
      _ -> acc
    end
  end

  defp row_to_csv_log(log, key_labels) do
    [
      csv_escape(format_datetime_csv(log.inserted_at)),
      log.status_code,
      csv_escape(model_display_csv(log.model_requested, log.model_responded)),
      csv_escape(log.user_email),
      csv_escape(log.group_name),
      csv_escape(log.client_agent),
      csv_api_key(log, key_labels),
      csv_escape(log.provider_name),
      csv_escape(log.provider_key_prefix),
      log.provider_status_code,
      csv_escape(log.error_reason),
      csv_escape(log.error_message),
      if(log.streaming, do: "true", else: "false"),
      if(log.think, do: "true", else: "false"),
      csv_escape(log.effort),
      csv_escape(log.effort_applied),
      log.prompt_tokens,
      log.completion_tokens,
      log.cache_read_tokens,
      log.cache_creation_tokens,
      log.latency_ms,
      log.ttft_ms,
      decimal_to_csv(log.provider_cost_usd)
    ]
  end

  defp model_display_csv(requested, nil), do: requested || ""
  defp model_display_csv(requested, responded) when requested == responded, do: requested
  defp model_display_csv(requested, responded), do: "#{requested} → #{responded}"

  defp row_to_csv_error(log, key_labels) do
    [
      csv_escape(format_datetime_csv(log.inserted_at)),
      log.status_code,
      csv_escape(log.model_requested),
      csv_escape(log.provider_name),
      csv_escape(log.user_email),
      csv_escape(log.group_name),
      csv_api_key(log, key_labels),
      csv_escape(log.error_reason),
      log.provider_status_code,
      log.latency_ms,
      decimal_to_csv(log.provider_cost_usd)
    ]
  end

  defp format_datetime_csv(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_datetime_csv(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> format_datetime_csv()
  end

  ## Row serialization ----------------------------------------------------

  defp row_to_csv(row, _labels) do
    [
      csv_escape(row_label(row)),
      row.request_count,
      decimal_to_csv(Map.get(row, :cost_usd)),
      Map.get(row, :prompt_tokens, 0),
      Map.get(row, :completion_tokens, 0),
      tps_to_csv(Map.get(row, :avg_tps))
    ]
  end

  # Drill-down rows carry provider_name + provider_model ("OpenAI · gpt-4o");
  # full-table rows carry model_name.
  defp row_label(%{provider_name: name, provider_model: model})
       when is_binary(name) and is_binary(model),
       do: "#{name} · #{model}"

  defp row_label(row),
    do: Map.get(row, :provider_name) || Map.get(row, :model_name) || "—"

  defp row_to_csv_group(row, _labels) do
    # When group_id is set, rows are members (have user_email).
    # When group_id is nil, rows are groups (have group_name).
    has_email = Map.has_key?(row, :user_email)

    if has_email do
      [
        csv_escape(row.user_email),
        csv_escape(Map.get(row, :group_name, "")),
        row.request_count,
        decimal_to_csv(Map.get(row, :cost_usd)),
        Map.get(row, :prompt_tokens, 0),
        Map.get(row, :completion_tokens, 0),
        tps_to_csv(Map.get(row, :avg_tps))
      ]
    else
      [
        csv_escape(Map.get(row, :group_name, "—")),
        row.request_count,
        decimal_to_csv(Map.get(row, :cost_usd)),
        Map.get(row, :prompt_tokens, 0),
        Map.get(row, :completion_tokens, 0),
        tps_to_csv(Map.get(row, :avg_tps))
      ]
    end
  end

  # El escape vive en `TokengateWeb.CSV`: UNA implementación para los dos
  # exports. Aquí solo se delega (el export de auditoría era la copia que se
  # quedó sin el guard de fórmula — hallazgo Medio 6 de la auditoría).
  defp csv_escape(value), do: TokengateWeb.CSV.escape(value)

  defp decimal_to_csv(nil), do: "0"
  defp decimal_to_csv(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_to_csv(n), do: to_string(n)

  defp tps_to_csv(nil), do: ""
  defp tps_to_csv(n) when is_float(n), do: Float.to_string(Float.round(n, 1))
  defp tps_to_csv(n) when is_integer(n), do: Integer.to_string(n)

  ## Scoping helpers (mirror StatsLive) ----------------------------------

  defp load_group_breakdown(%{global_role: "admin"}, opts) do
    Rollup.breakdown_by_group(opts)
  end

  defp load_group_breakdown(_, _), do: []

  # The period vocabulary lives in `Tokengate.Periods` (the one source): a
  # canonical value passes through and anything else — an old `?period=month`
  # bookmark, a forged non-binary param — degrades to the default, which is
  # itself in the set. Default `week` keeps the old "a week of data" intent of
  # the previous `7d` default.
  defp parse_period(period), do: Periods.normalize_period(period)
end
