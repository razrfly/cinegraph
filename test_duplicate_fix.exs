# Test script to verify the duplicate job fix
# Run with: mix run test_duplicate_fix.exs

alias Cinegraph.Imports.TMDbImporter
alias Cinegraph.Repo
import Ecto.Query

IO.puts("\n=== Testing Duplicate Job Fix ===\n")

# Clear any existing discovery jobs
deleted = Repo.delete_all(
  from j in Oban.Job, 
  where: j.queue == "tmdb_discovery" and j.state in ["available", "scheduled"]
)
IO.puts("Cleared #{elem(deleted, 0)} existing discovery jobs")

# Queue 10 pages for testing
IO.puts("\nQueueing pages 1-10...")
{:ok, count} = TMDbImporter.queue_pages(1, 10)
IO.puts("Successfully queued #{count} jobs")

# Check for duplicates
IO.puts("\nChecking for duplicate pages...")
jobs = Repo.all(
  from j in Oban.Job,
  where: j.queue == "tmdb_discovery",
  select: {j.args, j.scheduled_at, j.state}
)

# Group by page number
pages = Enum.group_by(jobs, fn {args, _, _} -> args["page"] end)

# Find duplicates
duplicates = Enum.filter(pages, fn {_page, jobs} -> length(jobs) > 1 end)

if Enum.empty?(duplicates) do
  IO.puts("✅ No duplicate pages found!")
else
  IO.puts("❌ Found duplicate pages:")
  Enum.each(duplicates, fn {page, jobs} ->
    IO.puts("  Page #{page}: #{length(jobs)} jobs")
    Enum.each(jobs, fn {_, scheduled_at, state} ->
      IO.puts("    - Scheduled: #{scheduled_at}, State: #{state}")
    end)
  end)
end

# Show job distribution
IO.puts("\n=== Job Distribution ===")
Enum.each(1..10, fn page ->
  case Map.get(pages, page) do
    nil -> IO.puts("Page #{page}: No job found ❌")
    jobs -> IO.puts("Page #{page}: #{length(jobs)} job(s)")
  end
end)

IO.puts("\n=== Summary ===")
IO.puts("Total jobs created: #{length(jobs)}")
IO.puts("Expected jobs: 10")
IO.puts("Test result: #{if length(jobs) == 10 and Enum.empty?(duplicates), do: "✅ PASSED", else: "❌ FAILED"}")