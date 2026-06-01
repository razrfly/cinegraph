defmodule Cinegraph.Workers.MaterializedViewRefreshSweeper do
  @moduledoc """
  Daily refresh of all `public` materialized views via the single safe refresh
  path (`Cinegraph.Database.MaterializedViews`): CONCURRENTLY (non-blocking for
  readers) plus a server-side `statement_timeout`.

  Runs with `concurrently_only: true`, so a scheduled job can **never** take an
  `ACCESS EXCLUSIVE` lock — a view without a unique index is skipped (logged) and
  must be rebuilt out-of-band in a maintenance window
  (`Cinegraph.Maintenance.RebuildCollaborationTrends`). This is the firebreak for
  the #1019 incident: no cron path can recreate a long blocking refresh.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1, priority: 3

  alias Cinegraph.Database.MaterializedViews

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    results = MaterializedViews.refresh_all!(concurrently_only: true)

    refreshed = for {name, :ok} <- results, do: name
    skipped = for {name, {:skipped, _reason}} <- results, do: name

    Logger.info(
      "MaterializedViewRefreshSweeper: refreshed=#{length(refreshed)} skipped=#{inspect(skipped)}"
    )

    {:ok, %{refreshed: refreshed, skipped: skipped}}
  end
end
