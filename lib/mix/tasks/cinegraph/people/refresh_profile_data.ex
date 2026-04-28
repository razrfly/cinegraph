defmodule Mix.Tasks.Cinegraph.People.RefreshProfileData do
  @moduledoc """
  Enqueues `PersonTmdbRefreshWorker` jobs for canonical-list people missing
  `profile_path` or `known_for_department` (#745 Phase 1.3 + 1.6). Thin
  wrapper around `Cinegraph.Maintenance.RefreshProfileData`.

  ## Usage

      mix cinegraph.people.refresh_profile_data
      mix cinegraph.people.refresh_profile_data --dry-run
      mix cinegraph.people.refresh_profile_data --limit 100
  """
  use Mix.Task

  @shortdoc "Backfill profile_path + known_for_department for canonical-list people"

  alias Cinegraph.Maintenance.RefreshProfileData

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: [dry_run: :boolean, limit: :integer])

    {:ok, %{found: found, enqueued: enqueued, failed: failed, dry_run: dry_run?}} =
      RefreshProfileData.run(opts)

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
