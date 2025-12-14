defmodule CinegraphWeb.HealthController do
  @moduledoc """
  Health check endpoints for monitoring database and service status.

  Provides endpoints for:
  - `/health` - Basic service health (always returns 200 if app is running)
  - `/health/db` - Database health including primary and replica status
  - `/health/metrics` - Detailed metrics for monitoring systems
  """
  use CinegraphWeb, :controller

  alias Cinegraph.Repo.Metrics

  @doc """
  Basic health check - returns 200 if the application is running.
  """
  def index(conn, _params) do
    json(conn, %{
      status: "ok",
      service: "cinegraph",
      timestamp: DateTime.utc_now()
    })
  end

  @doc """
  Database health check - tests connectivity to primary and replica.
  Returns 200 if at least primary is healthy, 503 otherwise.
  """
  def database(conn, _params) do
    health = Metrics.health_check()

    status_code =
      case health.primary.status do
        :healthy -> 200
        _ -> 503
      end

    conn
    |> put_status(status_code)
    |> json(%{
      status: if(status_code == 200, do: "ok", else: "degraded"),
      databases: %{
        primary: format_health_status(health.primary),
        replica: format_health_status(health.replica)
      },
      timestamp: DateTime.utc_now()
    })
  end

  @doc """
  Detailed metrics endpoint for monitoring systems.
  Returns database distribution stats, pool info, and health status.
  """
  def metrics(conn, _params) do
    health = Metrics.health_check()
    distribution = Metrics.get_distribution_stats()

    # Calculate distribution quality indicator
    total_queries = distribution.primary_queries + distribution.replica_queries
    distribution_quality = categorize_distribution(distribution.distribution_ratio, total_queries)

    json(conn, %{
      status: "ok",
      databases: %{
        primary: format_health_status(health.primary),
        replica: format_health_status(health.replica)
      },
      query_distribution: %{
        primary_queries: distribution.primary_queries,
        replica_queries: distribution.replica_queries,
        total_queries: total_queries,
        replica_percentage: distribution.distribution_ratio,
        quality: distribution_quality,
        note: Map.get(distribution, :note)
      },
      timestamp: DateTime.utc_now()
    })
  end

  @doc """
  Reset metrics counters endpoint.
  Useful for getting fresh metrics after deployment.
  """
  def reset(conn, _params) do
    case Metrics.reset_counters() do
      :ok ->
        json(conn, %{
          status: "ok",
          message: "Counters reset successfully",
          timestamp: DateTime.utc_now()
        })

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{
          status: "error",
          message: "Failed to reset counters: #{inspect(reason)}",
          timestamp: DateTime.utc_now()
        })
    end
  end

  # Categorize distribution quality based on replica percentage
  # Goal is 60%+ queries on replica per issue #469 success metrics
  defp categorize_distribution(_replica_percentage, total_queries) when total_queries < 100 do
    "insufficient_data"
  end

  defp categorize_distribution(replica_percentage, _total_queries) do
    cond do
      replica_percentage >= 60.0 -> "optimal"
      replica_percentage >= 40.0 -> "good"
      replica_percentage >= 20.0 -> "improving"
      true -> "needs_attention"
    end
  end

  defp format_health_status(%{status: status, latency_ms: latency} = health) do
    %{
      status: status,
      latency_ms: Float.round(latency, 2),
      checked_at: health.checked_at
    }
  end

  defp format_health_status(%{status: status, error: error} = health) do
    %{
      status: status,
      error: error,
      checked_at: health.checked_at
    }
  end
end
