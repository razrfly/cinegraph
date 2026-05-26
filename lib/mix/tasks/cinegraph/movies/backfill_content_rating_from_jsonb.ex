defmodule Mix.Tasks.Cinegraph.Movies.BackfillContentRatingFromJsonb do
  @moduledoc """
  Re-extracts OMDb content_rating metrics from existing `omdb_data` JSONB
  without API calls. Thin wrapper around
  `Cinegraph.Maintenance.BackfillContentRatingFromJsonb`.

  See #989 Action 1.

  ## Usage

      mix cinegraph.movies.backfill_content_rating_from_jsonb            # run backfill
      mix cinegraph.movies.backfill_content_rating_from_jsonb --dry-run  # count only
      mix cinegraph.movies.backfill_content_rating_from_jsonb --batch-size 200
  """
  use Mix.Task

  @shortdoc "Backfill content_rating from existing omdb_data JSON (no API calls)"

  alias Cinegraph.Maintenance.BackfillContentRatingFromJsonb

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, extra_args, invalid} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean, batch_size: :integer],
        aliases: [n: :dry_run]
      )

    cond do
      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      extra_args != [] ->
        Mix.raise("Unexpected positional argument(s): #{inspect(extra_args)}")

      opts[:batch_size] && opts[:batch_size] <= 0 ->
        Mix.raise("Invalid value for --batch-size: must be a positive integer")

      true ->
        :ok
    end

    {:ok, %{found: found, processed: processed, failed: failed, dry_run: dry_run?}} =
      BackfillContentRatingFromJsonb.run(opts)

    Mix.shell().info("Found #{found} movies with omdb_data but no content_rating metric")

    cond do
      dry_run? ->
        Mix.shell().info("(dry-run — no rows written)")

      true ->
        Mix.shell().info("Processed #{processed} movies")
    end

    if failed > 0 do
      Mix.shell().error("#{failed} movie(s) failed — see logs above")
    end
  end
end
