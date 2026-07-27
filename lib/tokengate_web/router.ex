defmodule TokengateWeb.Router do
  use TokengateWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TokengateWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
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

  # Browser routes reserved for admins (global_role == "admin").
  pipeline :browser_admin do
    plug TokengateWeb.Plugs.DashboardAuth, action: :require_admin
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
      live "/dashboard/stats", StatsLive, :index
      live "/dashboard/stats/models", StatsLive, :models
      live "/dashboard/stats/teams", StatsLive, :teams
      live "/dashboard/teams", TeamsLive
      live "/dashboard/teams/:id/members", TeamMembersLive
      live "/dashboard/logs", LogsLive
    end

    live_session :admin,
      on_mount: [{TokengateWeb.UserAuth, :require_admin}] do
      live "/dashboard/providers", ProvidersLive
      live "/dashboard/users", UsersLive
      live "/dashboard/models", ModelsLive
      live "/dashboard/keys", ApiKeysLive
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
