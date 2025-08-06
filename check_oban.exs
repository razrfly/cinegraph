# Check Oban job status
IO.puts("Checking Oban jobs...")

# Check all jobs
all_jobs = Oban.Job |> Cinegraph.Repo.all()
IO.puts("Total jobs in database: #{length(all_jobs)}")

# Check by state
states = ["available", "executing", "completed", "cancelled", "discarded", "retryable"]

Enum.each(states, fn state ->
  count =
    Cinegraph.Repo.aggregate(
      Ecto.Query.from(j in Oban.Job, where: j.state == ^state),
      :count
    )

  if count > 0, do: IO.puts("  #{state}: #{count}")
end)

# Check discovery queue specifically
discovery_jobs =
  Cinegraph.Repo.all(
    Ecto.Query.from(j in Oban.Job,
      where: j.queue == "tmdb_discovery",
      order_by: [desc: j.inserted_at],
      limit: 5
    )
  )

IO.puts("\nRecent discovery jobs:")

Enum.each(discovery_jobs, fn job ->
  IO.puts("  ID: #{job.id}, State: #{job.state}, Args: #{inspect(job.args)}")
end)

# Check if Oban is running
IO.puts("\nOban running: #{Oban.started?()}")
