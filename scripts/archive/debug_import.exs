# Debug the import process
# Run with: mix run debug_import.exs

alias Cinegraph.Cultural.CanonicalImporter
alias Cinegraph.Movies
alias Cinegraph.Repo
import Ecto.Query

Logger.configure(level: :debug)

IO.puts("🔍 Debugging Canonical Import Process")
IO.puts("=" |> String.duplicate(50))

# Check initial state
initial_count = Movies.count_canonical_movies("1001_movies")
initial_total = Repo.aggregate(Movies.Movie, :count)
IO.puts("\n📊 Initial State:")
IO.puts("  • 1001 Movies marked: #{initial_count}")
IO.puts("  • Total movies in DB: #{initial_total}")

# Check for movies that exist but aren't marked
sample_imdb_ids = ["tt0000417", "tt0000439", "tt0004972", "tt0006206", "tt0006864"]
existing_movies = Repo.all(from m in Movies.Movie, where: m.imdb_id in ^sample_imdb_ids)
IO.puts("\n🎬 Checking first 5 IMDb IDs:")

Enum.each(sample_imdb_ids, fn imdb_id ->
  movie = Enum.find(existing_movies, &(&1.imdb_id == imdb_id))

  if movie do
    is_canonical = Movies.Movie.is_canonical?(movie, "1001_movies")
    IO.puts("  • #{imdb_id}: ✅ Exists (#{movie.title}) - Canonical: #{is_canonical}")
  else
    IO.puts("  • #{imdb_id}: ❌ Not in DB")
  end
end)

# Run import for just first page to see what happens
IO.puts("\n📋 Running import (first page only)...")

# Let's trace the actual process
result = CanonicalImporter.import_1001_movies()

IO.puts("\n📊 Import Result:")
IO.inspect(result, pretty: true, limit: :infinity)

# Check final state
final_count = Movies.count_canonical_movies("1001_movies")
final_total = Repo.aggregate(Movies.Movie, :count)

IO.puts("\n📈 Final State:")

IO.puts(
  "  • 1001 Movies marked: #{final_count} (#{if final_count > initial_count, do: "+#{final_count - initial_count}", else: "no change"})"
)

IO.puts(
  "  • Total movies in DB: #{final_total} (#{if final_total > initial_total, do: "+#{final_total - initial_total}", else: "no change"})"
)

# Check Oban jobs
oban_jobs =
  from(j in Oban.Job,
    where: j.worker == "Cinegraph.Workers.TMDbDetailsWorker",
    order_by: [desc: j.inserted_at],
    limit: 5
  )
  |> Repo.all()

IO.puts("\n⚙️ Recent Oban Jobs:")

if length(oban_jobs) == 0 do
  IO.puts("  • No TMDbDetailsWorker jobs found")
else
  Enum.each(oban_jobs, fn job ->
    IO.puts("  • Job #{job.id}: #{job.state} - #{inspect(job.args)}")
  end)
end
