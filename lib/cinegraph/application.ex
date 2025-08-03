defmodule Cinegraph.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CinegraphWeb.Telemetry,
      Cinegraph.Repo,
      {DNSCluster, query: Application.get_env(:cinegraph, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Cinegraph.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, 
       name: Cinegraph.Finch,
       pools: %{
         :default => [size: 10, count: 2],
         "https://api.themoviedb.org" => [
           size: 10,
           count: 2,
           conn_opts: [
             transport_opts: [
               timeout: 30_000,
               # Keep connections alive longer
               keepalive: :timer.minutes(5),
               # Reuse connections
               reuse_sessions: true
             ]
           ]
         ]
       }},
      # Start Oban
      {Oban, Application.fetch_env!(:cinegraph, Oban)},
      # Start Rate Limiter
      Cinegraph.RateLimiter,
      # Start Import Stats
      Cinegraph.Import.ImportStats,
      # Start a worker by calling: Cinegraph.Worker.start_link(arg)
      # {Cinegraph.Worker, arg},
      # Start to serve requests, typically the last entry
      CinegraphWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cinegraph.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CinegraphWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
