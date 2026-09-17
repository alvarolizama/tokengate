# Demo seeds — un mes de uso sintético para probar toda la app.
#
# Run with:  mix ecto.demo      (alias de `mix run priv/repo/demo_seeds.exs`)
#
# Crea un universo autocontenido y **re-ejecutable**: todo lo que este script
# genera queda marcado (usuarios `@demo.tokengate`, grupos/servicios/labs con
# nombres fijos) y el primer paso borra la corrida anterior. Nunca toca datos
# ajenos: los modelos, proveedores y usuarios que ya existían se reutilizan
# como rutas reales sin modificarse.
#
# Alcance del dataset (31 días):
#
#   * 12 usuarios demo + membresía demo del admin real (dashboard personal).
#   * 4 grupos: sub activa, sub con rollover, sub pausada y sub por debajo del
#     consumo real (para ver el estado agotado / 402).
#   * 3 servicios máquina (con sub propia, one-shot y sin sub) + supervisores.
#   * 2 proveedores custom + credenciales nuevas sobre builtins, una de ellas
#     en `error` y otra `disabled` (para probar reactivación).
#   * 11 modelos nuevos (9 llm + 2 embedding) con market pricing, precio manual,
#     `prompt_cache_enabled`, `pinned`, TTL sticky, `extra_body`
#     y rutas exclusivas de usuario / grupo / servicio.
#   * ~11k `request_logs` repartidos por hora local de cada sujeto, con
#     streaming, thinking, caché, fallbacks, errores de gate y de proveedor.
#   * Rollup horario (`request_metrics_hourly`) reconstruido para el rango.
#   * Crédito: subs de grupo/servicio, rollover, pausada, top-ups (activo,
#     agotado, vencido), sub directa y exenciones del tope global.
#   * Webhooks de observabilidad, lab custom, audit logs del mes y cap global.
#
# Al terminar imprime un resumen y las API keys demo para pegarle al proxy.

