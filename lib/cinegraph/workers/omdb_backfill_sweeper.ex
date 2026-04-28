defmodule Cinegraph.Workers.OmdbBackfillSweeper do
  @moduledoc """
  Daily sweep that enqueues a capped batch of `OMDbEnrichmentWorker` jobs
  for movies missing OMDb data (#745 Phase 1.1). Canonical-list movies are
  prioritised first.

  Wraps `Cinegraph.Maintenance.BackfillOmdb.run/1`.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Maintenance.BackfillOmdb

  require Logger

  @per_run_limit 5_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case BackfillOmdb.run(limit: @per_run_limit) do
      {:ok, %{found: found, enqueued: enqueued, failed: failed} = stats} ->
        Logger.info(
          "OmdbBackfillSweeper: found=#{found} enqueued=#{enqueued} failed=#{failed} (cap=#{@per_run_limit})"
        )

        {:ok, stats}
    end
  end
end
