defmodule Cinegraph.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        CinegraphWeb.Telemetry,
        Cinegraph.Repo,
        # Read replica for PlanetScale - offloads read queries from primary
        # Only started if configured (production with DATABASE_REPLICA_ENABLED=true)
        replica_child_spec(),
        # Dedicated pool for Oban background jobs — isolates from the Replica
        # pool so slow workers can't starve web page loads (#955).
        worker_child_spec(),
        {DNSCluster, query: Application.get_env(:cinegraph, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Cinegraph.PubSub},
        # Start the Finch HTTP client for sending emails
        {Finch, name: Cinegraph.Finch},
        oban_child_spec(),
        # Start Cachex for performance caching
        Supervisor.child_spec({Cachex, name: :predictions_cache}, id: :predictions_cache),
        # Start Cachex for movies page caching (Phase 1 optimization)
        Supervisor.child_spec(
          {Cachex, name: :movies_cache, limit: 10_000, stats: true},
          id: :movies_cache
        ),
        # Start Cachex for health/drift dashboards (#722)
        Supervisor.child_spec({Cachex, name: :health_cache}, id: :health_cache),
        # Catalog map + /algorithms display caches (#1084 — busts in DisplayCache/Metrics)
        Supervisor.child_spec({Cachex, name: :algorithms_cache}, id: :algorithms_cache),
        # Supervised short-lived HTTP fan-out for admin image search.
        {Task.Supervisor, name: Cinegraph.Images.TaskSupervisor},
        # Task supervisor for health/drift parallel reads — keeps unsupervised
        # Task.async out of the LiveView process tree (#722).
        {Task.Supervisor, name: Cinegraph.Health.TaskSupervisor},
        # Task supervisor for the prediction matrix's per-cell workers (#1065): async_nolink so an
        # abnormal cell crash is isolated (monitored, not linked) and can still be attributed.
        {Task.Supervisor, name: Cinegraph.Predictions.TaskSupervisor},
        # Start Rate Limiter
        Cinegraph.RateLimiter
      ] ++
        background_children() ++
        [
          # Start to serve requests, typically the last entry
          CinegraphWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cinegraph.Supervisor]

    # Initialize replica metrics tracking before starting supervisor
    Cinegraph.Repo.Metrics.init_counters()
    Cinegraph.Repo.Metrics.attach_handlers()

    # Slow-query logging (dev only — prod uses PlanetScale's slow-query analytics)
    if Application.get_env(:cinegraph, :slow_query_logger, false) do
      threshold = Application.get_env(:cinegraph, :slow_query_threshold_ms, 500)
      Cinegraph.Telemetry.SlowQueryLogger.attach(threshold)
    end

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Schedule cache warmup after application starts
        if Application.get_env(:cinegraph, :start_oban, true) &&
             Application.get_env(:cinegraph, :start_background_children, true) do
          Cinegraph.Workers.StartupWarmupWorker.schedule()
        end

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

  # Background children that hammer the DB on a timer — skip in :test env
  # since their queries run outside the per-test sandbox and crash the
  # connection pool. Re-add to the supervision tree only in :dev / :prod.
  # Controlled by `:cinegraph, :start_background_children` (default `true`;
  # `config/test.exs` sets it to `false`).
  defp background_children do
    if Application.get_env(:cinegraph, :start_oban, true) &&
         Application.get_env(:cinegraph, :start_background_children, true) do
      [
        Cinegraph.Imports.ImportStats,
        Cinegraph.Cache.DashboardStats,
        Cinegraph.Cache.AwardImportStats,
        Cinegraph.ObanPlugins.FestivalInferenceMonitor
      ]
    else
      []
    end
  end

  defp oban_child_spec do
    if Application.get_env(:cinegraph, :start_oban, true) do
      {Oban, Application.fetch_env!(:cinegraph, Oban)}
    else
      %{
        id: :oban_disabled_placeholder,
        start: {Task, :start_link, [fn -> :ok end]},
        restart: :temporary
      }
    end
  end

  # Returns child spec for replica repo if configured, otherwise a no-op
  defp replica_child_spec do
    if Application.get_env(:cinegraph, Cinegraph.Repo.Replica) do
      Cinegraph.Repo.Replica
    else
      # Return a task that does nothing when replica is not configured
      # Using restart: :temporary prevents supervisor from trying to restart this no-op task
      %{
        id: :replica_placeholder,
        start: {Task, :start_link, [fn -> :ok end]},
        restart: :temporary
      }
    end
  end

  # Returns child spec for the worker repo if configured, otherwise a no-op.
  # Only starts in production where the runtime.exs block configures it.
  defp worker_child_spec do
    if Application.get_env(:cinegraph, Cinegraph.Repo.Worker) do
      Cinegraph.Repo.Worker
    else
      %{
        id: :worker_placeholder,
        start: {Task, :start_link, [fn -> :ok end]},
        restart: :temporary
      }
    end
  end
end
