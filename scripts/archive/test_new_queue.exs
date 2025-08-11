# Test the new batch queueing
IO.puts("Testing new batch queue approach...\n")

# Let's queue pages 6-20 as a test (15 pages)
{:ok, count} = Cinegraph.Imports.TMDbImporter.queue_pages(6, 20, "test")
IO.puts("Queued #{count} discovery jobs")

# Check the queue
import Ecto.Query
alias Cinegraph.Repo

scheduled_jobs =
  Repo.all(
    from j in Oban.Job,
      where: j.queue == "tmdb_discovery" and j.state == "scheduled",
      order_by: [asc: j.scheduled_at],
      limit: 20,
      select: %{
        page: j.args["page"],
        scheduled_at: j.scheduled_at
      }
  )

IO.puts("\nScheduled discovery jobs:")

Enum.each(scheduled_jobs, fn job ->
  diff = DateTime.diff(job.scheduled_at, DateTime.utc_now())
  IO.puts("  Page #{job.page}: scheduled in #{diff} seconds")
end)

total_scheduled =
  Repo.aggregate(
    from(j in Oban.Job, where: j.state == "scheduled"),
    :count
  )

IO.puts("\nTotal scheduled jobs: #{total_scheduled}")
