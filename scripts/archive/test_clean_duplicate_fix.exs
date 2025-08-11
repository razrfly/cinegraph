# Clean test script to verify the duplicate job fix
# Run with: mix run test_clean_duplicate_fix.exs

alias Cinegraph.Imports.TMDbImporter
alias Cinegraph.Repo
import Ecto.Query

IO.puts("\n=== Testing Duplicate Job Fix (Clean) ===\n")

# Clear ALL discovery and detail jobs
deleted_discovery = Repo.delete_all(from j in Oban.Job, where: j.queue == "tmdb_discovery")
deleted_details = Repo.delete_all(from j in Oban.Job, where: j.queue == "tmdb_details")

IO.puts(
  "Cleared #{elem(deleted_discovery, 0)} discovery jobs and #{elem(deleted_details, 0)} detail jobs"
)

# Wait a moment to ensure clean state
:timer.sleep(1000)

# Queue exactly 5 pages for testing
IO.puts("\nQueueing pages 1-5...")
{:ok, count} = TMDbImporter.queue_pages(1, 5)
IO.puts("Successfully queued #{count} jobs")

# Check initial state
IO.puts("\n=== Initial Queue State ===")

initial_jobs =
  Repo.all(
    from j in Oban.Job,
      where: j.queue == "tmdb_discovery" and j.state in ["available", "scheduled"],
      select: {j.args["page"], j.state}
  )

IO.puts("Jobs in queue: #{length(initial_jobs)}")

Enum.each(initial_jobs, fn {page, state} ->
  IO.puts("  Page #{page}: #{state}")
end)

# Wait a bit to let some jobs process (if any are immediate)
IO.puts("\nWaiting 5 seconds for jobs to start processing...")
:timer.sleep(5000)

# Check for duplicates after processing
IO.puts("\n=== Checking for Duplicates After Processing ===")

all_jobs =
  Repo.all(
    from j in Oban.Job,
      where: j.queue == "tmdb_discovery",
      select: {j.args["page"], j.state, j.inserted_at}
  )

# Group by page to find duplicates
pages_grouped = Enum.group_by(all_jobs, fn {page, _, _} -> page end)

# Find pages with multiple jobs
duplicate_pages = Enum.filter(pages_grouped, fn {_page, jobs} -> length(jobs) > 1 end)

if Enum.empty?(duplicate_pages) do
  IO.puts("✅ No duplicate pages found!")
else
  IO.puts("❌ Found duplicate pages:")

  Enum.each(duplicate_pages, fn {page, jobs} ->
    IO.puts("\n  Page #{page}: #{length(jobs)} jobs")

    Enum.each(jobs, fn {_, state, inserted_at} ->
      IO.puts("    - State: #{state}, Inserted: #{inserted_at}")
    end)
  end)
end

# Summary
unique_pages = Map.keys(pages_grouped) |> length()
total_jobs = length(all_jobs)

IO.puts("\n=== Test Summary ===")
IO.puts("Expected pages: 5")
IO.puts("Unique pages found: #{unique_pages}")
IO.puts("Total jobs found: #{total_jobs}")

IO.puts(
  "Test result: #{if unique_pages == 5 and total_jobs == 5, do: "✅ PASSED", else: "❌ FAILED"}"
)

if total_jobs > 5 do
  IO.puts("\n⚠️  More jobs than expected! This indicates duplicates are being created.")
  IO.puts("The queue_next_discovery function may still be active somewhere.")
end
