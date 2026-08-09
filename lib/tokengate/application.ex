defmodule Tokengate.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TokengateWeb.Telemetry,
      Tokengate.Repo,
      {DNSCluster, query: Application.get_env(:tokengate, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Tokengate.PubSub},
      TokengateWeb.Presence,
      # Finch: pools sized for upstream concurrency (defaults are 1 pool ×
      # 50 conns per origin — tight when several providers share load).
      # HTTP/2 preferred with HTTP/1.1 fallback: one socket multiplexes many
      # SSE streams per provider instead of one connection per in-flight
      # request. Idle conns live 60s to survive provider switches.
      {Finch,
       name: Tokengate.Finch,
       pools: %{
         :default => [
           size: 32,
           count: 2,
           protocols: [:http2, :http1],
           conn_max_idle_time: 60_000
         ]
       }},
      {Oban, Application.fetch_env!(:tokengate, Oban)},
      Tokengate.Routing.Supervisor,
      Tokengate.Routing.Cache,
      Tokengate.Limits.Supervisor,
      Tokengate.Budgets.Supervisor,
      Tokengate.Metrics.Supervisor,
      Tokengate.Logs.Inflight,
      Tokengate.Accounts.ApiKeyCache,
      TokengateWeb.Plugs.LoginRateLimit.TableKeeper,
      TokengateWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tokengate.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TokengateWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