defmodule Tokengate.DemoSeeds do
  @moduledoc false

  import Ecto.Query

  alias Tokengate.Accounts
  alias Tokengate.Accounts.{ApiKey, Group, GroupMember, Service, User}
  alias Tokengate.Auditing.AuditLog
  alias Tokengate.Budgets.{Exemption, Exemptions}
  alias Tokengate.Credits
  alias Tokengate.Credits.Subscription
  alias Tokengate.GlobalSettings
  alias Tokengate.Logs
  alias Tokengate.Logs.{PartitionWorker, RequestLog}
  alias Tokengate.Metrics.RequestMetricsHourly
  alias Tokengate.Metrics.Rollup.HourlyAggregate
  alias Tokengate.Observability
  alias Tokengate.Observability.Destination
  alias Tokengate.Providers

  alias Tokengate.Providers.{
    Credential,
    GroupMemberExtraModel,
    Model,
    ModelProvider,
    Provider,
    ServiceModel
  }

  alias Tokengate.Repo

  # ---------------------------------------------------------------------------
  # Constantes de la demo
  # ---------------------------------------------------------------------------

  @email_domain "demo.tokengate"
  @password "DemoPassw0rd!2026"
  @days 31
  @batch_size 1_000

  @group_names ["Platform Crew", "Growth Squad", "Data Lab", "Contractors"]
  @service_names ["ci-eval-bot", "docs-rag", "batch-reports"]
  @custom_providers ["Internal LiteLLM", "VLLM Cluster"]
  @custom_lab_key "acme"
  @custom_lab_name "Acme Research"

  @sub_names [
    "Platform Crew · mensual",
    "Growth Squad · mensual (rollover)",
    "Data Lab · mensual (pausada)",
    "Contractors · mensual",
    "docs-rag · mensual",
    "ci-eval-bot · one-shot",
    "Top-up · Ana",
    "Top-up · Luis (agotado)",
    "Top-up · Iván (vencido)",
    "Sub directa · Sofía"
  ]

  @demo_models [
    "claude-opus-4.7",
    "claude-sonnet-4.7",
    "gpt-5",
    "gpt-5-mini",
    "gemini-3-pro",
    "grok-4",
    "kimi-k2",
    "glm-5.2",
    "qwen3-coder",
    "bge-m3",
    "text-embedding-3-large"
  ]

  # Credenciales demo: clave del provider builtin → nombre de la credencial.
  @credential_by_key %{
    "zai" => "prod",
    "moonshotai" => "prod",
    "opencode" => "prod",
    "zai-coding-plan" => "plan",
    "openrouter" => "overflow"
  }

  # Credenciales extra (para probar `error` y `disabled`).
  @extra_credentials [{"openrouter", "legacy-2024"}, {"zai", "overflow"}]

  @builtin_providers ["openrouter", "zai", "moonshotai", "opencode", "zai-coding-plan"]

  # Precio por 1M tokens (USD) por **provider_model**: es la tabla con la que se
  # calcula el `provider_cost_usd` de cada log (lo que el upstream "reporta"),
  # con una varianza ±12% para que el comparativo real vs estimado de la
  # calculadora no sea una línea plana.
  @pricing %{
    "anthropic/claude-opus-4.7" => {15.0, 75.0, 1.50},
    "anthropic/claude-sonnet-4.7" => {3.0, 15.0, 0.30},
    "openai/gpt-5" => {1.25, 10.0, 0.125},
    "gpt-5" => {1.20, 9.60, 0.12},
    "openai/gpt-5-mini" => {0.25, 2.0, 0.025},
    "gpt-5-mini" => {0.24, 1.90, 0.024},
    "google/gemini-3-pro" => {1.25, 10.0, 0.31},
    "x-ai/grok-4" => {3.0, 15.0, 0.75},
    "moonshotai/kimi-k2-0905" => {0.60, 2.50, 0.12},
    "z-ai/glm-5.2" => {0.58, 2.10, 0.11},
    "glm-5.2" => {0.60, 2.20, 0.11},
    "GLM-5.2-AWQ" => {0.05, 0.18, 0.01},
    "qwen3-coder" => {0.30, 1.20, 0.06},
    "Qwen3-Coder-480B" => {0.04, 0.16, 0.01},
    "openai/text-embedding-3-large" => {0.13, 0.0, 0.0},
    "/models/bge-m3" => {0.010, 0.0, 0.0},
    # Rutas preexistentes del operador — precio asumido para el demo.
    "deepseek/deepseek-v4-flash" => {0.28, 0.42, 0.028},
    "accounts/fireworks/models/gpt-oss-120b" => {0.15, 0.60, 0.06}
  }

  # Agentes cliente: {X-Agent-Type, X-Title/User-Agent, peso}. Pesos enteros:
  # `:rand.uniform/1` sólo acepta enteros.
  @agents [
    {"claude-code", "claude-code/2.1.4", 34},
    {"cursor", "Cursor/0.51.2 (darwin arm64)", 16},
    {"codex-cli", "codex-cli/0.48.0", 12},
    {"opencode", "opencode/1.2.3", 9},
    {"zed", "Zed/0.186.4", 7},
    {"roo-code", "Roo-Code/3.28.1", 5},
    {"cline", "Cline/3.4.0", 4},
    {"api", "python-requests/2.32.3", 8},
    {"unknown", nil, 5}
  ]

  @agent_weights Enum.map(@agents, fn {_a, _c, w} -> w end)
  @hour_weights [
    {7, 3},
    {8, 6},
    {9, 12},
    {10, 14},
    {11, 13},
    {12, 9},
    {13, 8},
    {14, 11},
    {15, 12},
    {16, 10},
    {17, 7},
    {18, 4},
    {20, 3},
    {22, 2}
  ]

  @night_hour_weights [{2, 14}, {3, 18}, {4, 14}, {5, 8}, {13, 10}, {14, 12}, {15, 10}, {22, 14}]

  # ---------------------------------------------------------------------------
  # Entrada
  # ---------------------------------------------------------------------------

  def run do
    :rand.seed(:exsss, {20_260_916, 7, 13})

    IO.puts("\n=== TokenGate · demo seeds (31 días de uso) ===\n")

    wipe!()
    ensure_partitions()

    providers = seed_providers()
    models = seed_models(providers)
    org = seed_org()
    credits = seed_credits(org)
    org = org |> Map.put(:services, credits.services) |> Map.put(:credits, credits)

    seed_exclusives(models, org)
    seed_observability(org)
    seed_misc(org)

    ctx = %{models: models, org: org}
    rows = build_rows(ctx)

    insert_logs(rows)
    calibrate_topups(credits)
    rebuild_rollup()
    invalidate_caches()

    print_report(ctx)
  end

  # ---------------------------------------------------------------------------
  # Wipe — borra la corrida anterior (y sólo esa)
  # ---------------------------------------------------------------------------

  # El orden importa: las FK sin ON DELETE CASCADE (join tables, model_providers)
  # se limpian antes de borrar sus padres, y los logs antes que sus sujetos.
  defp wipe! do
    demo_user_ids =
      Repo.all(from u in User, where: like(u.email, ^"%#{@email_domain}"), select: u.id)

    demo_group_ids = Repo.all(from g in Group, where: g.name in ^@group_names, select: g.id)
    demo_service_ids = Repo.all(from s in Service, where: s.name in ^@service_names, select: s.id)

    demo_member_ids =
      Repo.all(
        from gm in GroupMember,
          where: gm.user_id in ^demo_user_ids or gm.group_id in ^demo_group_ids,
          select: gm.id
      )

    demo_model_ids = Repo.all(from m in Model, where: m.name in ^@demo_models, select: m.id)

    demo_provider_ids =
      Repo.all(from p in Provider, where: p.name in ^@custom_providers, select: p.id)

    demo_sub_ids = Repo.all(from s in Subscription, where: s.name in ^@sub_names, select: s.id)

    demo_credential_ids = demo_credential_ids()

    from = DateTime.new!(Date.add(Date.utc_today(), -@days), ~T[00:00:00], "Etc/UTC")

    {logs, _} =
      from(rl in RequestLog,
        where: rl.group_member_id in ^demo_member_ids or rl.service_id in ^demo_service_ids
      )
      |> Repo.delete_all()

    # El rollup del rango se reconstruye completo al final desde request_logs.
    {rollup, _} =
      from(m in RequestMetricsHourly, where: m.hour_utc >= ^from) |> Repo.delete_all()

    # La auditoría demo se marca en `changes` (`"demo" => true`): su `user_id`
    # es el admin real (la demo no crea admins), así que filtrar por usuario
    # dejaría las filas acumulándose en cada corrida.
    {audit, _} =
      from(a in AuditLog, where: fragment("? ->> 'demo' = 'true'", a.changes))
      |> Repo.delete_all()

    {exemptions, _} =
      from(e in Exemption,
        where:
          e.user_id in ^demo_user_ids or e.group_id in ^demo_group_ids or
            e.service_id in ^demo_service_ids
      )
      |> Repo.delete_all()

    # Los webhooks demo son globales: no cuelgan de ninguna sub, así que la
    # limpieza los borra por nombre y no por grupo.
    {destinations, _} =
      from(d in Destination,
        where: d.name in ["Datadog · producción", "Grafana Cloud · growth"]
      )
      |> Repo.delete_all()

    # Join tables sin cascade.
    {extras, _} =
      from(e in GroupMemberExtraModel, where: e.group_member_id in ^demo_member_ids)
      |> Repo.delete_all()

    {group_models, _} =
      from(gm in Providers.GroupModel, where: gm.group_id in ^demo_group_ids) |> Repo.delete_all()

    {service_models, _} =
      from(sm in ServiceModel, where: sm.service_id in ^demo_service_ids) |> Repo.delete_all()

    {model_providers, _} =
      from(mp in ModelProvider,
        where: mp.model_id in ^demo_model_ids or mp.credential_id in ^demo_credential_ids
      )
      |> Repo.delete_all()

    {subs, _} = from(s in Subscription, where: s.id in ^demo_sub_ids) |> Repo.delete_all()
    {models, _} = from(m in Model, where: m.id in ^demo_model_ids) |> Repo.delete_all()

    {credentials, _} =
      from(c in Credential, where: c.id in ^demo_credential_ids) |> Repo.delete_all()

    Enum.each(demo_provider_ids, fn id ->
      case Providers.get_provider(id) do
        nil -> :ok
        provider -> Providers.delete_provider(provider)
      end
    end)

    # Membresías demo (incluye la que la demo le crea al admin real).
    {memberships, _} =
      from(gm in GroupMember,
        where:
          gm.id in ^demo_member_ids or gm.user_id in ^demo_user_ids or
            gm.group_id in ^demo_group_ids
      )
      |> Repo.delete_all()

    {services, _} = from(s in Service, where: s.id in ^demo_service_ids) |> Repo.delete_all()
    {groups, _} = from(g in Group, where: g.id in ^demo_group_ids) |> Repo.delete_all()
    {users, _} = from(u in User, where: u.id in ^demo_user_ids) |> Repo.delete_all()

    from(l in Providers.Lab, where: l.key == ^@custom_lab_key) |> Repo.delete_all()

    IO.puts(
      "· wipe: #{logs} logs · #{rollup} buckets · #{audit} audit · #{exemptions} exenciones · " <>
        "#{destinations} webhooks · #{users} usuarios · #{groups} grupos · #{services} servicios · " <>
        "#{memberships} membresías · #{subs} subs · #{models} modelos · #{credentials} credenciales · " <>
        "#{model_providers + extras + group_models + service_models} enlaces"
    )
  end

  defp demo_credential_ids do
    # Marcador `sk-demo-` en `api_key_encrypted`: es el único filtro que
    # distingue lo que creó la demo de una credencial del operador con el
    # mismo nombre.
    Repo.all(from(c in Credential, where: like(c.api_key_encrypted, "sk-demo-%"), select: c.id))
  end

  # ---------------------------------------------------------------------------
  # Particiones
  # ---------------------------------------------------------------------------

  # El rango arranca 31 días atrás: esos días deben vivir en particiones reales
  # (no en el default) para que el pruning sirva y el rollup sea barato.
  defp ensure_partitions do
    statuses =
      for offset <- -@days..0 do
        Date.utc_today() |> Date.add(offset) |> PartitionWorker.ensure_partition()
      end
      |> Enum.frequencies()

    IO.puts("· particiones: #{inspect(statuses)}")
  end

  # ---------------------------------------------------------------------------
  # Proveedores y credenciales
  # ---------------------------------------------------------------------------

  defp seed_providers do
    custom_specs = [
      %{
        name: "Internal LiteLLM",
        base_url: "http://litellm.internal:4000/v1",
        dialect: "openai",
        capabilities: ~w(llm embedding),
        source: "custom",
        billing_type: "pay_per_token",
        doc_url: "https://docs.litellm.internal",
        max_rpm: 300,
        max_concurrent: 32,
        max_concurrent_per_user: 8,
        receive_timeout_ms: 90_000,
        # El reranker vive en otro host: path absoluto (tier 1 del modal
        # Capacidades) para ejercitar los overrides del operador.
        path_overrides: %{"rerank" => "http://reranker.internal:8080/v1/rerank"}
      },
      %{
        name: "VLLM Cluster",
        base_url: "http://vllm.internal:8000/v1",
        dialect: "openai",
        capabilities: ~w(llm),
        source: "custom",
        billing_type: "subscription",
        max_rpm: 120,
        max_concurrent: 16,
        receive_timeout_ms: 60_000
      }
    ]

    clients =
      for spec <- custom_specs do
        specs = Map.to_list(spec)

        case Repo.get_by(Provider, name: spec.name) do
          nil ->
            {:ok, provider} = Providers.create_provider(Map.new(specs))
            provider

          provider ->
            provider
        end
      end

    builtins =
      Repo.all(from p in Provider, where: p.key in ^@builtin_providers, order_by: [asc: p.key])

    with_credentials =
      Enum.map(builtins ++ clients, fn provider ->
        Map.put(provider, :demo_credential, ensure_credential(provider))
      end)

    # Credencial en estado `error` (401 del upstream): para probar la
    # reactivación desde /catalog/providers.
    openrouter = Enum.find(with_credentials, &(&1.key == "openrouter"))

    if openrouter do
      ensure_extra_credential(openrouter, "legacy-2024", %{
        status: "error",
        error_reason: "auth_error",
        error_message: "401 invalid api key (rotada el 2025-11-02)",
        error_at:
          DateTime.add(DateTime.utc_now(), -3 * 86_400, :second) |> DateTime.truncate(:second)
      })
    end

    # Credencial deshabilitada a mano: excluida del routing, reactivable.
    zai = Enum.find(with_credentials, &(&1.key == "zai"))

    if zai do
      ensure_extra_credential(zai, "overflow", %{status: "disabled"})
    end

    IO.puts("· proveedores: #{length(with_credentials)} superficies (#{length(clients)} custom)")

    with_credentials
  end

  defp ensure_credential(%Provider{key: nil} = provider) do
    ensure_extra_credential(provider, "on-prem", %{})
  end

  defp ensure_credential(%Provider{key: key} = provider) do
    name = Map.fetch!(@credential_by_key, key)
    ensure_extra_credential(provider, name, %{})
  end

  defp ensure_extra_credential(%Provider{} = provider, name, extra) do
    marker = "sk-demo-#{provider.key || "custom"}-#{name}"

    case Repo.one(
           from c in Credential,
             where:
               c.provider_id == ^provider.id and like(c.api_key_encrypted, ^"sk-demo-%") and
                 c.name == ^name
         ) do
      nil ->
        attrs =
          %{
            provider_id: provider.id,
            name: name,
            api_key_encrypted: marker,
            status: "active"
          }
          |> Map.merge(extra)

        {:ok, credential} = Providers.create_credential(attrs)
        credential

      credential ->
        credential
    end
  end

  defp provider_by(providers, key), do: Enum.find(providers, &(&1.key == key))
  defp custom_provider(providers, name), do: Enum.find(providers, &(&1.name == name))

  # ---------------------------------------------------------------------------
  # Modelos y rutas
  # ---------------------------------------------------------------------------

  defp seed_models(providers) do
    openrouter = provider_by(providers, "openrouter")
    zai = provider_by(providers, "zai")
    zai_plan = provider_by(providers, "zai-coding-plan")
    moonshot = provider_by(providers, "moonshotai")
    opencode = provider_by(providers, "opencode")
    lite_llm = custom_provider(providers, "Internal LiteLLM")
    vllm = custom_provider(providers, "VLLM Cluster")

    specs = [
      %{
        name: "claude-opus-4.7",
        context_window: 200_000,
        market: {15.0, 75.0, 1.50},
        prompt_cache_enabled: true,
        pinned: true,
        routes: [
          {openrouter, "anthropic/claude-opus-4.7", 0, {15.0, 75.0, 1.50}, []},
          {lite_llm, "anthropic/claude-opus-4.7", 1, nil, []}
        ]
      },
      %{
        name: "claude-sonnet-4.7",
        context_window: 200_000,
        market: {3.0, 15.0, 0.30},
        prompt_cache_enabled: true,
        routes: [
          {openrouter, "anthropic/claude-sonnet-4.7", 0, {3.0, 15.0, 0.30}, []},
          {lite_llm, "anthropic/claude-sonnet-4.7", 1, nil, []}
        ]
      },
      %{
        name: "gpt-5",
        context_window: 400_000,
        market: {1.25, 10.0, 0.125},
        prompt_cache_enabled: true,
        pinned: true,
        routes: [
          {openrouter, "openai/gpt-5", 0, {1.25, 10.0, 0.125}, []},
          {opencode, "gpt-5", 1, nil, []}
        ]
      },
      %{
        name: "gpt-5-mini",
        context_window: 400_000,
        market: {0.25, 2.0, 0.025},
        prompt_cache_enabled: true,
        routes: [
          {openrouter, "openai/gpt-5-mini", 0, {0.25, 2.0, 0.025}, []},
          {opencode, "gpt-5-mini", 1, nil, []}
        ]
      },
      %{
        name: "gemini-3-pro",
        context_window: 1_000_000,
        market: {1.25, 10.0, 0.31},
        prompt_cache_enabled: true,
        routes: [
          {openrouter, "google/gemini-3-pro", 0, {1.25, 10.0, 0.31}, []}
        ]
      },
      %{
        name: "grok-4",
        context_window: 256_000,
        market: {3.0, 15.0, 0.75},
        prompt_cache_enabled: true,
        routes: [
          {openrouter, "x-ai/grok-4", 0, {3.0, 15.0, 0.75}, []}
        ]
      },
      %{
        name: "kimi-k2",
        context_window: 256_000,
        market: {0.60, 2.50, 0.12},
        routes: [
          {moonshot, "moonshotai/kimi-k2-0905", 0, {0.60, 2.50, 0.12}, []},
          {openrouter, "moonshotai/kimi-k2-0905", 1, nil, []}
        ]
      },
      %{
        name: "glm-5.2",
        context_window: 200_000,
        market: {0.60, 2.20, 0.11},
        prompt_cache_enabled: true,
        routes: [
          {zai, "glm-5.2", 0, {0.60, 2.20, 0.11}, []},
          {zai_plan, "glm-5.2", 1, nil, sticky_ttl_ms: 1_800_000},
          {openrouter, "z-ai/glm-5.2", 2, nil, []}
        ]
      },
      %{
        name: "qwen3-coder",
        context_window: 256_000,
        market: {0.30, 1.20, 0.06},
        lazy_cleanup_enabled: true,
        routes: [
          {opencode, "qwen3-coder", 0, {0.30, 1.20, 0.06}, []},
          {vllm, "Qwen3-Coder-480B", 1, nil, []}
        ]
      },
      %{
        name: "bge-m3",
        context_window: 8_192,
        model_type: "embedding",
        market: {0.01, 0.0, 0.0},
        routes: [
          {lite_llm, "/models/bge-m3", 0, {0.01, 0.0, 0.0}, []}
        ]
      },
      %{
        name: "text-embedding-3-large",
        context_window: 8_191,
        model_type: "embedding",
        market: {0.13, 0.0, 0.0},
        routes: [
          {openrouter, "openai/text-embedding-3-large", 0, {0.13, 0.0, 0.0}, []}
        ]
      }
    ]

    models =
      Enum.map(specs, fn spec ->
        model = upsert_model(spec)

        routes =
          Enum.map(spec.routes, fn {provider, provider_model, priority, pricing, extra} ->
            {inp, out, cache} = pricing || {nil, nil, nil}

            attrs =
              %{
                model_id: model.id,
                credential_id: provider.demo_credential.id,
                provider_model: provider_model,
                priority: priority,
                enabled: true,
                input_cost_per_million: price(inp),
                output_cost_per_million: price(out),
                cache_cost_per_million: price(cache)
              }
              |> Map.merge(Map.new(extra))

            {:ok, mp} = Providers.create_model_provider(attrs)
            %{name: model.name, model: model, mp: mp}
          end)

        {model, routes}
      end)

    # Rutas ya existentes del operador que la demo reutiliza.
    reused =
      Repo.all(from m in Model, where: m.name in ["deepseek-4-flash", "fw-gpt-oss-120b"])

    reused_routes =
      for model <- reused,
          mp <-
            Repo.all(
              from r in ModelProvider, where: r.model_id == ^model.id and r.enabled == true
            ) do
        %{name: model.name, model: model, mp: mp}
      end

    all_routes = Enum.flat_map(models, fn {_model, routes} -> routes end) ++ reused_routes

    IO.puts(
      "· modelos: #{length(models)} nuevos + #{length(reused)} reutilizados · #{length(all_routes)} rutas de proveedor"
    )

    %{models: models, routes: all_routes, reused: reused}
  end

  defp upsert_model(spec) do
    case Repo.get_by(Model, name: spec.name) do
      nil ->
        {:ok, model} =
          Providers.create_model(%{
            name: spec.name,
            context_window: spec.context_window,
            model_type: Map.get(spec, :model_type, "llm"),
            prompt_cache_enabled: Map.get(spec, :prompt_cache_enabled, false),
            lazy_cleanup_enabled: Map.get(spec, :lazy_cleanup_enabled, false),
            pinned: Map.get(spec, :pinned, false),
            market_input_price_per_1m: price(elem(spec.market, 0)),
            market_output_price_per_1m: price(elem(spec.market, 1)),
            market_cache_price_per_1m: price(elem(spec.market, 2))
          })

        model

      model ->
        model
    end
  end

  defp price(nil), do: nil
  defp price(float) when is_float(float), do: Decimal.from_float(float) |> Decimal.round(6)
  defp price(int) when is_integer(int), do: Decimal.new(int)

  defp model_by_name(name), do: Repo.get_by(Model, name: name)

  # ---------------------------------------------------------------------------
  # Organización: grupos, usuarios, membresías, servicios
  # ---------------------------------------------------------------------------

  defp seed_org do
    groups = %{
      platform: create_group("Platform Crew", 10, 180),
      growth: create_group("Growth Squad", 6, 90),
      data_lab: create_group("Data Lab", 5, 60),
      contractors: create_group("Contractors", 3, 30)
    }

    people = [
      {"Marta Ríos", "marta", "America/Mexico_City", :heavy},
      {"Diego Salinas", "diego", "America/Merida", :heavy},
      {"Ana Beltrán", "ana", "Europe/Madrid", :regular},
      {"Luis Cárdenas", "luis", "America/Merida", :regular},
      {"Sofía Peralta", "sofia", "America/Bogota", :regular},
      {"Iván Ortega", "ivan", "America/Mexico_City", :light},
      {"Paulina Vega", "paulina", "Etc/UTC", :light},
      {"Tomás Ibarra", "tomas", "America/Argentina/Buenos_Aires", :light},
      {"Renata Cruz", "renata", "America/Merida", :regular},
      {"Bruno Kessler", "bruno", "Europe/Berlin", :regular},
      {"Camila Duarte", "camila", "America/Mexico_City", :heavy},
      {"Hugo Méndez", "hugo", "Etc/UTC", :light}
    ]

    users =
      Map.new(people, fn {name, slug, tz, profile} ->
        {:ok, user} =
          Accounts.register_user(%{
            email: "#{slug}@#{@email_domain}",
            name: name,
            password: @password,
            global_role: "user",
            timezone: tz
          })

        {slug, {user, profile}}
      end)

    placements = [
      {"marta", :platform, []},
      {"diego", :platform, []},
      {"ana", :growth, []},
      {"luis", :growth, []},
      {"sofia", :growth, [extra_rpm: 60, extra_concurrency: 4]},
      {"ivan", :platform, []},
      {"paulina", :data_lab, []},
      {"tomas", :data_lab, []},
      {"renata", :contractors, []},
      {"bruno", :contractors, [status: "suspended"]},
      {"camila", :data_lab, [extra_rpm: 120, extra_concurrency: 6]},
      {"hugo", :contractors, []}
    ]

    members =
      Enum.map(placements, fn {slug, group_key, extra} ->
        {user, profile} = Map.fetch!(users, slug)
        group = Map.fetch!(groups, group_key)

        {:ok, member} =
          Accounts.create_group_member(
            Map.merge(%{user_id: user.id, group_id: group.id}, Map.new(extra))
          )

        {:ok, _key, token} = Accounts.replace_api_key(member)

        %{
          member: member,
          user: user,
          group: group,
          profile: profile,
          token: token,
          key_prefix: String.slice(token, 0, 8)
        }
      end)

    # Membresía demo del admin real: su dashboard es siempre personal, así que
    # también necesita un mes de datos.
    admin_entry = demo_admin_membership(groups.platform)
    members = if admin_entry, do: members ++ [admin_entry], else: members

    services = seed_services()

    IO.puts(
      "· org: #{map_size(users)} usuarios · #{length(members)} membresías · #{map_size(groups)} grupos · #{length(services)} servicios"
    )

    %{groups: groups, members: members, services: services, admin: admin_entry}
  end

  defp demo_admin_membership(platform_group) do
    admin =
      Repo.one(
        from u in User,
          where: u.global_role == "admin",
          order_by: [asc: u.inserted_at],
          limit: 1
      )

    if admin do
      case Repo.one(
             from gm in GroupMember,
               where: gm.user_id == ^admin.id and gm.group_id == ^platform_group.id
           ) do
        nil ->
          {:ok, member} =
            Accounts.create_group_member(%{user_id: admin.id, group_id: platform_group.id})

          {:ok, _key, token} = Accounts.replace_api_key(member)

          %{
            member: member,
            user: admin,
            group: platform_group,
            profile: :regular,
            token: token,
            key_prefix: String.slice(token, 0, 8)
          }

        member ->
          prefix =
            Repo.one(
              from ak in ApiKey,
                where: ak.group_member_id == ^member.id and ak.status == "active",
                select: ak.key_prefix
            )

          %{
            member: member,
            user: admin,
            group: platform_group,
            profile: :regular,
            token: nil,
            key_prefix: prefix || "tg-demo"
          }
      end
    end
  end

  defp create_group(name, concurrency, rpm) do
    {:ok, group} =
      Accounts.create_group(%{
        name: name,
        default_concurrency_limit: concurrency,
        default_rpm_limit: rpm
      })

    group
  end

  defp seed_services do
    specs = [
      %{name: "ci-eval-bot", concurrency_limit: 8, rpm_limit: 240},
      %{name: "docs-rag", concurrency_limit: 12, rpm_limit: 300},
      %{name: "batch-reports", concurrency_limit: 2, rpm_limit: 20}
    ]

    Enum.map(specs, fn spec ->
      {:ok, service} =
        Accounts.create_service(%{
          name: spec.name,
          concurrency_limit: spec.concurrency_limit,
          rpm_limit: spec.rpm_limit
        })

      {:ok, _key, token} = Accounts.generate_service_api_key(service)
      %{service: service, token: token, key_prefix: String.slice(token, 0, 8)}
    end)
  end

  # ---------------------------------------------------------------------------
  # Crédito
  # ---------------------------------------------------------------------------

  defp seed_credits(org) do
    groups = org.groups

    platform_sub =
      create_subscription(%{
        name: "Platform Crew · mensual",
        units: 500,
        recurrence: "monthly",
        reset_day: 1,
        rollover_mode: "reset",
        status: "active"
      })

    {:ok, _} = Credits.set_group_default(groups.platform, platform_sub)

    growth_sub =
      create_subscription(%{
        name: "Growth Squad · mensual (rollover)",
        units: 200,
        recurrence: "monthly",
        reset_day: 1,
        rollover_mode: "rollover",
        rollover_pct: 25,
        rollover_cap_units: 40,
        status: "active"
      })

    {:ok, _} = Credits.set_group_default(groups.growth, growth_sub)

    data_lab_sub =
      create_subscription(%{
        name: "Data Lab · mensual (pausada)",
        units: 120,
        recurrence: "monthly",
        reset_day: 1,
        rollover_mode: "reset",
        status: "paused"
      })

    {:ok, _} = Credits.set_group_default(groups.data_lab, data_lab_sub)

    # Contractors queda por debajo del consumo real a propósito: así la UI de
    # presupuestos muestra el estado agotado / 402.
    contractors_sub =
      create_subscription(%{
        name: "Contractors · mensual",
        units: 10,
        recurrence: "monthly",
        reset_day: 1,
        rollover_mode: "reset",
        status: "active"
      })

    {:ok, _} = Credits.set_group_default(groups.contractors, contractors_sub)

    docs_sub =
      create_subscription(%{
        name: "docs-rag · mensual",
        units: 80,
        recurrence: "monthly",
        reset_day: 1,
        rollover_mode: "reset",
        status: "active"
      })

    ci_sub =
      create_subscription(%{
        name: "ci-eval-bot · one-shot",
        units: 40,
        recurrence: "none",
        starts_at: DateTime.new!(Date.add(Date.utc_today(), -20), ~T[00:00:00], "Etc/UTC"),
        expires_at: DateTime.new!(Date.add(Date.utc_today(), 45), ~T[00:00:00], "Etc/UTC"),
        status: "active"
      })

    services =
      Enum.map(org.services, fn entry ->
        case entry.service.name do
          "docs-rag" ->
            {:ok, service} =
              Accounts.update_service(entry.service, %{subscription_id: docs_sub.id})

            entry |> Map.put(:service, service) |> Map.put(:subscription, docs_sub)

          "ci-eval-bot" ->
            {:ok, service} = Accounts.update_service(entry.service, %{subscription_id: ci_sub.id})
            entry |> Map.put(:service, service) |> Map.put(:subscription, ci_sub)

          _ ->
            entry
        end
      end)

    ana = find_member(org, "ana")
    luis = find_member(org, "luis")
    ivan = find_member(org, "ivan")
    sofia = find_member(org, "sofia")

    ana_topup =
      create_subscription(%{
        user_id: ana.user.id,
        name: "Top-up · Ana",
        units: 25,
        recurrence: "none",
        starts_at: DateTime.new!(Date.add(Date.utc_today(), -12), ~T[00:00:00], "Etc/UTC"),
        expires_at: DateTime.new!(Date.add(Date.utc_today(), 20), ~T[00:00:00], "Etc/UTC"),
        status: "active"
      })

    luis_topup =
      create_subscription(%{
        user_id: luis.user.id,
        name: "Top-up · Luis (agotado)",
        units: 20,
        recurrence: "none",
        starts_at: DateTime.new!(Date.add(Date.utc_today(), -9), ~T[00:00:00], "Etc/UTC"),
        expires_at: DateTime.new!(Date.add(Date.utc_today(), 30), ~T[00:00:00], "Etc/UTC"),
        status: "active"
      })

    ivan_topup =
      create_subscription(%{
        user_id: ivan.user.id,
        name: "Top-up · Iván (vencido)",
        units: 15,
        recurrence: "none",
        starts_at: DateTime.new!(Date.add(Date.utc_today(), -25), ~T[00:00:00], "Etc/UTC"),
        expires_at: DateTime.new!(Date.add(Date.utc_today(), -4), ~T[00:00:00], "Etc/UTC"),
        status: "active"
      })

    sofia_direct =
      create_subscription(%{
        user_id: sofia.user.id,
        name: "Sub directa · Sofía",
        units: 30,
        recurrence: "monthly",
        reset_day: 15,
        rollover_mode: "reset",
        status: "active"
      })

    IO.puts(
      "· crédito: 6 subs de grupo/servicio + 4 directas (2 top-ups activos, 1 agotado, 1 vencido)"
    )

    %{
      group_subs: %{
        groups.platform.id => platform_sub.id,
        groups.growth.id => growth_sub.id,
        groups.data_lab.id => data_lab_sub.id,
        groups.contractors.id => contractors_sub.id
      },
      service_subs: %{"docs-rag" => docs_sub.id, "ci-eval-bot" => ci_sub.id},
      direct_subs: %{
        ana.user.id => ana_topup.id,
        luis.user.id => luis_topup.id,
        ivan.user.id => ivan_topup.id,
        sofia.user.id => sofia_direct.id
      },
      topups: %{ana: ana_topup, luis: luis_topup, ivan: ivan_topup, sofia_direct: sofia_direct},
      services: services
    }
  end

  defp create_subscription(attrs) do
    {:ok, subscription} = Credits.create_subscription(attrs)
    subscription
  end

  # Los `units` de los top-ups se fijan **después** de generar los logs, con el
  # consumo real ya en la tabla: así el top-up de Luis queda agotado (consumido
  # ≥ otorgado ⇒ se auto-archiva) y el de Ana parcialmente consumido, sin
  # depender de que el costo por request coincida con una cifra inventada.
  defp calibrate_topups(credits) do
    ana = credits.topups.ana
    luis = credits.topups.luis

    ana_consumed = Credits.subscription_usage(ana).consumed_micro
    luis_consumed = Credits.subscription_usage(luis).consumed_micro

    # Ana: ~1/3 consumido del ciclo (unidades = 3× lo gastado, mínimo 1).
    ana_units = max(1, round(ana_consumed / 1_000_000 * 3))

    # Luis: agotado — el otorgado es exactamente lo gastado (remanente 0).
    luis_units = max(1, div(luis_consumed, 1_000_000))

    {:ok, _} = Credits.update_subscription(ana, %{units: ana_units})
    {:ok, _} = Credits.update_subscription(luis, %{units: luis_units})

    IO.puts(
      "· top-ups calibrados: Ana #{ana_units} u " <>
        "(#{Decimal.round(Decimal.div(Decimal.new(ana_consumed), Decimal.new(1_000_000)), 2)} gastadas) · " <>
        "Luis #{luis_units} u (agotado)"
    )
  end

  defp find_member(org, slug) do
    Enum.find(org.members, &(&1.user.email == "#{slug}@#{@email_domain}"))
  end

  # ---------------------------------------------------------------------------
  # Rutas exclusivas, observabilidad, extras
  # ---------------------------------------------------------------------------

  defp seed_exclusives(models, org) do
    create_exclusive(models, "gemini-3-pro", "google/gemini-3-pro", "openrouter", "overflow",
      exclusive_to_group_member_id: find_member(org, "marta").member.id
    )

    create_exclusive(models, "kimi-k2", "moonshotai/kimi-k2-0905", "moonshotai", "prod",
      exclusive_to_group_id: org.groups.contractors.id
    )

    batch = Enum.find(org.services, &(&1.service.name == "batch-reports"))

    create_exclusive(models, "glm-5.2", "GLM-5.2-AWQ", "VLLM Cluster", "on-prem",
      exclusive_to_service_id: batch.service.id
    )

    IO.puts("· rutas exclusivas: 1 de usuario, 1 de grupo, 1 de servicio")
  end

  defp create_exclusive(models, model_name, provider_model, provider_ref, credential_name, scope) do
    model = find_model(models, model_name)
    credential = credential_for(provider_ref, credential_name)

    if model && credential do
      {:ok, _} =
        Providers.create_model_provider(
          Map.merge(
            %{
              model_id: model.id,
              credential_id: credential.id,
              provider_model: provider_model,
              priority: 0,
              enabled: true
            },
            Map.new(scope)
          )
        )
    end
  end

  defp find_model(models, name) do
    Enum.find_value(models.models, fn {model, _routes} ->
      if model.name == name, do: model
    end)
  end

  defp credential_for(provider_ref, name) do
    provider =
      case provider_ref do
        key when key in @builtin_providers -> Repo.get_by(Provider, key: key)
        name -> Repo.get_by(Provider, name: name)
      end

    if provider do
      Repo.one(from c in Credential, where: c.provider_id == ^provider.id and c.name == ^name)
    end
  end

  defp seed_observability(org) do
    {:ok, _} =
      Observability.create_destination(%{
        name: "Datadog · producción",
        type: "otlp_webhook",
        url: "https://hooks.internal.example.com/otlp/tokengate",
        headers: %{"x-api-key" => "demo-datadog-key", "x-tenant" => "acme"}
      })

    {:ok, _} =
      Observability.create_destination(%{
        name: "Grafana Cloud · growth",
        type: "otlp_webhook",
        url: "https://otlp-gateway-prod.grafana.net/otlp/v1/logs",
        headers: %{"authorization" => "Bearer demo-grafana-token"}
      })

    IO.puts("· observabilidad: 2 webhooks OTLP (globales)")
  end

  defp seed_misc(org) do
    # Tope global diario (kill-switch): con margen para que el tráfico de hoy
    # no bloquee requests reales durante las pruebas.
    {:ok, _} = GlobalSettings.update(%{daily_max_spend_usd: price(50)})

    marta = find_member(org, "marta")
    batch = Enum.find(org.services, &(&1.service.name == "batch-reports"))

    {:ok, _} =
      Exemptions.add(%{
        scope: "global_daily",
        subject_type: "user",
        user_id: marta.user.id,
        note: "On-call de plataforma: su tráfico no debe tocar el kill-switch"
      })

    {:ok, _} =
      Exemptions.add(%{
        scope: "global_daily",
        subject_type: "group",
        group_id: org.groups.data_lab.id,
        note: "Grupo de investigación: exento durante el trimestre"
      })

    {:ok, _} =
      Exemptions.add(%{
        scope: "global_daily",
        subject_type: "service",
        service_id: batch.service.id,
        note: "Reportes nocturnos de dirección"
      })

    # Supervisores de servicios (vista read-only /services/supervised).
    docs_rag = Enum.find(org.services, &(&1.service.name == "docs-rag"))
    Accounts.add_service_supervisor(docs_rag.service.id, find_member(org, "diego").user.id)
    Accounts.add_service_supervisor(docs_rag.service.id, find_member(org, "paulina").user.id)

    # Lab custom (el resto del catálogo de labs es builtin, viene de models.dev).
    {:ok, _} =
      Providers.create_custom_lab(%{
        "key" => @custom_lab_key,
        "name" => @custom_lab_name,
        "icon" => "hero-beaker",
        "logo_url" => "https://cdn.internal.example.com/logos/acme.svg"
      })

    # Grants de modelos por grupo y por servicio.
    grant_models(org.groups.platform, [
      "claude-opus-4.7",
      "claude-sonnet-4.7",
      "gpt-5",
      "gpt-5-mini",
      "gemini-3-pro",
      "grok-4",
      "kimi-k2",
      "glm-5.2",
      "deepseek-4-flash",
      "bge-m3",
      "text-embedding-3-large"
    ])

    grant_models(org.groups.growth, [
      "gpt-5",
      "gpt-5-mini",
      "gemini-3-pro",
      "grok-4",
      "deepseek-4-flash",
      "text-embedding-3-large"
    ])

    grant_models(org.groups.data_lab, ["glm-5.2", "kimi-k2", "deepseek-4-flash", "bge-m3"])

    grant_models(org.groups.contractors, ["gpt-5-mini", "deepseek-4-flash", "fw-gpt-oss-120b"])

    # Modelo extra individual (grant puntual fuera del grupo).
    sofia = find_member(org, "sofia")
    opus = model_by_name("claude-opus-4.7")
    if opus, do: {:ok, _} = Providers.grant_extra_model(sofia.member.id, opus.id)

    ci_bot = Enum.find(org.services, &(&1.service.name == "ci-eval-bot"))

    grant_service_models(docs_rag, ["bge-m3", "text-embedding-3-large"])
    grant_service_models(ci_bot, ["gpt-5-mini", "deepseek-4-flash"])
    grant_service_models(batch, ["glm-5.2", "qwen3-coder"])

    seed_audit(org)
  end

  defp grant_models(group, names) do
    ids = Repo.all(from m in Model, where: m.name in ^names, select: m.id)
    Enum.each(ids, fn id -> {:ok, _} = Providers.grant_model_to_group(group.id, id) end)
    :ok
  end

  defp grant_service_models(%{service: service}, names) do
    ids = Repo.all(from m in Model, where: m.name in ^names, select: m.id)
    Enum.each(ids, fn id -> {:ok, _} = Providers.grant_model_to_service(service.id, id) end)
    :ok
  end

  # Acciones de administración repartidas por el mes (la lista de usuarios y
  # las tarjetas de mantenimiento leen esta tabla).
  defp seed_audit(org) do
    admin_id = org.admin && org.admin.user.id

    actions = [
      {"user.create", "user", "Alta de miembro", 29},
      {"credential.create", "credential", "Credencial de Z.AI (prod)", 28},
      {"budget.update_global_daily_cap", "global_settings", "Tope diario 40 → 50 USD", 26},
      {"credential.update", "credential", "Rotación de la credencial de OpenRouter", 24},
      {"user.update", "user", "Cambio de zona horaria de Ana", 22},
      {"provider.update", "provider", "Límites RPM del proveedor interno", 21},
      {"settings.catalog_refresh", "catalog_providers", "Refresco manual del catálogo models.dev",
       20},
      {"user.create", "user", "Alta de miembro (Contractors)", 18},
      {"user.toggle_status", "user", "Suspensión de Bruno Kessler", 17},
      {"credential.create", "credential", "Credencial de VLLM Cluster (on-prem)", 16},
      {"settings.reset_sticky_sessions", "sticky_sessions", "Reset de sesiones sticky", 15},
      {"model.update", "model", "Precios de mercado de gemini-3-pro", 14},
      {"user.reset_password", "user", "Reset de contraseña de Hugo", 12},
      {"budget.update_global_daily_cap", "global_settings", "Tope diario 30 → 40 USD", 11},
      {"impersonate.start", "user", "Impersonación para soporte", 10},
      {"impersonate.stop", "user", "Fin de impersonación", 10},
      {"credential.toggle_status", "credential", "Credencial de Z.AI overflow deshabilitada", 9},
      {"settings.reset_member_extra", "group_member", "Reset de extras de membresía", 8},
      {"model_provider.create", "model_provider", "Ruta exclusiva para batch-reports", 7},
      {"user.create", "user", "Alta de miembro (Data Lab)", 6},
      {"credential.create", "credential", "Credencial de Moonshot AI (prod)", 5},
      {"settings.reset_logs", "request_logs", "Purga de logs de prueba", 4},
      {"user.delete", "user", "Baja de cuenta temporal", 3},
      {"budget.update_global_daily_cap", "global_settings", "Tope diario de 50 USD confirmado",
       2},
      {"credential.update", "credential", "Rotación de la credencial de Fireworks", 1}
    ]

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    demo_member_ids = Enum.map(org.members, & &1.member.id)
    credential_refs = Enum.map(@extra_credentials, fn {key, name} -> "#{key}:#{name}" end)

    rows =
      actions
      |> Enum.with_index()
      |> Enum.map(fn {{action, entity_type, note, days_ago}, index} ->
        entity_id =
          case entity_type do
            "credential" -> Enum.random(credential_refs)
            "user" -> Enum.random(demo_member_ids)
            _ -> Ecto.UUID.generate()
          end

        %{
          id: Ecto.UUID.generate(),
          user_id: admin_id,
          action: action,
          entity_type: entity_type,
          entity_id: entity_id,
          changes: %{"note" => note, "demo" => true},
          inserted_at:
            DateTime.add(now, -(days_ago * 86_400 + index * 1_337), :second)
            |> DateTime.truncate(:second)
        }
      end)

    {count, _} = Repo.insert_all(AuditLog, rows)
    IO.puts("· auditoría: #{count} entradas repartidas en el mes")
  end

  # ---------------------------------------------------------------------------
  # Generación de logs
  # ---------------------------------------------------------------------------

  defp build_rows(ctx) do
    today = Date.utc_today()
    subjects = subjects(ctx)

    rows =
      for offset <- @days..0, reduce: [] do
        acc ->
          date = Date.add(today, -offset)
          acc ++ Enum.flat_map(subjects, &day_requests(&1, date, ctx))
      end

    # Tráfico de los últimos minutos: el panel "En vivo" (KPI de ventana
    # rodante, top modelos/usuarios del último minuto, in-flight) sólo tiene
    # datos si hay filas cerca de `now`. Se generan con timestamps hacia atrás
    # desde el instante actual, no desde la hora en punto.
    recent = recent_rows(subjects, ctx)
    rows = Enum.sort_by(rows ++ recent, & &1.inserted_at)

    IO.puts("· logs: #{length(rows)} filas generadas (31 días + últimos minutos)")
    rows
  end

  defp recent_rows(subjects, ctx) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    active = Enum.take_random(subjects, min(7, length(subjects)))

    Enum.flat_map(active, fn subject ->
      # Ventana corta (0–90 s) y varios requests por sujeto: la tira "En vivo"
      # muestra top modelos/usuarios del ÚLTIMO MINUTO, no de los últimos 5.
      count = 2 + :rand.uniform(4)

      for _ <- 1..count//1 do
        inserted_at = DateTime.add(now, -:rand.uniform(90), :second)
        request_row(subject, DateTime.to_date(inserted_at), ctx, inserted_at)
      end
    end)
  end

  defp subjects(ctx) do
    members =
      Enum.map(ctx.org.members, fn entry ->
        profile = profile_of(entry.profile)

        %{
          kind: :member,
          id: entry.member.id,
          prefix: entry.key_prefix,
          tz: entry.user.timezone,
          profile: entry.profile,
          daily: profile.daily,
          models: profile.models,
          streaming_ratio: profile.streaming,
          prompt: profile.prompt,
          completion: profile.completion,
          credit_sub_id: Map.get(ctx.org.credits.group_subs, entry.group.id),
          extra_sub_id: Map.get(ctx.org.credits.direct_subs, entry.user.id),
          slug: entry.user.email |> String.split("@") |> hd()
        }
      end)

    services =
      Enum.map(ctx.org.credits.services, fn entry ->
        {models, prompt, completion, daily, sub} =
          case entry.service.name do
            "docs-rag" ->
              {[{"bge-m3", 6}, {"text-embedding-3-large", 4}, {"gpt-5-mini", 1}], 2_600, 40, 34,
               Map.get(ctx.org.credits.service_subs, "docs-rag")}

            "ci-eval-bot" ->
              {[{"gpt-5-mini", 5}, {"deepseek-4-flash", 3}, {"gpt-5", 1}], 1_800, 400, 40,
               Map.get(ctx.org.credits.service_subs, "ci-eval-bot")}

            "batch-reports" ->
              {[{"glm-5.2", 4}, {"qwen3-coder", 3}, {"gpt-5-mini", 2}], 6_500, 1_400, 8, nil}
          end

        %{
          kind: :service,
          id: entry.service.id,
          prefix: entry.key_prefix,
          tz: "Etc/UTC",
          profile: :service,
          daily: daily,
          models: models,
          streaming_ratio: 0.2,
          prompt: prompt,
          completion: completion,
          credit_sub_id: sub,
          extra_sub_id: nil,
          slug: entry.service.name
        }
      end)

    members ++ services
  end

  defp profile_of(:heavy) do
    %{
      daily: 34,
      streaming: 0.76,
      prompt: 22_000,
      completion: 1_400,
      models: [
        {"claude-opus-4.7", 16},
        {"claude-sonnet-4.7", 20},
        {"gpt-5", 18},
        {"gemini-3-pro", 8},
        {"glm-5.2", 12},
        {"deepseek-4-flash", 10},
        {"kimi-k2", 6},
        {"grok-4", 4},
        {"text-embedding-3-large", 3},
        {"bge-m3", 3}
      ]
    }
  end

  defp profile_of(:regular) do
    %{
      daily: 16,
      streaming: 0.62,
      prompt: 11_000,
      completion: 900,
      models: [
        {"claude-sonnet-4.7", 14},
        {"gpt-5-mini", 18},
        {"gpt-5", 10},
        {"deepseek-4-flash", 14},
        {"glm-5.2", 10},
        {"qwen3-coder", 8},
        {"kimi-k2", 6},
        {"bge-m3", 8},
        {"text-embedding-3-large", 6},
        {"fw-gpt-oss-120b", 6}
      ]
    }
  end

  defp profile_of(_light) do
    %{
      daily: 6,
      streaming: 0.45,
      prompt: 5_500,
      completion: 600,
      models: [
        {"gpt-5-mini", 26},
        {"deepseek-4-flash", 20},
        {"glm-5.2", 14},
        {"qwen3-coder", 12},
        {"bge-m3", 12},
        {"fw-gpt-oss-120b", 8},
        {"claude-sonnet-4.7", 8}
      ]
    }
  end

  # Un día de tráfico de un sujeto: volumen → eventos.
  defp day_requests(subject, date, ctx) do
    weekday = Date.day_of_week(date)

    day_factor =
      cond do
        weekday in [6, 7] -> 0.32
        weekday == 1 -> 0.88
        true -> 1.0
      end

    # Hoy sólo transcurrió una fracción del día UTC.
    partial_factor =
      if date == Date.utc_today() do
        max(DateTime.utc_now().hour + 1, 3) / 24
      else
        1.0
      end

    count =
      subject.daily
      |> Kernel.*(day_factor * partial_factor * (0.75 + :rand.uniform() * 0.5))
      |> round()
      |> max(0)

    rows =
      for _ <- 1..count//1 do
        request_row(subject, date, ctx)
      end

    # Al convertir la hora local a UTC, un turno de las 22:00 en México cae en
    # el día siguiente: las horas ya pasadas del "hoy" local no deben producir
    # filas en el futuro (el dashboard y el kill-switch miden contra `now`).
    if date == Date.utc_today() do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      Enum.filter(rows, &(DateTime.compare(&1.inserted_at, now) != :gt))
    else
      rows
    end
  end

  defp request_row(subject, date, ctx) do
    hour = pick_hour(subject)
    {utc_date, utc_hour} = local_to_utc(date, hour, subject.tz)
    minute = :rand.uniform(60) - 1
    second = :rand.uniform(60) - 1

    inserted_at =
      DateTime.new!(utc_date, Time.new!(utc_hour, minute, second), "Etc/UTC")
      |> DateTime.truncate(:second)

    request_row(subject, date, ctx, inserted_at)
  end

  # Variante con timestamp explícito (tráfico reciente).
  defp request_row(subject, _date, ctx, inserted_at) do
    model_name = pick_weighted(subject.models)
    route = pick_route(model_name, ctx.models.routes)
    {agent_type, client_agent} = pick_agent(subject)
    outcome = pick_outcome(subject, DateTime.to_date(inserted_at))

    build_log(subject, model_name, route, agent_type, client_agent, inserted_at, outcome, ctx)
  end

  defp pick_hour(%{profile: :service}), do: pick_weighted(@night_hour_weights)

  defp pick_hour(%{profile: profile}) when profile in [:heavy, :regular, :light],
    do: pick_weighted(@hour_weights)

  # Hora local de `tz` → UTC. El offset se toma del propio día, así el cambio
  # de horario no descuadra los gráficos por hora.
  defp local_to_utc(date, hour, tz) do
    case DateTime.new(date, Time.new!(hour, 0, 0), tz) do
      {:ok, local} ->
        utc = DateTime.shift_zone!(local, "Etc/UTC")
        {DateTime.to_date(utc), utc.hour}

      {:error, _} ->
        {date, hour}
    end
  end

  defp pick_weighted(list) do
    total = Enum.reduce(list, 0, fn {_value, weight}, acc -> acc + weight end)
    do_pick(list, :rand.uniform(total))
  end

  defp do_pick([{value, weight} | rest], roll) do
    if roll <= weight, do: value, else: do_pick(rest, roll - weight)
  end

  defp do_pick([], _roll), do: nil

  # Ruta para un modelo: la de mayor prioridad (menor número) casi siempre,
  # con 22% de overflow a la siguiente para que el ranking de proveedores de
  # /stats no quede plano.
  defp pick_route(model_name, routes) do
    candidates =
      routes
      |> Enum.filter(&(&1.name == model_name))
      |> Enum.sort_by(& &1.mp.priority)

    case candidates do
      [] ->
        nil

      list ->
        index = if length(list) > 1 and :rand.uniform() < 0.22, do: 1, else: 0
        Enum.at(list, index)
    end
  end

  defp pick_agent(%{kind: :service, slug: "ci-eval-bot"}), do: {"codex-cli", "codex-cli/0.48.0"}
  defp pick_agent(%{kind: :service, slug: slug}), do: {"api", "#{slug}/1.0"}

  defp pick_agent(_subject) do
    {agent, client, _weight} = Enum.at(@agents, weighted_index(@agent_weights))
    {agent, client}
  end

  defp weighted_index(weights) do
    roll = :rand.uniform(Enum.sum(weights))
    do_weighted_index(weights, roll, 0)
  end

  defp do_weighted_index([weight | rest], roll, index) do
    if roll <= weight, do: index, else: do_weighted_index(rest, roll - weight, index + 1)
  end

  defp do_weighted_index([], _roll, index), do: index - 1

  # Resultado del request: ~92% éxito, resto errores repartidos entre gates,
  # cliente y proveedor. Dos días del mes tienen caída de proveedor (más 5xx)
  # para que los gráficos de errores tengan picos.
  defp pick_outcome(subject, date) do
    days_ago = Date.diff(Date.utc_today(), date)
    outage? = days_ago in [7, 18]
    error_rate = if outage?, do: 0.26, else: 0.08

    cond do
      :rand.uniform() < error_rate ->
        pick_weighted([
          {:gate_rate_limited, 16},
          {:gate_budget, 4},
          {:client_bad_request, 12},
          {:client_not_found, 4},
          {:provider_rate_limited, 22},
          {:provider_overloaded, 20},
          {:provider_timeout, 14},
          {:provider_auth, 6},
          {:no_available_provider, 8},
          {:all_providers_down, if(outage?, do: 14, else: 4)}
        ])

      subject.kind == :service and :rand.uniform() < 0.03 ->
        :fallback

      :rand.uniform() < 0.035 ->
        :fallback

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Construcción de la fila
  # ---------------------------------------------------------------------------

  defp build_log(subject, model_name, route, agent_type, client_agent, inserted_at, outcome, ctx) do
    model = route && route.model
    mp = route && route.mp
    credential = mp && Repo.preload(mp, :credential).credential
    is_embedding = model != nil and model.model_type == "embedding"

    {prompt, completion, cache_read, cache_creation} = tokens(subject, model, is_embedding)

    base = %{
      id: Ecto.UUID.generate(),
      inserted_at: inserted_at,
      group_member_id: if(subject.kind == :member, do: subject.id),
      service_id: if(subject.kind == :service, do: subject.id),
      subject_type: if(subject.kind == :member, do: "user", else: "service"),
      provider_id: credential && credential.provider_id,
      model_provider_id: mp && mp.id,
      credential_id: credential && credential.id,
      model_id: model && model.id,
      model_requested: model_name,
      model_responded: mp && mp.provider_model,
      agent_type: agent_type,
      client_agent: client_agent,
      status_code: 200,
      provider_status_code: nil,
      error_reason: nil,
      error_message: nil,
      prompt_tokens: prompt,
      completion_tokens: completion,
      cache_read_tokens: cache_read,
      cache_creation_tokens: cache_creation,
      provider_cost_usd: Decimal.new(0),
      latency_ms: nil,
      ttft_ms: nil,
      streaming: not is_embedding and :rand.uniform() < subject.streaming_ratio,
      request_type: if(is_embedding, do: "embedding", else: "chat"),
      think: false,
      effort: nil,
      api_key_prefix: subject.prefix,
      session_id: session_id(subject, inserted_at, is_embedding),
      credential_name: credential_name(credential),
      provider_key_prefix: provider_key_prefix(credential),
      credit_subscription_id: credit_sub_for(subject, inserted_at, ctx)
    }

    {think, effort} = think_flags(model_name, is_embedding)
    base = %{base | think: think, effort: effort}

    case outcome do
      :ok -> success_row(base, mp, is_embedding)
      :fallback -> fallback_row(base, is_embedding)
      :gate_rate_limited -> gate_error(base, 429, "rate_limited", nil)
      :gate_budget -> gate_error(base, 402, "budget_exceeded", nil)
      :client_bad_request -> gate_error(base, 400, "bad_request", nil)
      :client_not_found -> gate_error(base, 404, "model_not_found", nil)
      :no_available_provider -> gate_error(base, 503, "no_available_provider", nil)
      :provider_rate_limited -> provider_error(base, 429, "provider_rate_limited", 429)
      :provider_overloaded -> provider_error(base, 503, "provider_overloaded", 503)
      :provider_timeout -> provider_error(base, 504, "timeout", nil)
      :provider_auth -> provider_error(base, 401, "provider_auth_error", 401)
      :all_providers_down -> provider_error(base, 503, "all_providers_down", 503)
    end
  end

  defp success_row(base, mp, is_embedding) do
    {latency, ttft} = latency_for(base, is_embedding)

    %{
      base
      | provider_cost_usd: cost_for(base, mp),
        latency_ms: latency,
        ttft_ms: ttft
    }
  end

  # Fallback: el cliente vio 200, pero el proveedor de la primera ruta falló y
  # el gateway reintentó contra otra credencial (la UI lo marca con el badge
  # "fallback" y conserva el status del upstream).
  defp fallback_row(base, is_embedding) do
    {latency, ttft} = latency_for(base, is_embedding)

    upstream = pick_weighted([{"rate limit", 3}, {"service overloaded", 2}])

    %{
      base
      | provider_cost_usd: Decimal.new(0),
        latency_ms: latency + 900,
        ttft_ms: ttft,
        provider_status_code: pick_weighted([{429, 3}, {503, 3}, {500, 2}, {502, 2}]),
        error_reason:
          pick_weighted([
            {"provider_rate_limited", 2},
            {"provider_overloaded", 3},
            {"provider_gateway_error", 2}
          ]),
        error_message: "upstream #{upstream} — recuperado por fallback"
    }
  end

  # Error de gate: nunca se contactó a un proveedor.
  defp gate_error(base, status, reason, provider_status) do
    base
    |> reset_tokens()
    |> Map.merge(%{
      status_code: status,
      provider_status_code: provider_status,
      error_reason: reason,
      error_message: error_message(reason),
      latency_ms: :rand.uniform(90),
      ttft_ms: nil,
      provider_cost_usd: Decimal.new(0)
    })
    |> clear_route(reason)
  end

  defp provider_error(base, status, reason, provider_status) do
    base
    |> reset_tokens()
    |> Map.merge(%{
      status_code: status,
      provider_status_code: provider_status,
      error_reason: reason,
      error_message: error_message(reason),
      latency_ms: :rand.uniform(4_000) + 400,
      ttft_ms: nil,
      provider_cost_usd: Decimal.new(0)
    })
  end

  defp reset_tokens(base) do
    %{
      base
      | prompt_tokens: 0,
        completion_tokens: 0,
        cache_read_tokens: 0,
        cache_creation_tokens: 0
    }
  end

  # Un fallo que no llegó a tocar proveedor no deja rastro de routing.
  defp clear_route(base, reason)
       when reason in ["no_available_provider", "model_not_found", "bad_request"] do
    %{
      base
      | provider_id: nil,
        model_provider_id: nil,
        credential_id: nil,
        credential_name: nil,
        provider_key_prefix: nil,
        model_responded: nil
    }
  end

  defp clear_route(base, _reason), do: base

  defp error_message("rate_limited"), do: "Rate limit exceeded, retry in 12ms"
  defp error_message("budget_exceeded"), do: "Credit exhausted"
  defp error_message("bad_request"), do: "missing required field 'messages'"
  defp error_message("model_not_found"), do: "Model not found or not accessible"
  defp error_message("provider_rate_limited"), do: "429 upstream: rate limit reached"
  defp error_message("provider_overloaded"), do: "503 upstream: model overloaded, try again later"
  defp error_message("timeout"), do: "provider read timeout after 60000ms"
  defp error_message("provider_auth_error"), do: "401 upstream: invalid api key"
  defp error_message("no_available_provider"), do: "All providers are currently unavailable"
  defp error_message("all_providers_down"), do: "All providers failed"
  defp error_message(_), do: nil

  # ---------------------------------------------------------------------------
  # Tokens, costo y latencia
  # ---------------------------------------------------------------------------

  defp tokens(subject, _model, true) do
    # Embeddings: prompt-only.
    prompt = max(80, round(subject.prompt * 0.12 * (0.4 + :rand.uniform())))
    {prompt, 0, 0, 0}
  end

  defp tokens(subject, model, false) do
    cache_enabled? = model != nil and model.prompt_cache_enabled

    prompt =
      subject.prompt
      |> Kernel.*(0.35 + :rand.uniform() * 1.5)
      |> round()
      |> max(120)

    completion =
      subject.completion
      |> Kernel.*(0.3 + :rand.uniform() * 2.2)
      |> round()
      |> max(20)

    # Turnos de agente (claude-code/cursor/codex) reenvían la conversación:
    # la tasa de aciertos de caché es alta.
    cache_read =
      if cache_enabled? and :rand.uniform() < 0.62 do
        round(prompt * (0.35 + :rand.uniform() * 0.5))
      else
        0
      end

    cache_creation =
      if cache_enabled? and :rand.uniform() < 0.22 do
        round(prompt * (0.2 + :rand.uniform() * 0.4))
      else
        0
      end

    {prompt, completion, cache_read, cache_creation}
  end

  defp think_flags(_model_name, true), do: {false, nil}

  defp think_flags(model_name, false) do
    reasoning? =
      String.contains?(model_name, [
        "opus",
        "sonnet",
        "gpt-5",
        "gemini",
        "grok",
        "glm",
        "kimi",
        "qwen3"
      ])

    cond do
      not reasoning? -> {false, nil}
      :rand.uniform() < 0.42 -> {true, pick_weighted([{"low", 4}, {"medium", 5}, {"high", 3}])}
      :rand.uniform() < 0.3 -> {false, pick_weighted([{"none", 2}, {"minimal", 1}])}
      true -> {false, nil}
    end
  end

  defp latency_for(_base, true) do
    {:rand.uniform(700) + 120, nil}
  end

  defp latency_for(base, false) do
    completion = max(base.completion_tokens, 1)

    # 25–90 tokens/s: throughput realista de un modelo grande detrás de una
    # gateway con cola.
    tps = 25 + :rand.uniform() * 65
    generation = round(completion / tps * 1_000)
    ttft = round(280 + :rand.uniform() * 1_400 + if(base.think, do: 2_200, else: 0))

    {ttft + generation, ttft}
  end

  # Costo "reportado por el upstream": fórmula de 3 términos sobre la tabla de
  # precios con una varianza de ±12%. ~0.2% de las filas quedan en $0 a
  # propósito, para poder probar el backfill de precios manuales.
  defp cost_for(_base, nil), do: Decimal.new(0)

  defp cost_for(base, mp) do
    with {input, output, cache} when not is_nil(input) <- Map.get(@pricing, mp.provider_model),
         false <- :rand.uniform(1_000) <= 2 do
      non_cached = max(base.prompt_tokens - base.cache_read_tokens, 0)

      tokens_cost =
        non_cached * input + base.cache_read_tokens * cache + base.completion_tokens * output

      tokens_cost
      |> Kernel.*(0.88 + :rand.uniform() * 0.24)
      |> round()
      |> Decimal.new()
      |> Decimal.div(Decimal.new(1_000_000))
    else
      _ -> Decimal.new(0)
    end
  end

  # ---------------------------------------------------------------------------
  # Detalles
  # ---------------------------------------------------------------------------

  defp credential_name(nil), do: nil
  defp credential_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp credential_name(_credential), do: "default"

  defp provider_key_prefix(nil), do: nil

  defp provider_key_prefix(%{api_key_encrypted: key}) when is_binary(key) and byte_size(key) > 4,
    do: String.slice(key, -4, 4)

  defp provider_key_prefix(_credential), do: nil

  # Sesiones de conversación: pocas por sujeto y día (afinidad de caché), como
  # se ven en la vida real — una conversación larga son muchos turnos.
  defp session_id(_subject, _inserted_at, true), do: nil

  defp session_id(subject, inserted_at, false) do
    if :rand.uniform() < 0.78 do
      day = DateTime.to_date(inserted_at) |> Date.to_string()
      bucket = div(inserted_at.hour, 3)
      "conv-#{String.slice(to_string(subject.id), 0, 8)}-#{day}-#{bucket}"
    end
  end

  # Débito de crédito: primero el grant del ciclo vigente; el top-up directo
  # cubre el resto (así "Top-up · Luis" queda agotado y el de Ana parcialmente
  # consumido, que es lo que la página de top-ups pinta).
  defp credit_sub_for(subject, inserted_at, ctx) do
    today = Date.utc_today()
    in_current_month? = DateTime.compare(inserted_at, month_start()) != :lt

    cond do
      is_nil(subject.credit_sub_id) and is_nil(subject.extra_sub_id) ->
        nil

      subject.slug == "luis" ->
        if Date.diff(today, DateTime.to_date(inserted_at)) <= 9 do
          subject.extra_sub_id || subject.credit_sub_id
        else
          subject.credit_sub_id
        end

      subject.slug == "ana" and in_current_month? and :rand.uniform() < 0.35 ->
        subject.extra_sub_id

      in_current_month? ->
        subject.credit_sub_id || subject.extra_sub_id

      true ->
        subject.credit_sub_id
    end
  end

  defp month_start do
    today = Date.utc_today()
    DateTime.new!(Date.new!(today.year, today.month, 1), ~T[00:00:00], "Etc/UTC")
  end

  # ---------------------------------------------------------------------------
  # Inserción, rollup, cachés
  # ---------------------------------------------------------------------------

  defp insert_logs(rows) do
    count =
      rows
      |> Enum.chunk_every(@batch_size)
      |> Enum.reduce(0, fn chunk, acc ->
        {count, _} = Repo.insert_all(RequestLog, chunk)
        acc + count
      end)

    IO.puts("· insert: #{count} request_logs (lotes de #{@batch_size})")
  end

  defp rebuild_rollup do
    from = DateTime.new!(Date.add(Date.utc_today(), -@days), ~T[00:00:00], "Etc/UTC")
    to = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, %{days: days, rows: rows}} = HourlyAggregate.backfill(from, to)
    IO.puts("· rollup: #{rows} buckets en #{days} días (request_metrics_hourly)")
  end

  # Las cachés ETS guardan sujetos que el wipe acaba de borrar; sin esto las
  # primeras pantallas podrían resolver auth/límites contra datos viejos.
  defp invalidate_caches do
    Tokengate.Accounts.ApiKeyCache.invalidate_all()
    Tokengate.Routing.Cache.invalidate_all()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Reporte
  # ---------------------------------------------------------------------------

  defp print_report(ctx) do
    summary = Logs.cost_summary()
    today = Logs.today_summary("America/Merida")

    top_models =
      Repo.all(
        from(rl in RequestLog,
          where:
            rl.inserted_at >=
              ^DateTime.new!(Date.add(Date.utc_today(), -30), ~T[00:00:00], "Etc/UTC"),
          group_by: rl.model_requested,
          order_by: [desc: count(rl.id)],
          limit: 5,
          select: {rl.model_requested, count(rl.id)}
        )
      )

    errors = Repo.one(from(rl in RequestLog, where: rl.status_code >= 400, select: count(rl.id)))

    IO.puts("""

    --- Resumen del dataset ---
    · requests: #{summary.request_count}
    · costo real: $#{Decimal.round(summary.total_cost_usd, 2)}
    · tokens: #{summary.total_prompt_tokens} prompt / #{summary.total_completion_tokens} completion
    · hoy (UTC): #{today.requests_total} requests · $#{Decimal.round(today.cost_usd, 2)}
    · top modelos: #{Enum.map_join(top_models, ", ", fn {m, c} -> "#{m} (#{c})" end)}
    · filas con error: #{errors}

    --- API keys demo ---
    """)

    Enum.each(ctx.org.members, fn entry ->
      if entry.token do
        IO.puts("· #{entry.user.email} · #{entry.group.name}: #{entry.token}")
      else
        IO.puts("· #{entry.user.email} · #{entry.group.name}: usa su key existente del dashboard")
      end
    end)

    Enum.each(ctx.org.services, fn entry ->
      IO.puts("· #{entry.service.name} (service): #{entry.token}")
    end)

    IO.puts("""

    --- Puntos de prueba ---
    · /dashboard                 → consumo personal del mes (la membresía demo del admin)
    · /stats/*                   → overview, modelos, grupos (rollover), servicios, usuarios, proveedores
    · /operations/monitoring     → #{summary.request_count} logs con filtros de agente / estado / streaming / error
    · /credit/subscriptions      → subs de grupo, rollover de Growth, sub pausada de Data Lab
    · /credit/topups             → top-up activo (Ana), agotado (Luis) y vencido (Iván, archivado)
    · /calculator                → real vs estimado por modelo (hay logs con costo $0 para el backfill)
    · /catalog/providers         → 2 proveedores custom, credencial en error y credencial deshabilitada
    · /access/groups             → membresías, extras, suspensión de Bruno y servicios supervisados
    · /operations/observability  → 2 webhooks OTLP (Datadog / Grafana)
    · /catalog/labs              → lab custom "Acme Research" sobre el catálogo de models.dev

    Contraseña de todos los usuarios demo: #{@password}
    Los webhooks apuntan a hosts internos de ejemplo: el envío real NO ocurre.
    """)
  end
end

Tokengate.DemoSeeds.run()
