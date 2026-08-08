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
        "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; connect-src 'self' wss: ws:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
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

  pipeline :proxy_api do
    plug :accepts, ["json"]
    plug TokengateWeb.Plugs.ApiAuth
  end

  scope "/", TokengateWeb do
    pipe_through :browser

    get "/", PageController, :home

    # Session (login/logout). The login form is public; logout requires
    # a session but the plug just clears it if absent, so we keep both
    # in the plain :browser pipeline.
    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete

    # Impersonation — guards live inside the controller actions (the start
    # route requires a real admin; the stop route runs while the session
    # points at the impersonated user, so no admin plug can guard it).
    post "/impersonate/:user_id", SessionController, :impersonate
    delete "/impersonate", SessionController, :stop_impersonating

    # Google OAuth — public routes (no auth required to start the flow).
    get "/auth/google", OAuthController, :request
    get "/auth/google/callback", OAuthController, :callback
  end

  # Authenticated browser dashboard. The on_mount hook mirrors the plug
  # for LiveView socket reconnects (where plugs don't run again).
  scope "/", TokengateWeb do
    pipe_through :browser

    live_session :dashboard,
      on_mount: [{TokengateWeb.UserAuth, :require_authenticated}] do
      live "/dashboard", DashboardLive
    end

    # Read-only view of the services the current user supervises. Open to
    # any authenticated user (admin or not) — supervisors are read-only.
    live_session :service_viewer,
      on_mount: [{TokengateWeb.UserAuth, :require_authenticated}] do
      live "/dashboard/services/supervised", SupervisedServicesLive
    end

    live_session :admin,
      on_mount: [{TokengateWeb.UserAuth, :require_admin}] do
      live "/dashboard/stats", StatsLive, :index
      live "/dashboard/stats/models", StatsLive, :models
      live "/dashboard/stats/teams", StatsLive, :teams
      live "/dashboard/stats/services", StatsLive, :services
      live "/dashboard/stats/members/:member_id", StatsLive, :member
      live "/dashboard/teams", TeamsLive
      live "/dashboard/teams/:id/members", TeamMembersLive
      live "/dashboard/services", ServicesLive
      live "/dashboard/monitor", MonitorLive
      live "/dashboard/logs", LogsLive
      live "/dashboard/providers", ProvidersLive
      live "/dashboard/users", UsersLive
      live "/dashboard/users/:user_id/stats", UserStatsLive
      live "/dashboard/models", ModelsLive
      live "/dashboard/credits", CreditsLive
      live "/dashboard/settings", SettingsLive
    end
  end

  # CSV export — regular controller action (not LiveView) requiring auth.
  scope "/dashboard/stats", TokengateWeb do
    pipe_through [:browser, :browser_auth]
    get "/export", StatsExportController, :export
  end

  # OpenAI-compatible proxy API — authenticated via bearer API key
  scope "/v1", TokengateWeb do
    pipe_through :proxy_api

    get "/models", ProxyController, :models
    post "/chat/completions", ProxyController, :chat_completions
    post "/embeddings", ProxyController, :embeddings
    post "/rerank", ProxyController, :rerank
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
