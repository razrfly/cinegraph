# Test script to verify import statistics tracking
# Run with: mix run test_import_stats.exs

require Logger

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("TESTING IMPORT STATISTICS TRACKING")
IO.puts(String.duplicate("=", 60) <> "\n")

# 1. Check current state of movie lists
IO.puts("1. CURRENT MOVIE LISTS STATE")
IO.puts(String.duplicate("-", 40))
lists = Cinegraph.Movies.MovieLists.list_all_movie_lists()
Enum.each(lists, fn list ->
  IO.puts("#{list.source_key}:")
  IO.puts("  Last Import: #{list.last_import_at || "Never"}")
  IO.puts("  Movie Count: #{list.last_movie_count}")
  IO.puts("  Status: #{list.last_import_status || "None"}")
  IO.puts("  Total Imports: #{list.total_imports}")
end)

# 2. Queue a small test import
IO.puts("\n2. QUEUEING TEST IMPORT")
IO.puts(String.duplicate("-", 40))
IO.puts("Queueing import for '1001_movies' list...")

# Queue the import through the orchestrator
job_args = %{
  "action" => "orchestrate_import",
  "list_key" => "1001_movies"
}

case Cinegraph.Workers.CanonicalImportOrchestrator.new(job_args) |> Oban.insert() do
  {:ok, job} ->
    IO.puts("✓ Import job queued successfully (Job ID: #{job.id})")
    IO.puts("\nYou can now:")
    IO.puts("1. Visit http://localhost:4001/import to see progress")
    IO.puts("2. Wait a few minutes for the import to complete")
    IO.puts("3. Run this script again to see updated statistics")
    
  {:error, reason} ->
    IO.puts("✗ Failed to queue import: #{inspect(reason)}")
end

# 3. Show how to check statistics after import
IO.puts("\n3. CHECKING STATISTICS")
IO.puts(String.duplicate("-", 40))
IO.puts("To check if statistics are updating, run:")
IO.puts(~s"""
mix run -e '
  list = Cinegraph.Movies.MovieLists.get_by_source_key("1001_movies")
  IO.puts("Last Import: \#{list.last_import_at}")
  IO.puts("Movie Count: \#{list.last_movie_count}")
  IO.puts("Status: \#{list.last_import_status}")
'
""")

IO.puts("\n✅ Test script complete!")