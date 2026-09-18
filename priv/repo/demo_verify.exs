# Verificación post-seed: ejercita las mismas funciones de contexto que usan
# las LiveViews, para confirmar que cada pantalla tiene datos reales.
#   mix run priv/repo/demo_verify.exs

alias Tokengate.{Accounts, Budgets, Credits, Logs, Periods, Providers}
alias Tokengate.Credits.Topups
alias Tokengate.Metrics.Rollup
alias TokengateWeb.TopupHelpers

ok = fn label, value -> IO.puts("  ✓ #{label}: #{value}") end

IO.puts("\n=== Verificación del dataset demo ===\n")

# --- Dashboard personal (admin) -------------------------------------------------
admin = Accounts.get_user_by_email("admin@tokengate.local")
members = Accounts.list_group_members_for_user(admin.id)
member_ids = Enum.map(members, & &1.id)

bounds_30d = Periods.period_bounds("30d", admin.timezone)

summary =
  Rollup.summary_for_members(from: bounds_30d.from, to: bounds_30d.to, member_ids: member_ids)

ok.(
  "dashboard · summary 30d",
  "#{summary.request_count} req · $#{Decimal.round(summary.total_cost_usd, 2)}"
)

bounds_7d = Periods.period_bounds("7d", admin.timezone)

# La serie por grupo consulta sólo miembros de ese grupo (Platform Crew es el
# de tráfico denso); la serie por miembros es la que consume el dashboard.
platform = Enum.find(Accounts.list_groups(), &(&1.name == "Platform Crew"))

series = Rollup.hourly_series(platform.id, from: bounds_7d.from, to: bounds_7d.to)
ok.("dashboard · serie horaria 7d (Platform Crew)", "#{length(series)} buckets")

member_series =
  Rollup.hourly_series_for_members(member_ids, from: bounds_7d.from, to: bounds_7d.to)

ok.("dashboard · serie horaria 7d (miembros)", "#{length(member_series)} buckets")

by_model = Rollup.breakdown_by_model(nil, from: bounds_30d.from, to: bounds_30d.to)
ok.("stats · breakdown por modelo", "#{length(by_model)} modelos")

by_member = Rollup.breakdown_by_member(nil, from: bounds_30d.from, to: bounds_30d.to)
ok.("stats · breakdown por miembro", "#{length(by_member)} miembros")

# --- /stats --------------------------------------------------------------------
bounds_today = Periods.period_bounds("today", "America/Merida")
today_summary = Logs.today_summary("America/Merida")

ok.(
  "stats · hoy (UTC)",
  "#{today_summary.requests_total} req · $#{Decimal.round(today_summary.cost_usd, 2)}"
)

_ = bounds_today

prev = Periods.previous_period_bounds("7d", "Etc/UTC")
week = Periods.period_bounds("7d", "Etc/UTC")
week_summary = Rollup.summary_from_rollup(from: week.from, to: week.to)
prev_summary = Rollup.summary_from_rollup(from: prev.from, to: prev.to)

ok.(
  "stats · 7d vs período previo",
  "#{week_summary.request_count} vs #{prev_summary.request_count}"
)

ranking = Rollup.provider_ranking(nil, from: week.from, to: week.to)

ok.(
  "stats · ranking de proveedores",
  Enum.map_join(Enum.take(ranking, 3), ", ", & &1.provider_name)
)

models_ranking = Rollup.model_ranking(nil, from: week.from, to: week.to)
ok.("stats · ranking de modelos", "#{length(models_ranking)} modelos")

by_hour = Rollup.usage_by_hour_of_day(nil, from: week.from, to: week.to)
ok.("stats · uso por hora del día", "#{length(by_hour)} horas con datos")

stacked = Rollup.usage_by_model_provider_stacked(from: week.from, to: week.to)
ok.("stats · modelo × proveedor (stacked)", "#{length(stacked)} series")

hours = Rollup.busiest_hours(nil, from: week.from, to: week.to)
minutes = Rollup.busiest_minutes(nil, from: week.from, to: week.to)
ok.("stats · horas y minutos pico", "#{length(hours)} / #{length(minutes)}")

peak = Rollup.peak_concurrency(nil, from: week.from, to: week.to)
ok.("stats · concurrencia pico", "#{peak.max_concurrent} (@ #{peak.at})")

tiers = Rollup.member_usage_tiers(nil, from: bounds_30d.from, to: bounds_30d.to)

ok.(
  "stats · tiers de miembros",
  Enum.map_join(tiers, ", ", &"#{&1.user_name || &1.user_email}=#{&1.tier}")
)

errors = Rollup.top_errors(nil, from: bounds_30d.from, to: bounds_30d.to)
ok.("stats · top errores", Enum.map_join(errors, ", ", &"#{&1.status_code}×#{&1.error_count}"))

agents = Rollup.agent_breakdown(nil)
ok.("stats · desglose por agente", "#{map_size(agents)} agentes")

by_group = Rollup.breakdown_by_group(from: bounds_30d.from, to: bounds_30d.to)
ok.("stats · desglose por grupo", "#{length(by_group)} grupos")

services = Accounts.list_services()

by_service =
  Rollup.service_summaries(Enum.map(services, & &1.id), from: bounds_30d.from, to: bounds_30d.to)

ok.("stats · resumen por servicio", "#{map_size(by_service)} servicios")

for_model =
  Rollup.breakdown_by_provider_for_model(List.first(by_model).model_id,
    from: bounds_30d.from,
    to: bounds_30d.to
  )

ok.("stats · detalle modelo → proveedores", "#{length(for_model)} rutas")

# --- /operations/monitoring -----------------------------------------------------
logs = Logs.list_logs(%{limit: 50})
ok.("monitoring · últimos logs", "#{length(logs)} filas")

