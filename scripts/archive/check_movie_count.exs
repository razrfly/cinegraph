count = Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count)
IO.puts("Total movies in database: #{count}")

# Check Oban queue status
import Ecto.Query

scheduled =
  Cinegraph.Repo.aggregate(
    from(j in Oban.Job, where: j.state == "scheduled" and j.queue == "tmdb_discovery"),
    :count
  )

IO.puts("Discovery jobs still scheduled: #{scheduled}")
