import Ecto.Query
alias Cinegraph.Repo

# Get the page 1 discovery job details
page1_job = Repo.one(
  from j in Oban.Job,
  where: j.queue == "tmdb_discovery" and j.args["page"] == 1,
  order_by: [desc: j.id],
  limit: 1
)

if page1_job do
  IO.puts("Page 1 job details:")
  IO.puts("  ID: #{page1_job.id}")
  IO.puts("  State: #{page1_job.state}")
  IO.puts("  Completed at: #{page1_job.completed_at}")
  IO.puts("  Errors: #{inspect(page1_job.errors)}")
  
  # Check how many detail jobs were created from page 1
  detail_jobs_count = Repo.aggregate(
    from(j in Oban.Job, 
      where: j.queue == "tmdb_details" and 
             j.inserted_at >= ^page1_job.inserted_at and
             j.inserted_at <= ^NaiveDateTime.add(page1_job.completed_at || page1_job.inserted_at, 10)),
    :count
  )
  
  IO.puts("  Detail jobs created: #{detail_jobs_count}")
else
  IO.puts("No page 1 discovery job found")
end

# Let's manually simulate what should happen after page 1
IO.puts("\nManually queueing page 2...")
# Get the actual total pages from TMDb or ImportState
{:ok, tmdb_total} = Cinegraph.Imports.ImportState.get("tmdb_total_movies")
total_pages = div(String.to_integer(tmdb_total || "0"), 20) # Assuming 20 movies per page
Cinegraph.Imports.TMDbImporter.queue_next_discovery(1, total_pages, "full")

# Check if it was created
Process.sleep(1000)
page2_exists = Repo.exists?(
  from j in Oban.Job,
  where: j.queue == "tmdb_discovery" and j.args["page"] == 2
)

IO.puts("Page 2 job created: #{page2_exists}")
