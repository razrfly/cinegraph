defmodule Cinegraph.Workers.CollaborationRepairSweeper do
  @moduledoc """
  Daily capped sweeper that enqueues collaboration rebuilds for full movies
  with normalized credits but no collaboration details.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Maintenance.Collaborations

  require Logger

  @per_run_limit 5_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Collaborations.backfill(limit: @per_run_limit) do
      {:ok, %{found: found, enqueued: enqueued, failed: failed, stats: stats} = result} ->
        Logger.info(
          "CollaborationRepairSweeper: found=#{found} enqueued=#{enqueued} failed=#{failed} coverage=#{stats.coverage_pct}% missing=#{stats.missing_collaboration_details}"
        )

        {:ok, Map.drop(result, [:movie_ids])}

      {:error, reason} ->
        Logger.error("CollaborationRepairSweeper failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
