defmodule Cinegraph.Repo.Replica do
  @moduledoc """
  Read-only replica repository for PlanetScale PostgreSQL.

  This repo connects to PlanetScale read replicas using the `|replica` username suffix.
  All queries through this repo are read-only - any write attempts will fail.

  ## Usage

      # Direct usage
      Cinegraph.Repo.Replica.all(query)

      # Via helper function
      Cinegraph.Repo.replica().all(query)

  ## Configuration

  In production, this repo connects to replicas via the username suffix:
  - Primary: `postgres.xxx`
  - Replica: `postgres.xxx|replica`

  IMPORTANT: PlanetScale requires port 5432 for replica routing.
  PgBouncer (port 6432) does NOT support replica routing.

  In development and test environments, this repo points to the same
  database as the primary repo for simplicity.
  """

  use Ecto.Repo,
    otp_app: :cinegraph,
    adapter: Ecto.Adapters.Postgres,
    read_only: true
end
