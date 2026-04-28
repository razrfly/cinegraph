defmodule Cinegraph.Workers.ImdbIdRepairSweeper do
  @moduledoc """
  Daily sweep that enqueues a capped batch of `TMDbDetailsWorker` jobs for
  movies missing `imdb_id` (#745 Phase 1.2). TMDb returns IMDb id on most
  fetches, so this drains fast.

  Wraps `Cinegraph.Maintenance.RepairImdbIds.run/1`.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Maintenance.RepairImdbIds

  require Logger

  @per_run_limit 5_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case RepairImdbIds.run(limit: @per_run_limit) do
      {:ok, %{found: found, enqueued: enqueued, failed: failed} = stats} ->
        Logger.info(
          "ImdbIdRepairSweeper: found=#{found} enqueued=#{enqueued} failed=#{failed} (cap=#{@per_run_limit})"
        )

        {:ok, stats}
    end
  end
end
