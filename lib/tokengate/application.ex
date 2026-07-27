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
      {Finch, name: Tokengate.Finch},
      {Oban, Application.fetch_env!(:tokengate, Oban)},
      Tokengate.Routing.Supervisor,
      Tokengate.Limits.Supervisor,
      Tokengate.Budgets.Supervisor,
      Tokengate.Metrics.Supervisor,
      Tokengate.Logs.Inflight,
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
