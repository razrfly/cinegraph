defmodule Mix.Tasks.Cinegraph.Movies.BackfillAvailability do
  use Mix.Task

  @shortdoc "Backfill movie watch availability from stored TMDb JSON"

  @moduledoc """
  Backfills normalized movie watch availability from existing `movies.tmdb_data`.

      mix cinegraph.movies.backfill_availability --dry-run
      mix cinegraph.movies.backfill_availability --limit 100
      mix cinegraph.movies.backfill_availability --after-id 500000 --batch-size 1000
      mix cinegraph.movies.backfill_availability --regions US,CA

  This task does not call TMDb. It only normalizes watch-provider JSON already
  stored in `movies.tmdb_data["watch_providers"]`.
  """

  alias Cinegraph.Movies.AvailabilityBackfill

  @impl Mix.Task
  def run(args) do
    {opts, _extra, invalid} =
      OptionParser.parse(args,
        strict: [
          limit: :integer,
          batch_size: :integer,
          after_id: :integer,
          regions: :string,
          dry_run: :boolean
        ]
      )

    if invalid != [] do
      Mix.shell().error("Unknown options: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
      Mix.raise("Invalid options provided")
    end

    Mix.Task.run("app.start")

    case AvailabilityBackfill.run(
           limit: opts[:limit],
           batch_size: opts[:batch_size] || 500,
           after_id: opts[:after_id] || 0,
           regions: opts[:regions] || Cinegraph.Movies.Availability.configured_regions(),
           dry_run: opts[:dry_run] || false
         ) do
      {:ok, stats} ->
        print_stats(stats)

      {:error, reason} ->
        Mix.raise("Availability backfill failed: #{inspect(reason)}")
    end
  end

  defp print_stats(stats) do
    Mix.shell().info("Availability backfill complete")
    Mix.shell().info("  dry_run:    #{stats.dry_run}")
    Mix.shell().info("  processed:  #{stats.processed}")
    Mix.shell().info("  success:    #{stats.success}")
    Mix.shell().info("  no_results: #{stats.no_results}")
    Mix.shell().info("  error:      #{stats.error}")
    Mix.shell().info("  skipped:    #{stats.skipped}")
    Mix.shell().info("  last_id:    #{inspect(stats.last_id)}")
  end
end
