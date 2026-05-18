defmodule Cinegraph.Workers.FestivalSyncSweeper do
  @moduledoc """
  Monthly sweep that discovers new festival years and imports any ceremonies
  missing locally (#745 Phase 2). Wraps
  `Cinegraph.Maintenance.SyncFestivals.run/1`.

  Schedule: `0 2 1 * *` UTC (1st of each month). Festival year lists change
  at most annually; daily runs were burning Crawlbase tokens on stable data.
  Use `mix cinegraph.festivals.sync` for an immediate manual run.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Maintenance.SyncFestivals

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case SyncFestivals.run([]) do
      {:ok,
       %{
         events: events,
         discoveries_enqueued: discoveries,
         discoveries_already_queued: disc_already,
         imports_enqueued: imports,
         imports_already_queued: imp_already,
         failed: failed
       } = stats} ->
        Logger.info(
          "FestivalSyncSweeper: events=#{events} discoveries=#{discoveries} " <>
            "disc_already=#{disc_already} imports=#{imports} imp_already=#{imp_already} " <>
            "failed=#{failed}"
        )

        {:ok, stats}
    end
  end
end
