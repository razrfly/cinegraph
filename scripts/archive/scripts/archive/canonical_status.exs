# Check the status of canonical movie imports
# Run with: mix run canonical_status.exs

alias Cinegraph.Movies
alias Cinegraph.Repo
import Ecto.Query

IO.puts("📊 Canonical Movies Status Report")
IO.puts("=" |> String.duplicate(50))

# Check canonical movies by source
canonical_count = Movies.count_canonical_movies("1001_movies")
IO.puts("\n1001 Movies You Must See Before You Die:")
IO.puts("  • Movies marked: #{canonical_count}")
IO.puts("  • Expected total: 1,260")
IO.puts("  • Progress: #{Float.round(canonical_count / 1260 * 100, 1)}%")

# Check if there are any movies with canonical data
sample_movies =
  from(m in Movies.Movie,
    where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
    limit: 5,
    order_by: fragment("(? -> ? ->> 'list_position')::int", m.canonical_sources, "1001_movies")
  )
  |> Repo.all()

if length(sample_movies) > 0 do
  IO.puts("\n🎬 Sample Canonical Movies:")

  Enum.each(sample_movies, fn movie ->
    position = get_in(movie.canonical_sources, ["1001_movies", "list_position"])
    IO.puts("  • ##{position}: #{movie.title} (#{movie.imdb_id})")
  end)
end

# Check Oban jobs
tmdb_jobs =
  from(j in Oban.Job,
    where:
      j.worker == "Cinegraph.Workers.TMDbDetailsWorker" and
        j.state in ["available", "scheduled", "retryable"]
  )
  |> Repo.aggregate(:count)

IO.puts("\n⚙️  Background Jobs:")
IO.puts("  • TMDb Details Worker jobs pending: #{tmdb_jobs}")

# Recommendations
IO.puts("\n📝 Next Steps:")

if canonical_count < 1260 do
  IO.puts("  1. Run the full import to get all 1,260 movies:")
  IO.puts("     mix run -e 'Cinegraph.Cultural.CanonicalImporter.import_1001_movies()'")
  IO.puts("  2. This will take ~5-10 minutes to fetch all 6 pages")
  IO.puts("  3. Movies not in DB will be queued for creation via TMDb")
else
  IO.puts("  ✅ All 1001 Movies have been imported!")
  IO.puts("  • Ready for CRI backtesting")
end

IO.puts("\n🎯 Other Canonical Sources to Add:")
IO.puts("  • Sight & Sound Greatest Films")
IO.puts("  • AFI's 100 Greatest American Films")
IO.puts("  • Criterion Collection")
IO.puts("  • BFI's 100 Greatest British Films")
IO.puts("  • Find their IMDb list IDs and import similarly")
