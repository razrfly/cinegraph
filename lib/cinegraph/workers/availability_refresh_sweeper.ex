defmodule Cinegraph.Workers.AvailabilityRefreshSweeper do
  @moduledoc """
  Daily sweeper that enqueues capped movie availability refresh jobs.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Maintenance.RefreshAvailability

  require Logger

  # Bumped 5k → 30k (#1106): full-catalog drain ~76 days → ~25 days. TMDb isn't the
  # limiter; pair this with OBAN_MOVIE_AVAILABILITY_LIMIT=5 (concurrency of the
  # :movie_availability queue in runtime.exs, was 1 — separate from :maintenance:1)
  # on deploy. NOTE: each fetch writes ~139 region rows — at 30k/day that's ~4M
  # row-writes/day on the shared box. To go faster *safely*, narrow the region set
  # (see #1106 Part A — the real unlock; gets it to ~15 days at far lower DB load).
  @per_run_limit 30_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case RefreshAvailability.run(limit: @per_run_limit) do
      {:ok, %{found: found, enqueued: enqueued, failed: failed} = stats} ->
        Logger.info(
          "AvailabilityRefreshSweeper: found=#{found} enqueued=#{enqueued} failed=#{failed} (cap=#{@per_run_limit})"
        )

        {:ok, stats}

      {:error, reason} ->
        Logger.error("AvailabilityRefreshSweeper failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
