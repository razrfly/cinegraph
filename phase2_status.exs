IO.puts("=== Phase 2: Systematic Import Testing ===\n")

# Check current progress
progress = Cinegraph.Imports.TMDbImporter.get_progress()
IO.puts("Current Status:")
IO.puts("  Total movies in DB: #{progress.our_total_movies || 0}")
IO.puts("  Last page processed: #{progress.last_page_processed || "0"}")
IO.puts("  TMDB total: #{progress.tmdb_total_movies || "Unknown"}")
IO.puts("  Completion: #{progress.completion_percentage || 0}%")

# Check Oban status
import Ecto.Query
alias Cinegraph.Repo

job_stats = Repo.all(
  from j in Oban.Job,
  group_by: [j.queue, j.state],
  select: {j.queue, j.state, count(j.id)}
)

IO.puts("\nOban Queue Status:")
Enum.each(job_stats, fn {queue, state, count} ->
  IO.puts("  #{queue} - #{state}: #{count}")
end)

# Calculate target pages for 10,000 movies
target_movies = 10_000
movies_per_page = 20
target_pages = div(target_movies, movies_per_page)
IO.puts("\nTarget for Phase 2:")
IO.puts("  Goal: #{target_movies} movies")
IO.puts("  Pages needed: ~#{target_pages}")
IO.puts("  Estimated time: ~#{div(target_pages * 40, 3600)} hours")

# Check if import is already running
running_discovery = Repo.exists?(
  from j in Oban.Job,
  where: j.queue == "tmdb_discovery" and j.state in ["scheduled", "available", "executing"]
)

IO.puts("\nImport currently running: #{running_discovery}")

if progress.our_total_movies < 100 and not running_discovery do
  IO.puts("\nReady to start Phase 2 import!")
  IO.puts("Run: Cinegraph.Imports.TMDbImporter.start_full_import()")
end
