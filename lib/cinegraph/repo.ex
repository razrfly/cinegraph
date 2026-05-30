defmodule Cinegraph.Repo do
  @moduledoc """
  Primary Ecto repository for Cinegraph.

  This repo handles all write operations and is the default for queries.
  For read-heavy operations, consider using `replica/0` to offload to
  PlanetScale read replicas.

  ## Usage

      # Writes always use primary
      Repo.insert(changeset)
      Repo.update(changeset)

      # Reads can use replica for better load distribution
      Repo.replica().all(query)
      Repo.replica().one(query)

  ## When to Use Replicas

  Use `Repo.replica()` for:
  - Public-facing read pages (movie listings, person pages)
  - Search queries
  - Analytics and aggregate queries
  - Any read that doesn't need to see just-written data

  Use `Repo` (primary) for:
  - All write operations
  - Reads immediately after writes (read-after-write consistency)
  - Oban job processing
  - Admin operations that modify data
  """

  use Ecto.Repo,
    otp_app: :cinegraph,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Returns the read replica repo for read-only queries.

  In production, this routes to PlanetScale read replicas.
  In development/test, this returns the same database (for simplicity).

  ## Kill Switch

  Set `USE_REPLICA=false` environment variable to disable replica usage
  and route all queries to the primary database. Useful for:
  - Debugging replication issues
  - Emergency failover if replicas are misbehaving
  - Testing primary-only performance

  ## Examples

      # Use for read-heavy operations
      Repo.replica().all(from m in Movie, limit: 100)

      # Aggregate queries
      Repo.replica().aggregate(Movie, :count)

  """
  @spec replica() :: module()
  def replica do
    # When called from an Oban worker context, the process dict may hold a
    # dedicated worker pool module (e.g. Repo.Worker) so that background jobs
    # don't compete with web requests for the Replica connection pool.
    Process.get(:cinegraph_job_repo) ||
      if replica_enabled?() do
        Cinegraph.Repo.Replica
      else
        # Kill switch active - use primary for all queries
        __MODULE__
      end
  end

  @doc """
  Route this process's `replica/0` calls through the dedicated worker pool
  (`Cinegraph.Repo.Worker`) instead of the web-facing replica pool.

  Call at the start of an Oban worker's `perform/1` so background jobs don't
  compete with web requests for `Repo.Replica` connections. Centralises the
  `:cinegraph_job_repo` process-dictionary contract read by `replica/0`, so the
  routing key lives in exactly one place rather than being copy/pasted across
  every worker. (#1007)
  """
  @spec route_to_worker() :: term()
  def route_to_worker do
    Process.put(:cinegraph_job_repo, Cinegraph.Repo.Worker)
  end

  # Check if replica is enabled via environment variable
  # Defaults to true (replica enabled) if not set
  defp replica_enabled? do
    case System.get_env("USE_REPLICA") do
      "false" -> false
      "0" -> false
      _ -> true
    end
  end
end
