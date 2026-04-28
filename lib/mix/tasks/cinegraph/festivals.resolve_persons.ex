defmodule Mix.Tasks.Cinegraph.Festivals.ResolvePersons do
  @moduledoc """
  Enqueues `NominationPersonResolver` jobs for nominations missing `person_id`.

  Thin wrapper around `Cinegraph.Maintenance.ResolvePersons` (#739 Phase A) so
  the same code path runs from dev (this Mix task), from Oban Cron (the
  `FestivalPersonResolverSweeper`), and from prod via
  `bin/cinegraph eval "Cinegraph.Maintenance.ResolvePersons.run([])"`.

  ## Usage

      mix cinegraph.festivals.resolve_persons               # enqueue all
      mix cinegraph.festivals.resolve_persons --org AMPAS   # scope to one org
      mix cinegraph.festivals.resolve_persons --dry-run     # count only
      mix cinegraph.festivals.resolve_persons --limit 100   # cap enqueue count
  """
  use Mix.Task

  @shortdoc "Backfill festival nominations missing person_id"

  alias Cinegraph.Maintenance.ResolvePersons

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [org: :string, dry_run: :boolean, limit: :integer]
      )

    {:ok, %{found: found, enqueued: enqueued, failed: failed, dry_run: dry_run?}} =
      ResolvePersons.run(opts)

    Mix.shell().info("Found #{found} nominations to resolve")

    cond do
      dry_run? -> Mix.shell().info("(dry-run — no jobs enqueued)")
      true -> Mix.shell().info("Enqueued #{enqueued} jobs on queue :maintenance")
    end

    if failed > 0 do
      Mix.shell().error("#{failed} job(s) failed to enqueue — see logs above")
    end
  end
end
