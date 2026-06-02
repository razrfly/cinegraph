defmodule Mix.Tasks.Cinegraph.Movies.FixTmdbPopularityCollision do
  @moduledoc """
  Repairs the tmdb/popularity_score collision (#1036) from existing `tmdb_data` JSON
  (no API calls). Thin wrapper around `Cinegraph.Maintenance.FixTmdbPopularityCollision`.

  ## Usage

      mix cinegraph.movies.fix_tmdb_popularity_collision            # run
      mix cinegraph.movies.fix_tmdb_popularity_collision --dry-run  # count only
      mix cinegraph.movies.fix_tmdb_popularity_collision --limit 1000
  """
  use Mix.Task

  @shortdoc "Restore real TMDb popularity + split list_appearances (no API calls)"

  alias Cinegraph.Maintenance.FixTmdbPopularityCollision

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, extra, invalid} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean, batch_size: :integer, limit: :integer],
        aliases: [n: :dry_run]
      )

    cond do
      invalid != [] -> Mix.raise("Invalid option(s): #{inspect(invalid)}")
      extra != [] -> Mix.raise("Unexpected argument(s): #{inspect(extra)}")
      opts[:batch_size] && opts[:batch_size] <= 0 -> Mix.raise("--batch-size must be positive")
      true -> :ok
    end

    {:ok, %{found: found, processed: processed, failed: failed, dry_run: dry_run?}} =
      FixTmdbPopularityCollision.run(opts)

    Mix.shell().info("Found #{found} movies with a corrupted popularity_score row")

    if dry_run?,
      do: Mix.shell().info("(dry-run — no rows written)"),
      else: Mix.shell().info("Repaired #{processed} movies")

    if failed > 0, do: Mix.shell().error("#{failed} movie(s) failed — see logs")
  end
end
