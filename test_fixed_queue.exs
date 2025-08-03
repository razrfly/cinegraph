# Test the fixed queue_next_discovery function
IO.puts("Testing fixed queue_next_discovery...")

result = Cinegraph.Imports.TMDbImporter.queue_next_discovery(1, 51749, "full")
IO.inspect(result, label: "Queue result")

# Wait a moment and check if page 2 exists
Process.sleep(1000)

import Ecto.Query
alias Cinegraph.Repo

page2_job = Repo.one(
  from j in Oban.Job,
  where: j.queue == "tmdb_discovery" and j.args["page"] == 2,
  order_by: [desc: j.id],
  limit: 1
)

if page2_job do
  IO.puts("\nPage 2 job created successfully\!")
  IO.puts("  State: #{page2_job.state}")
  IO.puts("  Scheduled at: #{page2_job.scheduled_at}")
  
  if page2_job.scheduled_at do
    diff = DateTime.diff(page2_job.scheduled_at, DateTime.utc_now())
    IO.puts("  Will run in: #{diff} seconds")
  end
else
  IO.puts("\nPage 2 job was not created")
end
