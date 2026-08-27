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
      # Pure HTTP/1.1 pools on purpose: SSE streams hold one connection for
      # their whole duration, and listing :http2 alongside :http1 does NOT
      # multiplex (Finch docs) — it only makes ALPN-negotiated h2 connections
      # misbehave in an HTTP1 pool (connection leak → "excess queuing" 500s
      # in prod). Idle conns live 60s to survive provider switches.
      {Finch,
       name: Tokengate.Finch,
       pools: %{
         :default => [
           size: 32,
           count: 2,
           conn_max_idle_time: 60_000
         ]
       }},
      {Oban, Application.fetch_env!(:tokengate, Oban)},
      # Ensure upcoming request_logs partitions exist at boot so today's
      # inserts hit a real partition before the nightly cron runs. One-shot,
      # idempotent, never raises (no-op when :partition_boot_ensure is false).
      Supervisor.child_spec(
        {Task, fn -> Tokengate.Logs.PartitionWorker.ensure_on_boot() end},
        id: :partition_boot_ensure,
        restart: :temporary
      ),
      Tokengate.Routing.Supervisor,
      Tokengate.Routing.Cache,
      Tokengate.Limits.Supervisor,
      Tokengate.Budgets.Supervisor,
      Tokengate.Metrics.Supervisor,
      Tokengate.Logs.Inflight,
      Tokengate.Prompts.Cache,
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
