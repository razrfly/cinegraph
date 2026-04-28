defmodule Cinegraph.Workers.ZeroCreditsCleanupDeleteSweeper do
  @moduledoc """
  Weekly sweep (Mon, 24h after the enqueue sweeper) that hard-deletes
  people who *remained* orphaned after the prior Sunday's TMDb refetch
  (#745 Phase 1.5 — phase 2 of 2). Only deletes rows whose `tmdb_id` is
  set, so the import is reproducible.

  Wraps `Cinegraph.Maintenance.CleanupZeroCredits.delete_still_orphaned/1`.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Maintenance.CleanupZeroCredits

  require Logger

  @per_run_limit 200

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case CleanupZeroCredits.delete_still_orphaned(limit: @per_run_limit) do
      {:ok, %{found: found, deleted: deleted, failed: failed} = stats} ->
        Logger.info(
          "ZeroCreditsCleanupDeleteSweeper: found=#{found} deleted=#{deleted} failed=#{failed} (cap=#{@per_run_limit})"
        )

        {:ok, stats}
    end
  end
end
