defmodule Cinegraph.Workers.ZeroCreditsCleanupSweeper do
  @moduledoc """
  Weekly sweep (Sun) that enqueues `TMDbDetailsWorker` refetches for orphan
  people (#745 Phase 1.5 — phase 1 of 2). The companion
  `ZeroCreditsCleanupDeleteSweeper` runs 24h later (Mon) to hard-delete
  rows that *remained* orphaned after the refetch.

  Wraps `Cinegraph.Maintenance.CleanupZeroCredits.enqueue_refetch/1`.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Maintenance.CleanupZeroCredits

  require Logger

  @per_run_limit 200

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case CleanupZeroCredits.enqueue_refetch(limit: @per_run_limit) do
      {:ok, %{found: found, enqueued: enqueued, failed: failed} = stats} ->
        Logger.info(
          "ZeroCreditsCleanupSweeper: found=#{found} enqueued=#{enqueued} failed=#{failed} (cap=#{@per_run_limit})"
        )

        {:ok, stats}
    end
  end
end
