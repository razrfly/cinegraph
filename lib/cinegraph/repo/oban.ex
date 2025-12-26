defmodule Cinegraph.Repo.Oban do
  @moduledoc """
  Dedicated Ecto repository for Oban background jobs.

  This repo uses a DIRECT connection to PlanetScale (port 5432) instead of
  PgBouncer (port 6432). This is required because:

  1. Oban uses long-running transactions for job locking
  2. PgBouncer's transaction pooling mode terminates connections that exceed its timeout
  3. Complex scoring queries can take 2+ minutes to complete

  In development, this uses the same connection as the primary Repo.
  In production, this bypasses PgBouncer for reliable long-running job execution.
  """

  use Ecto.Repo,
    otp_app: :cinegraph,
    adapter: Ecto.Adapters.Postgres
end
