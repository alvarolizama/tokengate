defmodule Tokengate.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  # The dashboard and /stats compare the current period against the one before
  # it; the widest selector ("30d") reaches ~60 days back through
  # `Periods.previous_period_bounds/2`. Below that, `request_logs` no longer
  # has the rows and the delta silently becomes "last N days vs whatever is
  # left" — correct-looking, wrong. Not enforced, only surfaced: an operator
  # may have a real reason to trim that far.
  @min_retention_days 60

  @impl true
  def start(_type, _args) do
    warn_on_short_retention()

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
      # Ensure upcoming audit_logs monthly partitions exist at boot. One-shot,
      # idempotent, never raises (no-op when :audit_partition_boot_ensure is false).
      Supervisor.child_spec(
        {Task, fn -> Tokengate.Auditing.PartitionWorker.ensure_on_boot() end},
        id: :audit_partition_boot_ensure,
        restart: :temporary
      ),
      # Materialize the builtin provider catalog (upsert by key, never
      # touches custom rows). One-shot, idempotent, failures logged not
      # raised — the app must boot.
      Tokengate.Providers.CatalogSync,
      Tokengate.Routing.Supervisor,
      Tokengate.Routing.Cache,
      Tokengate.Limits.Supervisor,
      Tokengate.Budgets.Supervisor,
      Tokengate.Metrics.Supervisor,
      Tokengate.Logs.Inflight,
      Tokengate.Accounts.ApiKeyCache,
      # Generic hot-path ETS cache (observability destinations, other small
      # hot-path sets). Owns its table; see Tokengate.Cache.
      Tokengate.Cache,
      # Cross-node propagation of cache invalidations over the PubSub above.
      # The caches are per-node ETS; a write on one node must drop the same
      # entry everywhere instead of waiting out each node's TTL.
      Tokengate.CacheInvalidation,
      # Telegram notifications: owner of the settings cache and the
      # anti-repetition table, plus the single emit funnel (`Notifications.emit/2`).
      Tokengate.Notifications,
      # Gateway-local response cache for identical non-streaming requests
      # (embeddings re-indexing, retries, dashboard refreshes). Zero-cost
      # hits on a short TTL; see Tokengate.Proxy.ResponseCache.
      Tokengate.Proxy.ResponseCache,
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

  defp warn_on_short_retention do
    days = Tokengate.Logs.PartitionWorker.retention_days()

    if days < @min_retention_days do
      Logger.warning(
        "logs_retention_days is #{days}, below the #{@min_retention_days} days the " <>
          "dashboard's 30d deltas need (the previous 30-day window reaches ~60 days back). " <>
          "Period-over-period comparisons will silently under-report until it is raised."
      )
    else
      :ok
    end
  end
end
