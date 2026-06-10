defmodule Cinegraph.Workers.TmdbMovieRefreshSweeper do
  @moduledoc """
  Daily floor sweeper (#1106): enqueues a capped batch of `TMDbMovieRefreshWorker`
  jobs for movies due on `tmdb_details`/`watch_providers` per the freshness ledger.
  This is the capped *floor* — broad/uncapped running + read-through wait for the
  Phase 4 budget governor (#1090 Phase 4).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Maintenance.RefreshTmdbMovies

  require Logger

  @per_run_limit 5_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # `run/1` returns `{:ok, stats}` or raises; a raise lets Oban mark the job
    # failed (max_attempts: 1) rather than us swallowing it into `{:error, _}`.
    {:ok, %{found: found, enqueued: enqueued, failed: failed} = stats} =
      RefreshTmdbMovies.run(limit: @per_run_limit)

    Logger.info(
      "TmdbMovieRefreshSweeper: found=#{found} enqueued=#{enqueued} failed=#{failed} (cap=#{@per_run_limit})"
    )

    {:ok, stats}
  end
end
