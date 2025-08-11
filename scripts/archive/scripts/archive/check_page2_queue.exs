import Ecto.Query
alias Cinegraph.Repo

# Check discovery jobs
discovery_jobs =
  Repo.all(
    from j in Oban.Job,
      where: j.queue == "tmdb_discovery",
      order_by: [asc: j.args["page"]],
      select: {j.args["page"], j.state, j.scheduled_at}
  )

IO.puts("Discovery jobs:")

Enum.each(discovery_jobs, fn {page, state, scheduled} ->
  if scheduled && DateTime.compare(scheduled, DateTime.utc_now()) == :gt do
    diff = DateTime.diff(scheduled, DateTime.utc_now())
    IO.puts("  Page #{page}: #{state} (scheduled in #{diff}s)")
  else
    IO.puts("  Page #{page}: #{state}")
  end
end)

# Check the delay calculation
IO.puts("\nDelay calculation for page 2:")
# From the code: base_delay = min(page_number * 10, 300)
base_delay = min(2 * 10, 300)
IO.puts("  Base delay: #{base_delay}s")
IO.puts("  Plus random jitter: 0-30s")
IO.puts("  Total delay: #{base_delay}-#{base_delay + 30}s")
