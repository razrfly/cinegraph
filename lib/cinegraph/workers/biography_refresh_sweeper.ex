defmodule Cinegraph.Workers.BiographyRefreshSweeper do
  @moduledoc """
  Daily sweep that enqueues a capped batch of `PersonTmdbRefreshWorker` jobs
  for canonical-list people whose biography is null or empty. Drains the
  homeostasis backlog autonomously (#735 Phase 3.1).

  Wraps `Cinegraph.Maintenance.RefreshBiographies.run/1`. Caps the per-run
  enqueue count to live within TMDb's daily API budget. New canonical-list
  people introduced by future imports get picked up on the next sweep.

  ## Behavior

  - Runs once per scheduled fire (cron-driven; no self-rescheduling).
  - Caps at `@per_run_limit` jobs per run (TMDb rate-limit safe).
  - Idempotent across runs: `PersonTmdbRefreshWorker` is uniqueness-keyed on
    `:person_id` for 1 hour, so duplicate enqueues collapse.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Maintenance.RefreshBiographies

  require Logger

  @per_run_limit 5_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case RefreshBiographies.run(limit: @per_run_limit) do
      {:ok, %{found: found, enqueued: enqueued, failed: failed} = stats} ->
        Logger.info(
          "BiographyRefreshSweeper: found=#{found} enqueued=#{enqueued} failed=#{failed} (cap=#{@per_run_limit})"
        )

        {:ok, stats}
    end
  end
end
