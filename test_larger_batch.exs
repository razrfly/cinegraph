# Test with a larger batch to ensure no duplicates at scale
# Run with: mix run test_larger_batch.exs

alias Cinegraph.Imports.TMDbImporter
alias Cinegraph.Repo
import Ecto.Query

IO.puts("\n=== Testing Larger Batch (20 pages) ===\n")

# Clear all discovery jobs
Repo.delete_all(from j in Oban.Job, where: j.queue == "tmdb_discovery")

# Queue 20 pages
IO.puts("Queueing pages 100-119...")
{:ok, count} = TMDbImporter.queue_pages(100, 119)
IO.puts("Queued #{count} jobs")

# Check immediate state
jobs = Repo.all(
  from j in Oban.Job,
  where: j.queue == "tmdb_discovery",
  select: j.args["page"]
)

pages = Enum.sort(jobs)
unique_pages = Enum.uniq(jobs) |> length()

IO.puts("\nTotal jobs: #{length(jobs)}")
IO.puts("Unique pages: #{unique_pages}")
IO.puts("Expected: 20")

if length(jobs) == 20 and unique_pages == 20 do
  IO.puts("\n✅ Test PASSED - No duplicates!")
else
  IO.puts("\n❌ Test FAILED - Found duplicates!")
  duplicates = jobs -- Enum.uniq(jobs)
  IO.puts("Duplicate pages: #{inspect(duplicates)}")
end

# Show scheduling distribution
IO.puts("\n=== Job Scheduling ===")
job_details = Repo.all(
  from j in Oban.Job,
  where: j.queue == "tmdb_discovery",
  select: {j.args["page"], j.scheduled_at},
  order_by: j.scheduled_at
)

Enum.each(job_details, fn {page, scheduled_at} ->
  IO.puts("Page #{page}: #{scheduled_at}")
end)