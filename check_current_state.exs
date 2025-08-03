# Check current import state
progress = Cinegraph.Imports.TMDbImporter.get_progress()
IO.inspect(progress, label: "Current Progress")

# Check active jobs
import Ecto.Query
alias Cinegraph.Repo

active_jobs = Repo.all(
  from j in Oban.Job,
  where: j.state in ["available", "executing", "scheduled"],
  group_by: [j.queue, j.state],
  select: {j.queue, j.state, count(j.id)}
)

IO.puts("\nActive jobs:")
Enum.each(active_jobs, fn {queue, state, count} ->
  IO.puts("  #{queue} - #{state}: #{count}")
end)

# Check highest page
highest_page = Repo.one(
  from j in Oban.Job,
  where: j.queue == "tmdb_discovery",
  order_by: [desc: fragment("(args->>'page')::int")],
  limit: 1,
  select: j.args["page"]
)

IO.puts("\nHighest page queued: #{highest_page}")
