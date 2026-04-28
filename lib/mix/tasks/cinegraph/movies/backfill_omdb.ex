defmodule Mix.Tasks.Cinegraph.Movies.BackfillOmdb do
  @moduledoc """
  Enqueues `OMDbEnrichmentWorker` jobs for movies missing OMDb data
  (#745 Phase 1.1). Thin wrapper around `Cinegraph.Maintenance.BackfillOmdb`.

  ## Usage

      mix cinegraph.movies.backfill_omdb               # enqueue all
      mix cinegraph.movies.backfill_omdb --dry-run     # count only
      mix cinegraph.movies.backfill_omdb --limit 100
  """
  use Mix.Task

  @shortdoc "Backfill OMDb data for movies missing it"

  alias Cinegraph.Maintenance.BackfillOmdb

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, extra_args, invalid} =
      OptionParser.parse(args, strict: [dry_run: :boolean, limit: :integer])

    cond do
      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      extra_args != [] ->
        Mix.raise("Unexpected positional argument(s): #{inspect(extra_args)}")

      true ->
        :ok
    end

    {:ok, %{found: found, enqueued: enqueued, failed: failed, dry_run: dry_run?}} =
      BackfillOmdb.run(opts)

    Mix.shell().info("Found #{found} movies missing OMDb")

    cond do
      dry_run? -> Mix.shell().info("(dry-run — no jobs enqueued)")
      true -> Mix.shell().info("Enqueued #{enqueued} jobs on queue :omdb")
    end

    if failed > 0 do
      Mix.shell().error("#{failed} job(s) failed to enqueue — see logs above")
    end
  end
end
