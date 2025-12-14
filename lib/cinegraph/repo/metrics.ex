defmodule Cinegraph.Repo.Metrics do
  @moduledoc """
  Metrics and monitoring for database connections.

  This module provides:
  - Periodic pool statistics measurement
  - Query distribution tracking (primary vs replica)
  - Health check utilities
  - Telemetry event handling

  ## Telemetry Events

  This module emits and handles the following telemetry events:

  ### Pool Metrics (periodic, every 10s)
  - `[:cinegraph, :repo, :pool, :size]` - Primary pool size
  - `[:cinegraph, :repo, :pool, :available]` - Primary available connections
  - `[:cinegraph, :repo, :replica, :pool, :size]` - Replica pool size
  - `[:cinegraph, :repo, :replica, :pool, :available]` - Replica available connections

  ### Query Metrics (attached to Ecto telemetry)
  - `[:cinegraph, :repo, :replica, :query, :*]` - Replica query timing metrics
  """

  require Logger

  @doc """
  Measures pool statistics for both primary and replica repos.
  Called periodically by telemetry_poller.
  """
  def measure_pool_stats do
    measure_repo_pool(Cinegraph.Repo, [:cinegraph, :repo, :pool])
    measure_repo_pool(Cinegraph.Repo.Replica, [:cinegraph, :repo, :replica, :pool])
  end

  defp measure_repo_pool(repo, event_prefix) do
    try do
      # Get the DBConnection pool from the repo
      case get_pool_stats(repo) do
        {:ok, stats} ->
          :telemetry.execute(
            event_prefix ++ [:size],
            %{value: stats.pool_size},
            %{repo: repo}
          )

          :telemetry.execute(
            event_prefix ++ [:available],
            %{value: stats.available},
            %{repo: repo}
          )

        {:error, reason} ->
          Logger.debug("Could not get pool stats for #{inspect(repo)}: #{inspect(reason)}")
      end
    rescue
      e ->
        Logger.debug("Error measuring pool stats for #{inspect(repo)}: #{inspect(e)}")
    end
  end

  defp get_pool_stats(repo) do
    try do
      # Get the pool from the repo's config
      config = repo.config()
      pool_size = Keyword.get(config, :pool_size, 10)

      # Try to get checkout queue length from DBConnection
      # This is a best-effort measurement
      {:ok,
       %{
         pool_size: pool_size,
         # In production, we'd use DBConnection.get_connection_metrics/1
         # For now, estimate available as pool_size (conservative)
         available: pool_size
       }}
    rescue
      _ -> {:error, :config_unavailable}
    end
  end

  @doc """
  Returns database health status for both primary and replica.

  ## Examples

      iex> Cinegraph.Repo.Metrics.health_check()
      %{
        primary: %{status: :healthy, latency_ms: 1.2},
        replica: %{status: :healthy, latency_ms: 0.8}
      }
  """
  def health_check do
    %{
      primary: check_repo_health(Cinegraph.Repo),
      replica: check_repo_health(Cinegraph.Repo.Replica)
    }
  end

  @doc """
  Checks health of a specific repo.
  """
  def check_repo_health(repo) do
    start_time = System.monotonic_time(:microsecond)

    try do
      # Simple SELECT 1 query to test connectivity
      case repo.query("SELECT 1") do
        {:ok, _} ->
          latency = System.monotonic_time(:microsecond) - start_time

          %{
            status: :healthy,
            latency_ms: latency / 1000,
            checked_at: DateTime.utc_now()
          }

        {:error, reason} ->
          %{
            status: :unhealthy,
            error: inspect(reason),
            checked_at: DateTime.utc_now()
          }
      end
    rescue
      e ->
        %{
          status: :unhealthy,
          error: Exception.message(e),
          checked_at: DateTime.utc_now()
        }
    end
  end

  @doc """
  Returns summary statistics for database distribution.
  Useful for monitoring read distribution between primary and replica.
  """
  def get_distribution_stats do
    # This would typically pull from a metrics aggregator
    # For now, return structure that can be populated
    %{
      primary_queries: :counters.get(:repo_query_counter, 1),
      replica_queries: :counters.get(:repo_query_counter, 2),
      distribution_ratio: calculate_distribution_ratio()
    }
  rescue
    _ ->
      %{
        primary_queries: 0,
        replica_queries: 0,
        distribution_ratio: 0.0,
        note: "Counters not initialized"
      }
  end

  defp calculate_distribution_ratio do
    primary = :counters.get(:repo_query_counter, 1)
    replica = :counters.get(:repo_query_counter, 2)
    total = primary + replica

    if total > 0 do
      Float.round(replica / total * 100, 1)
    else
      0.0
    end
  rescue
    _ -> 0.0
  end

  @doc """
  Initializes query counters for distribution tracking.
  Should be called during application startup.
  """
  def init_counters do
    # Create a counter reference with 2 slots: [primary, replica]
    ref = :counters.new(2, [:write_concurrency])
    :persistent_term.put(:repo_query_counter, ref)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Increments the primary query counter.
  Called by telemetry handler for primary repo queries.
  """
  def increment_primary_count do
    ref = :persistent_term.get(:repo_query_counter)
    :counters.add(ref, 1, 1)
  rescue
    _ -> :ok
  end

  @doc """
  Increments the replica query counter.
  Called by telemetry handler for replica repo queries.
  """
  def increment_replica_count do
    ref = :persistent_term.get(:repo_query_counter)
    :counters.add(ref, 2, 1)
  rescue
    _ -> :ok
  end

  @doc """
  Attaches telemetry handlers for query counting.
  Should be called during application startup.

  Ecto repos emit telemetry events with the pattern:
  - Primary: [:cinegraph, :repo, :query]
  - Replica: [:cinegraph, :repo, :replica, :query]

  We attach handlers to track query counts and distribution.
  """
  def attach_handlers do
    # Handler for primary repo queries
    :telemetry.attach(
      "cinegraph-repo-primary-counter",
      [:cinegraph, :repo, :query],
      &__MODULE__.handle_primary_query/4,
      nil
    )

    # Handler for replica repo queries
    :telemetry.attach(
      "cinegraph-repo-replica-counter",
      [:cinegraph, :repo, :replica, :query],
      &__MODULE__.handle_replica_query/4,
      nil
    )

    Logger.info(
      "[Repo.Metrics] Telemetry handlers attached for primary and replica query tracking"
    )

    :ok
  end

  @doc false
  def handle_primary_query(_event, measurements, metadata, _config) do
    increment_primary_count()

    # Log slow queries (> 1 second) for monitoring
    if measurements[:total_time] && measurements[:total_time] > 1_000_000_000 do
      query = Map.get(metadata, :query, "unknown")
      time_ms = div(measurements[:total_time], 1_000_000)
      Logger.warning("[Repo.Primary] Slow query (#{time_ms}ms): #{String.slice(query, 0, 100)}")
    end
  end

  @doc false
  def handle_replica_query(_event, measurements, metadata, _config) do
    increment_replica_count()

    # Log slow queries (> 1 second) for monitoring
    if measurements[:total_time] && measurements[:total_time] > 1_000_000_000 do
      query = Map.get(metadata, :query, "unknown")
      time_ms = div(measurements[:total_time], 1_000_000)
      Logger.warning("[Repo.Replica] Slow query (#{time_ms}ms): #{String.slice(query, 0, 100)}")
    end
  end

  @doc """
  Returns a summary of the current database monitoring state.
  Useful for dashboards and debugging.
  """
  def summary do
    health = health_check()
    distribution = get_distribution_stats()

    %{
      health: %{
        primary: health.primary.status,
        replica: health.replica.status
      },
      distribution: %{
        primary_queries: distribution.primary_queries,
        replica_queries: distribution.replica_queries,
        replica_percentage: distribution.distribution_ratio
      },
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Resets query counters to zero.
  Useful for testing or after deployments to get fresh metrics.
  """
  def reset_counters do
    try do
      ref = :persistent_term.get(:repo_query_counter)
      :counters.put(ref, 1, 0)
      :counters.put(ref, 2, 0)
      :ok
    rescue
      _ -> {:error, :counters_not_initialized}
    end
  end
end
