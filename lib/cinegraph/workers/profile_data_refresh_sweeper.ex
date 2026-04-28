defmodule Cinegraph.Workers.ProfileDataRefreshSweeper do
  @moduledoc """
  Daily sweep that enqueues a capped batch of `PersonTmdbRefreshWorker` jobs
  for canonical-list people missing `profile_path` or `known_for_department`
  (#745 Phase 1.3 + 1.6). Complements `BiographyRefreshSweeper`; the 1-hour
  unique constraint on `:person_id` collapses overlapping enqueues.

  Wraps `Cinegraph.Maintenance.RefreshProfileData.run/1`.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Maintenance.RefreshProfileData

  require Logger

  @per_run_limit 3_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case RefreshProfileData.run(limit: @per_run_limit) do
      {:ok, %{found: found, enqueued: enqueued, failed: failed} = stats} ->
        Logger.info(
          "ProfileDataRefreshSweeper: found=#{found} enqueued=#{enqueued} failed=#{failed} (cap=#{@per_run_limit})"
        )

        {:ok, stats}
    end
  end
end
