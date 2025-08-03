import Ecto.Query
alias Cinegraph.Repo

IO.puts("Waiting 30 seconds for page 2 to be processed...")
Process.sleep(30000)

# Check discovery jobs again
discovery_jobs = Repo.all(
  from j in Oban.Job,
  where: j.queue == "tmdb_discovery",
  order_by: [asc: j.args["page"]],
  select: {j.args["page"], j.state}
)

IO.puts("\nDiscovery jobs after waiting:")
Enum.each(discovery_jobs, fn {page, state} ->
  IO.puts("  Page #{page}: #{state}")
end)

# Check progress
progress = Cinegraph.Imports.TMDbImporter.get_progress()
IO.puts("\nProgress update:")
IO.puts("  Movies: #{progress.our_total_movies}")
IO.puts("  Last page: #{progress.last_page_processed}")
IO.puts("  Completion: #{progress.completion_percentage}%")

# Check if there are scheduled jobs
scheduled = Repo.aggregate(
  from(j in Oban.Job, where: j.state == "scheduled"),
  :count
)
IO.puts("\nScheduled jobs: #{scheduled}")
