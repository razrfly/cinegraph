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
      Supervisor.child_spec({Cachex, name: :predictions_cache}, id: :predictions_cache),
      # Start Cachex for movies page caching (Phase 1 optimization)
      Supervisor.child_spec(
        {Cachex, name: :movies_cache, limit: 10_000, stats: true},
        id: :movies_cache
      ),
      # Start Rate Limiter
      Cinegraph.RateLimiter,
      # Start Import Stats
      Cinegraph.Imports.ImportStats,
      # Start Dashboard Stats Cache (Issue #421)
      Cinegraph.Cache.DashboardStats,
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
          # Wait 5 seconds for app to fully initialize
          Process.sleep(5000)
          Cinegraph.Workers.CacheWarmupWorker.schedule_warmup()

          # Schedule initial movies cache warming (Phase 2 optimization)
          # This warms the cache for popular queries immediately on startup
          Cinegraph.Workers.MoviesCacheWarmer.schedule()
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
