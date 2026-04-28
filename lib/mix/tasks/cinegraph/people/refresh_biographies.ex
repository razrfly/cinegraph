defmodule Mix.Tasks.Cinegraph.People.RefreshBiographies do
  @moduledoc """
  Enqueues `PersonTmdbRefreshWorker` jobs for canonical-list people whose
  biography is null or empty.

  Thin wrapper around `Cinegraph.Maintenance.RefreshBiographies` (#739 Phase A)
  so the same code path runs from dev, from Oban Cron (the
  `BiographyRefreshSweeper`), and from prod via
  `bin/cinegraph eval "Cinegraph.Maintenance.RefreshBiographies.run([])"`.

  ## Usage

      mix cinegraph.people.refresh_biographies               # enqueue all
      mix cinegraph.people.refresh_biographies --dry-run     # count only
      mix cinegraph.people.refresh_biographies --limit 100   # cap enqueue count
  """
  use Mix.Task

  @shortdoc "Backfill biographies for canonical-list people"

  alias Cinegraph.Maintenance.RefreshBiographies

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args, strict: [dry_run: :boolean, limit: :integer])

    {:ok, %{found: found, enqueued: enqueued, failed: failed, dry_run: dry_run?}} =
      RefreshBiographies.run(opts)

    Mix.shell().info("Found #{found} people to refresh")

    cond do
      dry_run? -> Mix.shell().info("(dry-run — no jobs enqueued)")
      true -> Mix.shell().info("Enqueued #{enqueued} jobs on queue :tmdb")
    end

    if failed > 0 do
      Mix.shell().error("#{failed} job(s) failed to enqueue — see logs above")
    end
  end
end
