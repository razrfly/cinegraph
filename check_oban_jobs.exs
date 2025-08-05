import Ecto.Query
alias Cinegraph.Repo

# Check recent Oban jobs
jobs = from(j in Oban.Job,
  where: j.worker == "Cinegraph.Workers.CanonicalImportOrchestrator",
  order_by: [desc: j.inserted_at],
  limit: 5
) |> Repo.all()

IO.puts("\nRecent CanonicalImportOrchestrator jobs:")
Enum.each(jobs, fn job ->
  IO.puts("  ID: #{job.id}, State: #{job.state}, Attempts: #{job.attempt}")
  if job.errors != [] do
    IO.puts("    Error: #{inspect(List.first(job.errors))}")
  end
end)

# Check page worker jobs
page_jobs = from(j in Oban.Job,
  where: j.worker == "Cinegraph.Workers.CanonicalPageWorker",
  order_by: [desc: j.inserted_at],
  limit: 5
) |> Repo.all()

IO.puts("\nRecent CanonicalPageWorker jobs:")
Enum.each(page_jobs, fn job ->
  IO.puts("  ID: #{job.id}, State: #{job.state}, Page: #{job.args["page"]}/#{job.args["total_pages"]}")
end)

# Check current list status
list = Cinegraph.Movies.MovieLists.get_by_source_key("1001_movies")
if list do
  IO.puts("\nCurrent 1001_movies stats:")
  IO.puts("  Last Import: #{list.last_import_at || "Never"}")
  IO.puts("  Movie Count: #{list.last_movie_count}")
  IO.puts("  Status: #{list.last_import_status || "None"}")
  IO.puts("  Total Imports: #{list.total_imports}")
end