defmodule Cinegraph.Workers.ExportBackfillWorker do
  @moduledoc """
  Orchestrates backfilling missing movies from TMDb daily export files.

  This worker bridges the gap between TMDb's 500-page API limit and complete
  movie coverage by using the daily export files which contain ALL movie IDs.

  ## How It Works

  1. Downloads/uses the daily export file (1.1M+ movie IDs)
  2. Compares against our database to find missing IDs
  3. Queues `TMDbDetailsWorker` jobs for missing movies
  4. Prioritizes by popularity (blockbusters first)
  5. Tracks progress via ImportStateV2

  ## Usage

  Via mix task:
      mix tmdb.export backfill                    # Import all missing
      mix tmdb.export backfill --limit 1000       # Import 1000 movies
      mix tmdb.export backfill --min-popularity 10  # Only popularity >= 10
      mix tmdb.export backfill --dry-run          # Preview without importing

  Via Oban:
      ExportBackfillWorker.new(%{
        "limit" => 1000,
        "min_popularity" => 1.0,
        "batch_size" => 100
      }) |> Oban.insert()
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 600]

  alias Cinegraph.Services.TMDb.GapAnalysis
  alias Cinegraph.Workers.TMDbDetailsWorker
  alias Cinegraph.Imports.ImportStateV2
  require Logger

  @default_batch_size 100
  @default_limit nil
  @default_min_popularity nil

  @doc """
  Performs the backfill operation.

  ## Args
    - "limit" - Maximum number of movies to queue (nil = all)
    - "min_popularity" - Minimum popularity threshold (nil = all)
    - "batch_size" - How many jobs to insert per batch (default: 100)
    - "dry_run" - If true, just count and log, don't queue jobs
    - "offset" - Skip first N missing movies (for resuming)
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    limit = Map.get(args, "limit", @default_limit)
    min_popularity = Map.get(args, "min_popularity", @default_min_popularity)
    batch_size = Map.get(args, "batch_size", @default_batch_size)
    dry_run = Map.get(args, "dry_run", false)
    offset = Map.get(args, "offset", 0)

    Logger.info(
      "ExportBackfillWorker starting: limit=#{inspect(limit)}, min_pop=#{inspect(min_popularity)}, dry_run=#{dry_run}"
    )

    case run_backfill(limit, min_popularity, batch_size, dry_run, offset) do
      {:ok, stats} ->
        Logger.info("ExportBackfillWorker complete: #{inspect(stats)}")
        update_progress_state(stats)
        {:ok, stats}

      {:error, reason} ->
        Logger.error("ExportBackfillWorker failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Runs the backfill process.

  Returns {:ok, stats} or {:error, reason}.
  """
  def run_backfill(
        limit \\ nil,
        min_popularity \\ nil,
        batch_size \\ @default_batch_size,
        dry_run \\ false,
        offset \\ 0
      ) do
    Logger.info("Starting backfill process...")

    with {:ok, missing} <- get_missing_movies(min_popularity, limit, offset) do
      total_missing = length(missing)

      if dry_run do
        stats = build_dry_run_stats(missing, min_popularity)
        Logger.info("DRY RUN: Would queue #{total_missing} movies")
        {:ok, stats}
      else
        queued = queue_movies_for_import(missing, batch_size)

        stats = %{
          total_missing: total_missing,
          queued: queued,
          min_popularity: min_popularity,
          limit: limit,
          offset: offset,
          timestamp: DateTime.utc_now()
        }

        {:ok, stats}
      end
    end
  end

  @doc """
  Gets missing movies from the daily export, filtered and sorted by popularity.
  """
  def get_missing_movies(min_popularity \\ nil, limit \\ nil, offset \\ 0) do
    Logger.info(
      "Finding missing movies (min_pop: #{inspect(min_popularity)}, limit: #{inspect(limit)})..."
    )

    opts = [sort_by: :popularity]
    opts = if min_popularity, do: [{:min_popularity, min_popularity} | opts], else: opts
    opts = if limit, do: [{:limit, limit + offset} | opts], else: opts

    case GapAnalysis.find_missing_ids(opts) do
      {:ok, missing} ->
        # Apply offset
        missing = if offset > 0, do: Enum.drop(missing, offset), else: missing
        # Apply limit after offset
        missing = if limit, do: Enum.take(missing, limit), else: missing

        Logger.info("Found #{length(missing)} missing movies to process")
        {:ok, missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Queues movies for import via TMDbDetailsWorker.

  Returns the count of successfully queued jobs.
  """
  def queue_movies_for_import(movies, batch_size \\ @default_batch_size) do
    Logger.info("Queueing #{length(movies)} movies for import in batches of #{batch_size}...")

    movies
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index(1)
    |> Enum.reduce(0, fn {batch, batch_num}, total_queued ->
      Logger.info("Processing batch #{batch_num} (#{length(batch)} movies)...")

      jobs =
        Enum.map(batch, fn movie ->
          TMDbDetailsWorker.new(%{
            "tmdb_id" => movie.id,
            "source" => "daily_export_backfill",
            "popularity" => movie.popularity,
            "original_title" => movie.original_title
          })
        end)

      case Oban.insert_all(jobs) do
        inserted when is_list(inserted) ->
          count = length(inserted)
          Logger.info("Batch #{batch_num}: queued #{count} jobs")
          total_queued + count

        {:error, reason} ->
          Logger.error("Batch #{batch_num} failed: #{inspect(reason)}")
          total_queued
      end
    end)
  end

  @doc """
  Preview what would be imported without actually queueing jobs.
  Useful for testing and validation.
  """
  def preview(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    min_popularity = Keyword.get(opts, :min_popularity)

    case get_missing_movies(min_popularity, limit) do
      {:ok, missing} ->
        stats = build_dry_run_stats(missing, min_popularity)

        IO.puts("\n" <> String.duplicate("=", 60))
        IO.puts("BACKFILL PREVIEW")
        IO.puts(String.duplicate("=", 60))
        IO.puts("\nWould import #{stats.total} movies\n")

        IO.puts("By popularity tier:")

        Enum.each(stats.by_tier, fn {tier, count} ->
          IO.puts("  #{tier}: #{count}")
        end)

        IO.puts("\nSample movies (top #{min(10, length(missing))} by popularity):")

        missing
        |> Enum.take(10)
        |> Enum.each(fn m ->
          IO.puts("  [#{Float.round(m.popularity, 1)}] #{m.original_title} (ID: #{m.id})")
        end)

        {:ok, stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp build_dry_run_stats(movies, min_popularity) do
    by_tier =
      movies
      |> Enum.group_by(fn m ->
        cond do
          m.popularity >= 100 -> "🔥 Blockbuster (100+)"
          m.popularity >= 10 -> "⭐ Popular (10-100)"
          m.popularity >= 1 -> "📽️ Standard (1-10)"
          true -> "📼 Obscure (<1)"
        end
      end)
      |> Enum.map(fn {tier, movies} -> {tier, length(movies)} end)
      |> Enum.sort_by(fn {tier, _} -> tier_order(tier) end)

    %{
      total: length(movies),
      by_tier: by_tier,
      min_popularity: min_popularity,
      dry_run: true,
      timestamp: DateTime.utc_now()
    }
  end

  defp tier_order("🔥 Blockbuster (100+)"), do: 0
  defp tier_order("⭐ Popular (10-100)"), do: 1
  defp tier_order("📽️ Standard (1-10)"), do: 2
  defp tier_order("📼 Obscure (<1)"), do: 3
  defp tier_order(_), do: 99

  defp update_progress_state(stats) do
    ImportStateV2.set("backfill_last_run", DateTime.to_iso8601(stats.timestamp))
    ImportStateV2.set("backfill_last_queued", stats[:queued] || 0)

    # Update cumulative stats
    previous_total = ImportStateV2.get_integer("backfill_total_queued", 0)
    ImportStateV2.set("backfill_total_queued", previous_total + (stats[:queued] || 0))
  end
end
