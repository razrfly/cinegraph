defmodule Cinegraph.Workers.AvailabilityRefreshSweeper do
  @moduledoc """
  Daily sweeper that enqueues capped movie availability refresh jobs.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Maintenance.RefreshAvailability

  require Logger

  @per_run_limit 5_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case RefreshAvailability.run(limit: @per_run_limit) do
      {:ok, %{found: found, enqueued: enqueued, failed: failed} = stats} ->
        Logger.info(
          "AvailabilityRefreshSweeper: found=#{found} enqueued=#{enqueued} failed=#{failed} (cap=#{@per_run_limit})"
        )

        {:ok, stats}
    end
  end
end
