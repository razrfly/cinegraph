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

  ## Examples

      # Use for read-heavy operations
      Repo.replica().all(from m in Movie, limit: 100)

      # Aggregate queries
      Repo.replica().aggregate(Movie, :count)

  """
  @spec replica() :: module()
  def replica do
    Cinegraph.Repo.Replica
  end
end
