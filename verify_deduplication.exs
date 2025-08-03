# Verify deduplication is working correctly
import Ecto.Query
alias Cinegraph.Repo

IO.puts("=== Verifying Deduplication ===\n")

# Check for duplicate TMDb IDs
duplicates = Repo.all(
  from m in Cinegraph.Movies.Movie,
  group_by: m.tmdb_id,
  having: count(m.id) > 1,
  select: {m.tmdb_id, count(m.id)}
)

if length(duplicates) == 0 do
  IO.puts("✅ No duplicate TMDb IDs found - deduplication is working!")
else
  IO.puts("❌ Found #{length(duplicates)} duplicate TMDb IDs:")
  Enum.each(duplicates, fn {tmdb_id, count} ->
    IO.puts("  TMDb ID #{tmdb_id}: #{count} copies")
  end)
end

# Check total unique movies
total_movies = Repo.aggregate(Cinegraph.Movies.Movie, :count)
unique_tmdb_ids = Repo.one(
  from m in Cinegraph.Movies.Movie,
  select: count(m.tmdb_id, :distinct)
)

IO.puts("\nTotal movies: #{total_movies}")
IO.puts("Unique TMDb IDs: #{unique_tmdb_ids}")

if total_movies == unique_tmdb_ids do
  IO.puts("✅ All movies have unique TMDb IDs")
else
  IO.puts("⚠️  Some movies might be missing TMDb IDs")
end

# Check if movie_exists? is being called
# Let's test with a movie we know exists
sample_movie = Repo.one(from m in Cinegraph.Movies.Movie, limit: 1)
if sample_movie do
  exists = Cinegraph.Movies.movie_exists?(sample_movie.tmdb_id)
  IO.puts("\nTesting movie_exists? with TMDb ID #{sample_movie.tmdb_id}: #{exists}")
end