# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :tokengate,
  ecto_repos: [Tokengate.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :tokengate, TokengateWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TokengateWeb.ErrorHTML, json: TokengateWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Tokengate.PubSub,
  live_view: [signing_salt: "cqUJx6pS"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :tokengate, Tokengate.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  tokengate: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  tokengate: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Configure Oban
config :tokengate, Oban,
  repo: Tokengate.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 0 1 * *", Tokengate.Budgets.ResetWorker}
     ]}
  ],
  queues: [default: 10, logs: 20, webhooks: 10, budgets: 5]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Filter sensitive parameters out of any request logging (Plug.Logger,
# error reporters, etc.) so secrets never land in logs in plaintext.
config :phoenix, :filter_parameters, [
  "password",
  "secret",
  "token",
  "api_key",
  "client_secret",
  "authorization"
]

# Configure the time zone database for DateTime.shift_zone/3
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

# ── Included credential wait + sticky TTL ──────────────────────────────

config :tokengate, :proxy,
  # Tiempos de espera en cola FIFO cuando una credential included está llena.
  # La llave es "cuántas included quedan después de excluir esta", el valor
  # es el timeout en milisegundos. Se toma el primer tier cuyo threshold
  # sea <= al número de included restantes (por eso 0 siempre matchea).
  included_wait_tiers: [
    {2, 3_000},
    {1, 5_000},
    {0, 30_000}
  ],
  # TTL por defecto del sticky routing según billing_mode.
  # Si el model_provider tiene sticky_ttl_ms explícito, ese gana.
  sticky_default_ttl_ms: %{
    "included" => 15 * 60 * 1000,
    "pay_per_token" => 3 * 60 * 1000
  }

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
