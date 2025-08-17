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
      {Finch, name: Cinegraph.Finch},
      # Start Oban
      {Oban, Application.fetch_env!(:cinegraph, Oban)},
      # Start Cachex for performance caching
      {Cachex, name: :predictions_cache},
      # Start Rate Limiter
      Cinegraph.RateLimiter,
      # Start Import Stats
      Cinegraph.Imports.ImportStats,
      # Start Festival Inference Monitor (Issue #286)
      Cinegraph.ObanPlugins.FestivalInferenceMonitor,
      # Start a worker by calling: Cinegraph.Worker.start_link(arg)
      # {Cinegraph.Worker, arg},
      # Start to serve requests, typically the last entry
      CinegraphWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cinegraph.Supervisor]
    
    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Schedule cache warmup after application starts
        Task.start(fn ->
          Process.sleep(5000)  # Wait 5 seconds for app to fully initialize
          Cinegraph.Workers.CacheWarmupWorker.schedule_warmup()
        end)
        {:ok, pid}
      
      error ->
        error
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CinegraphWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