by_status = Logs.list_logs(%{status_class: "5xx", limit: 20})
ok.("monitoring · filtro 5xx", "#{length(by_status)} filas")

streaming = Logs.list_logs(%{streaming: true, limit: 20})
ok.("monitoring · filtro streaming", "#{length(streaming)} filas")

errors_only = Logs.list_logs(%{status_class: "errors", limit: 500})
ok.("monitoring · filtro de errores", "#{length(errors_only)} filas")

top_models_1m = Logs.top_models_last_minutes(1, 3)
ok.("monitoring · top modelos (1 min)", "#{length(top_models_1m)}")

export = Logs.list_logs_for_export(%{from: bounds_30d.from, limit: 5_000})
ok.("monitoring · export CSV 30d", "#{length(export)} filas")

realtime = Logs.realtime_summary(%{}, 300)

ok.(
  "monitoring · resumen en vivo",
  "#{realtime.request_count} req/5min · #{realtime.req_per_min} rpm"
)

top_models_1m = Logs.top_models_last_minutes(1, 3)
ok.("monitoring · top modelos (último minuto)", "#{length(top_models_1m)} modelos")

top_users_1m = Logs.top_users_last_minutes(1, 3)
ok.("monitoring · top usuarios (último minuto)", "#{length(top_users_1m)} usuarios")

hour_provider = Logs.today_usage_by_hour_provider()
ok.("stats live · hoy por hora × proveedor", "#{length(hour_provider)} horas")

member_stats = Logs.member_stats(member_ids)

ok.(
  "user stats · member_stats",
  "#{member_stats.request_count} req · #{length(member_stats.top_models)} top modelos"
)

service_stats = Logs.service_stats(Enum.at(services, 0).id)
ok.("service stats · service_stats", "#{service_stats.request_count} req")

# --- /budget (perfiles de límites + top-ups) ------------------------------------
member_budgets = Budgets.list_member_budgets("America/Merida")
ok.("access · presupuestos por miembro", "#{length(member_budgets)} filas")

exhausted = Budgets.count_exhausted("America/Merida")
ok.("access · miembros agotados", exhausted)

service_budgets = Budgets.list_service_budgets()
ok.("access · presupuestos por servicio", "#{length(service_budgets)} filas")

group_budgets = Budgets.list_group_budgets("America/Merida")
ok.("budget · presupuestos por perfil", "#{length(group_budgets)} filas")

global = Budgets.global_daily_budget_summary()

ok.(
  "budget · tope global",
  "$#{Decimal.round(global.daily_spend_usd, 2)} de $#{global.daily_cap_usd} " <>
    "(#{global.exempt_count} exenciones)"
)

# Crédito: límite efectivo + top-ups del sujeto (lo que resuelve el proxy).
credits = Enum.map(members, &Credits.summary({:user, &1.user_id}, Credits.user_limit(&1)))
with_path = Enum.count(credits, & &1.has_path?)
unlimited = Enum.count(credits, & &1.unlimited?)
with_topup = Enum.count(credits, &(Decimal.compare(&1.remaining_topup_usd, 0) == :gt))

ok.(
  "crédito · miembros con camino de gasto",
  "#{with_path}/#{length(credits)} (#{unlimited} ilimitados, #{with_topup} con top-up)"
)

topups = Topups.list_all()

ok.(
  "crédito · top-ups",
  "#{length(topups)} (#{Enum.count(topups, &(&1.status == "active"))} activos)"
)

topup_usage =
  for topup <- topups do
    "#{topup.label} = #{TopupHelpers.usd(Topups.remaining_usd(topup))} de #{TopupHelpers.usd(topup.amount_usd)}"
  end

ok.("crédito · remanente por top-up", Enum.join(topup_usage, " · "))

expired_topup = Enum.find(topups, &(&1.label == "Top-up · Iván (vencido)"))

ok.(
  "crédito · top-up vencido detectado",
  expired_topup != nil and TopupHelpers.archived?(expired_topup)
)

# --- Catálogo -------------------------------------------------------------------
providers = Providers.list_providers()
custom = Enum.filter(providers, &(&1.key == nil))
ok.("catálogo · proveedores custom", Enum.map_join(custom, ", ", & &1.name))

error_creds = Providers.count_error_credentials()
ok.("catálogo · credenciales en error", error_creds)

models = Providers.list_models()

ok.(
  "catálogo · modelos",
  "#{length(models)} (#{Enum.count(models, &(&1.model_type == "embedding"))} embedding)"
)

exclusives =
  Providers.list_model_providers()
  |> Enum.filter(
    &(&1.exclusive_to_group_id || &1.exclusive_to_group_member_id || &1.exclusive_to_service_id)
  )

ok.("catálogo · rutas exclusivas", length(exclusives))

labs = Providers.list_labs()
ok.("catálogo · labs", "#{length(labs)} (#{Enum.count(labs, &(&1.source == "custom"))} custom)")

destinations = Tokengate.Observability.list_all_destinations()
ok.("observabilidad · webhooks", Enum.map_join(destinations, ", ", & &1.name))

demo_group = Enum.find(Accounts.list_groups(), &(&1.name == "Platform Crew"))
platform_member = Enum.find(members, &(&1.group_id == demo_group.id))
accessible = Providers.list_accessible_models(platform_member)

ok.(
  "routing · modelos accesibles (Platform Crew)",
  "#{length(accessible)} de #{length(models)}"
)

member_preloaded = Tokengate.Repo.preload(platform_member, [:group, :api_key])
ok.("routing · límites efectivos", inspect(Accounts.effective_limits(member_preloaded)))

IO.puts("\n=== Dataset OK ===\n")
