import Ecto.Query
alias Cinegraph.Repo

# Check page 2 job
page2_jobs =
  Repo.all(
    from j in Oban.Job,
      where: j.queue == "tmdb_discovery" and j.args["page"] == 2,
      order_by: [desc: j.inserted_at]
  )

IO.puts("Page 2 discovery jobs found: #{length(page2_jobs)}")

Enum.each(page2_jobs, fn job ->
  IO.puts("  State: #{job.state}, Scheduled: #{job.scheduled_at}")

  if job.scheduled_at do
    diff = DateTime.diff(job.scheduled_at, DateTime.utc_now())
    IO.puts("  Scheduled to run in: #{diff} seconds")
  end
end)

# Check all discovery jobs
all_discovery =
  Repo.all(
    from j in Oban.Job,
      where: j.queue == "tmdb_discovery",
      order_by: [desc: j.args["page"]],
      limit: 10
  )

IO.puts("\nAll discovery jobs:")

Enum.each(all_discovery, fn job ->
  IO.puts("  Page: #{job.args["page"]}, State: #{job.state}")
end)
