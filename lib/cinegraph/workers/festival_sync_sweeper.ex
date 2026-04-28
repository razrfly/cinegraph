defmodule Cinegraph.Workers.FestivalSyncSweeper do
  @moduledoc """
  Daily sweep that discovers new festival years and imports any ceremonies
  missing locally (#745 Phase 2). Wraps
  `Cinegraph.Maintenance.SyncFestivals.run/1`.

  Schedule: `0 2 * * *` UTC — runs before all other homeostasis sweepers
  so new nominations land before the daily person-resolver pass at 06:00 UTC.
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
