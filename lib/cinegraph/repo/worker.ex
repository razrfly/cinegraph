defmodule Cinegraph.Repo.Worker do
  @moduledoc """
  Dedicated connection pool for background Oban jobs and health-check workers.

  Isolates job DB usage from the `Repo.Replica` pool that serves web requests,
  so a slow or long-running job cannot starve page loads. Configured via the
  `WORKER_POOL_SIZE` env var (default 5).

  Usage: set `:cinegraph_job_repo` in the calling process dictionary (done
  automatically by `Cinegraph.Health.Facade` for health drift tasks) and
  `Repo.replica/0` will route to this module instead of `Repo.Replica`.
  """

  use Ecto.Repo,
    otp_app: :cinegraph,
    adapter: Ecto.Adapters.Postgres
end
