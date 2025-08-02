# Test script to verify TMDB import with rate limiting
# Run with: mix run test_import.exs

require Logger

# Test 1: Verify rate limiter is working
Logger.info("Testing rate limiter...")
{time, results} = :timer.tc(fn ->
  Enum.map(1..50, fn i ->
    start = System.monotonic_time(:millisecond)
    Cinegraph.RateLimiter.wait_for_token(:tmdb)
    elapsed = System.monotonic_time(:millisecond) - start
    {i, elapsed}
  end)
end)

Logger.info("Rate limiter test completed in #{time / 1_000_000}s")
Logger.info("First 10 requests should be fast, then throttled")
Enum.slice(results, 0..10) |> Enum.each(fn {i, elapsed} ->
  Logger.info("Request #{i}: #{elapsed}ms")
end)

# Test 2: Import a small batch of popular movies
Logger.info("\nStarting test import of 10 popular movies...")

# First, let's check if we have TMDB API key
case System.get_env("TMDB_API_KEY") do
  nil ->
    Logger.error("TMDB_API_KEY not set!")
    Logger.error("")
    Logger.error("Please ensure you're running this script with environment variables loaded:")
    Logger.error("  1. Make sure .env file exists with TMDB_API_KEY=your-key")
    Logger.error("  2. Run this script using: ./scripts/run_with_env.sh mix run test_import.exs")
    Logger.error("  OR manually: source .env && mix run test_import.exs")
    System.halt(1)
    
  api_key ->
    Logger.info("TMDB API key found: #{String.slice(api_key, 0..5)}...")
end

# Start a small popular movies import with only 1 page
{:ok, progress} = Cinegraph.Imports.TMDbImporter.start_popular_import(max_pages: 1)
Logger.info("Started import with progress ID: #{progress.id}")

# Wait a bit for jobs to process
Logger.info("Waiting 30 seconds for jobs to process...")
Process.sleep(30_000)

# Check import status
statuses = Cinegraph.Imports.TMDbImporter.get_import_status()
Enum.each(statuses, fn status ->
  Logger.info("""
  Import Status:
    Type: #{status.type}
    Status: #{status.status}
    Movies Found: #{status.movies_found}
    Movies Imported: #{status.movies_imported}
    Failed: #{status.movies_failed}
    Rate: #{status.rate} movies/min
  """)
end)

# Check Oban queue status
queue_counts = Oban.drain_queue(queue: :all, with_limit: 0)
Logger.info("Oban queue counts: #{inspect(queue_counts)}")

# Check database stats
import Ecto.Query
alias Cinegraph.Repo
alias Cinegraph.Movies.Movie

movie_count = Repo.aggregate(Movie, :count)
tmdb_count = Repo.aggregate(from(m in Movie, where: not is_nil(m.tmdb_data)), :count)

Logger.info("""
Database Stats:
  Total Movies: #{movie_count}
  With TMDB Data: #{tmdb_count}
""")

Logger.info("\nTest import complete!")
Logger.info("Check the import dashboard at http://localhost:4000/imports")