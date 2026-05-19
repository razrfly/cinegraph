defmodule Cinegraph.Workers.FestivalPersonResolverSweeper do
  @moduledoc """
  Daily sweep that enqueues a capped batch of `NominationPersonResolver` jobs
  for festival nominations still missing `person_id`. Drains the homeostasis
  backlog autonomously (#735 Phase 3.1).

  Wraps `Cinegraph.Maintenance.ResolvePersons.run/1`. Caps the per-run enqueue
  count to avoid bursting the `:maintenance` queue all at once. New nominations
  introduced by future imports get picked up on the next sweep.

  ## Behavior

  - Runs once per scheduled fire (cron-driven; no self-rescheduling).
  - Caps at `@per_run_limit` jobs per run.
  - Idempotent across runs: `NominationPersonResolver` is uniqueness-keyed on
    `:nomination_id` for 1 hour, so duplicate enqueues collapse.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Maintenance.ResolvePersons

  require Logger

  @per_run_limit 5_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case ResolvePersons.run(limit: @per_run_limit) do
      {:ok, %{found: found, enqueued: enqueued, failed: failed} = stats} ->
        Logger.info(
          "FestivalPersonResolverSweeper: found=#{found} enqueued=#{enqueued} failed=#{failed} (cap=#{@per_run_limit})"
        )

        {:ok, stats}
    end
  end
end
