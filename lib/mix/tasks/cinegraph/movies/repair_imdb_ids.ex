defmodule Mix.Tasks.Cinegraph.Movies.RepairImdbIds do
  @moduledoc """
  Enqueues `TMDbDetailsWorker` jobs for movies with `imdb_id IS NULL` but
  `tmdb_id IS NOT NULL` (#745 Phase 1.2). Thin wrapper around
  `Cinegraph.Maintenance.RepairImdbIds`.

  ## Usage

      mix cinegraph.movies.repair_imdb_ids
      mix cinegraph.movies.repair_imdb_ids --dry-run
      mix cinegraph.movies.repair_imdb_ids --limit 100
  """
  use Mix.Task

  @shortdoc "Backfill missing imdb_id via TMDb fetches"

  alias Cinegraph.Maintenance.RepairImdbIds

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: [dry_run: :boolean, limit: :integer])

    {:ok, %{found: found, enqueued: enqueued, failed: failed, dry_run: dry_run?}} =
      RepairImdbIds.run(opts)

    Mix.shell().info("Found #{found} movies missing imdb_id")

    cond do
      dry_run? -> Mix.shell().info("(dry-run — no jobs enqueued)")
      true -> Mix.shell().info("Enqueued #{enqueued} jobs on queue :tmdb")
    end

    if failed > 0 do
      Mix.shell().error("#{failed} job(s) failed to enqueue — see logs above")
    end
  end
end
