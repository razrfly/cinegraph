import Ecto.Query
alias Cinegraph.Repo

# Check detail queue
detail_jobs = Repo.all(
  from j in Oban.Job,
  where: j.queue == "tmdb_details",
  order_by: [desc: j.inserted_at],
  limit: 10
)

IO.puts("TMDb Details jobs: #{length(detail_jobs)}")
Enum.each(detail_jobs, fn job ->
  IO.puts("  State: #{job.state}, TMDb ID: #{job.args["tmdb_id"]}")
end)

# Check if page 2 was queued
discovery_jobs = Repo.all(
  from j in Oban.Job,
  where: j.queue == "tmdb_discovery" and j.args["page"] == 2
)

IO.puts("\nPage 2 discovery job exists: #{length(discovery_jobs) > 0}")

# Check the last processed page
last_page = try do
  Cinegraph.Imports.ImportState.get("last_page_processed")
rescue
  e -> 
    IO.puts("Error accessing import state: #{inspect(e)}")
    "unknown"
end
IO.puts("\nLast page processed: #{inspect(last_page)}")

# Check total movies in our DB
total = Repo.aggregate(Cinegraph.Movies.Movie, :count)
IO.puts("Total movies in DB: #{total}")
