defmodule TokengateWeb.Router do
  use TokengateWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TokengateWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self' wss: ws:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
      "permissions-policy" =>
        "camera=(), microphone=(), geolocation=(), payment=(), usb=(), magnetometer=(), gyroscope=(), accelerometer=()"
    }

    # Loads :current_user from the session so every browser request (including
    # LiveView mounts) has access to the signed-in user.
    plug TokengateWeb.Plugs.DashboardAuth, action: :fetch_current_user
  end

  # Browser routes that require an authenticated user. The
  # :require_authenticated plug short-circuits with a redirect to /login
  # when the visitor is not signed in.
  pipeline :browser_auth do
    plug TokengateWeb.Plugs.DashboardAuth, action: :require_authenticated
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Admin-only routes reached by a plain GET (CSV exports). The user is
  # loaded by `:browser`, then require_admin redirects non-admins.
  pipeline :admin_auth do
    plug TokengateWeb.Plugs.DashboardAuth, action: :require_admin
  end

  pipeline :proxy_api do
    # No `:accepts` negotiation: this API is a passthrough. A tts client may
    # legitimately ask for `Accept: audio/mpeg` and the response content-type
    # is the UPSTREAM's own (the controller writes it explicitly, `json/1`
    # included). An `accepts` list would 406 that client before the controller
    # ever runs — the negotiation belongs to the upstream, not here.
    plug TokengateWeb.Plugs.ApiAuth
  end

  # Liveness probe for the container/proxy. Deliberately OUTSIDE :browser (no
  # session, no CSRF, no cookie decrypt) and with NO database access: it runs
  # while the app is still warming up, which is when the pool is busiest. Use
  # this path as the healthcheck target, NOT `/` — `/` redirects to /login (302)
  # and a proxy configured to expect 200 reads that as "down" (502 Bad Gateway
  # with a perfectly healthy container).
  scope "/", TokengateWeb do
    get "/health", HealthController, :show
  end

  scope "/", TokengateWeb do
    pipe_through :browser

    get "/", PageController, :home

    # Session (login/logout). The login form is public; logout requires
    # a session but the plug just clears it if absent, so we keep both
    # in the plain :browser pipeline.
    get "/login", SessionController, :new

    scope "/" do
      pipe_through TokengateWeb.Plugs.LoginRateLimit

      post "/login", SessionController, :create
    end

    delete "/logout", SessionController, :delete

    # Impersonation — guards live inside the controller actions (the start
    # route requires a real admin; the stop route runs while the session
    # points at the impersonated user, so no admin plug can guard it).
    post "/impersonate/:user_id", SessionController, :impersonate
    delete "/impersonate", SessionController, :stop_impersonating

    # Google OAuth — public routes (no auth required to start the flow).
    get "/auth/google", OAuthController, :request
    get "/auth/google/callback", OAuthController, :callback

    # Créditos vivía en /dashboard/credits — ahora es un tab de
    # /stats. Redirect permanente para bookmarks.
    get "/dashboard/credits", RedirectController, :stats_credits

    # Stats vivía en /dashboard/stats, la calculadora en
    # /dashboard/calculator y los logs en /logs. Redirects
    # permanentes para bookmarks (query string preservado).
    get "/dashboard/stats", RedirectController, :stats
    get "/dashboard/stats/*rest", RedirectController, :stats
    get "/dashboard/calculator", RedirectController, :calculator
    # La página de logs se promovió a /operations/monitoring.
    get "/logs", RedirectController, :logs

    # Los servicios supervisados dejaron de ser una subpágina del
    # dashboard: viven en /services/supervised (sección propia).
    get "/dashboard/services/supervised", RedirectController, :supervised_services

    # Refactor /stats: el detalle de miembro se consolidó en el detalle
    # de usuario. El prefijo /admin se retiró en favor de las
    # sub-secciones del sidebar, así que sus rutas legacy
    # (la vieja de logs, y la de stats por usuario) se eliminaron con
    # él: no hay redirects para /admin/*.
    get "/stats/members/:member_id", RedirectController, :stats_member
    get "/stats/members/:member_id/*rest", RedirectController, :stats_member

    # El tab Créditos se disolvió: el uso de presupuesto vive dentro de
    # cada dimensión (En vivo, Resumen, Usuarios, Perfiles de límites, Servicios).
    get "/stats/credits", RedirectController, :stats_credits
    get "/stats/credits/*rest", RedirectController, :stats_credits

    # El hub de stats llamaba «grupos» al sujeto del techo mensual; el
    # vocabulario es ahora «perfil de límites», así que las URLs viejas
    # (/stats/groups[...rest]) caen en /stats/profiles[...rest] con la
    # subruta y la query string preservadas.
    get "/stats/groups", RedirectController, :stats_profiles
    get "/stats/groups/*rest", RedirectController, :stats_profiles

    # La página de suscripciones desapareció con el modelo: el presupuesto se
    # gobierna con el techo mensual del sujeto y los top-ups. Un bookmark
    # viejo cae en la página de top-ups, que es la única de crédito extra.
    get "/credit/subscriptions", RedirectController, :credit_subscriptions
    get "/credit/subscriptions/*rest", RedirectController, :credit_subscriptions

    # La sección «Crédito» pasó a «Presupuesto» y el sujeto del techo mensual
    # se llama ahora «perfil de límites»: su página vive en /budget/profiles.
    # Las dos generaciones anteriores de esa URL (/access/groups y
    # /budget/months) siguen respondiendo con un redirect permanente. La
    # subruta se preserva (/access/groups/:id/members →
    # /budget/profiles/:id/members) y la query string también.
    get "/access/groups", RedirectController, :budget_months
    get "/access/groups/*rest", RedirectController, :budget_months
    get "/budget/months", RedirectController, :budget_months
    get "/budget/months/*rest", RedirectController, :budget_months
    get "/credit/topups", RedirectController, :budget_topups
    get "/credit/topups/*rest", RedirectController, :budget_topups
  end

  # Authenticated browser dashboard. The on_mount hook mirrors the plug
  # for LiveView socket reconnects (where plugs don't run again).
  scope "/", TokengateWeb do
    pipe_through :browser

    live_session :dashboard,
      on_mount: [{TokengateWeb.UserAuth, :require_authenticated}] do
      live "/dashboard", DashboardLive
    end

    # Read-only views of the services the current user supervises. Access is
    # granted ONLY by a live `service_supervisors` row — no role involved — so
    # removing a user as supervisor revokes the access (checked on every mount,
    # sockets included, plus a hot PubSub notice for views already open).
    live_session :service_viewer,
      on_mount: [{TokengateWeb.UserAuth, :require_service_supervisor}] do
      live "/services/supervised", SupervisedServicesLive
      live "/services/supervised/:service_id", SupervisedServiceStatsLive
    end

    live_session :admin,
      on_mount: [{TokengateWeb.UserAuth, :require_admin}] do
      live "/stats", StatsLive, :live
      live "/stats/overview", StatsLive, :index
      live "/stats/models", StatsLive, :models
      live "/stats/models/:model_id", StatsLive, :model
      live "/stats/services", StatsLive, :services
      live "/stats/services/:service_id", ServiceStatsLive
      # El sujeto del techo mensual se llama «perfil de límites»: la página
      # sigue siendo el hub de StatsLive (acciones :groups/:group) y las URLs
      # viejas /stats/groups[...] redirigen aquí.
      live "/stats/profiles", StatsLive, :groups
      live "/stats/profiles/:group_id", StatsLive, :group
      live "/stats/providers", StatsLive, :providers
      live "/stats/providers/:provider_id", StatsLive, :provider
      live "/stats/users", StatsLive, :users
      live "/stats/users/:user_id", UserStatsLive
      live "/calculator", CalculatorLive

      # Las rutas admin se agrupan por la sub-sección del sidebar a la
      # que pertenecen (Catálogo / Acceso / Presupuesto / Operaciones). El
      # prefijo /admin se retiró: no hay redirects legacy, un bookmark
      # a /admin/* responde 404.
      # Catálogo — qué se sirve y a qué costo.
      live "/catalog/providers", ProvidersLive
      live "/catalog/models", ModelsLive
      live "/catalog/labs", LabsLive
      # Acceso — quién puede usar qué.
      live "/access/users", UsersLive
      live "/access/services", ServicesLive
      # Presupuesto — qué techo mensual tiene cada sujeto y qué crédito extra
      # lleva encima. Los perfiles de límites (antes «subs» / «grupos») son el
      # sujeto del que cada usuario hereda su techo; los top-ups son crédito
      # de un solo uso. El gasto ordinario se edita en la página de su sujeto.
      # El tope diario global (kill-switch de todo el gateway y sus exenciones)
      # también vive aquí: es una palanca de presupuesto, no de operaciones.
      live "/budget/profiles", GroupsLive
      live "/budget/profiles/:id/members", GroupMembersLive
      live "/budget/topups", TopupsLive
      live "/budget/global", GlobalCapLive
      # Operaciones — logs en vivo, webhooks y danger zone.
      live "/operations/monitoring", MonitoringLive
      live "/operations/observability", ObservabilityLive
      live "/operations/audit", AuditLive
      live "/operations/maintenance", MaintenanceLive
    end
  end

  # CSV export — regular controller action (not LiveView) requiring auth.
  scope "/stats", TokengateWeb do
    pipe_through [:browser, :browser_auth]
    get "/export", StatsExportController, :export
  end

  # Audit CSV export — admin only.
  scope "/operations", TokengateWeb do
    pipe_through [:browser, :browser_auth, :admin_auth]
    get "/audit/export", AuditExportController, :export
  end

  # OpenAI-compatible proxy API — authenticated via bearer API key
  scope "/v1", TokengateWeb do
    pipe_through :proxy_api

    get "/models", ProxyController, :models
    post "/chat/completions", ProxyController, :chat_completions
    post "/embeddings", ProxyController, :embeddings

    # The rest of a provider's services. The segment here is the gateway's
    # public name for the capability, NOT the upstream path: the URL is
    # `base_url` + what `ProviderPaths` resolves (operator override in the
    # Capacidades modal → catalog hardcode → generic default).
    post "/rerank", ProxyController, :rerank
    post "/audio/transcriptions", ProxyController, :transcriptions
    post "/audio/speech", ProxyController, :speech
    post "/images/generations", ProxyController, :image_generations
    post "/videos", ProxyController, :video_generations
    post "/music/generations", ProxyController, :music_generations
  end

  # Other scopes may use custom stacks.
  # scope "/api", TokengateWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:tokengate, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TokengateWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
