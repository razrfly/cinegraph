# Check import status
import Ecto.Query

movies_count = Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count)
IO.puts("Total movies in database: #{movies_count}")

# Check if we have OMDb data
omdb_count = Cinegraph.Repo.one(
  from m in Cinegraph.Movies.Movie,
  where: not is_nil(m.imdb_id),
  select: count(m.id)
)
IO.puts("Movies with IMDb IDs: #{omdb_count}")

# Check external ratings
ratings_count = Cinegraph.Repo.aggregate(Cinegraph.ExternalSources.Rating, :count)
IO.puts("Total external ratings: #{ratings_count}")

# Sample movie with details
if movies_count > 0 do
  movie = Cinegraph.Repo.one(
    from m in Cinegraph.Movies.Movie,
    where: not is_nil(m.imdb_id),
    limit: 1,
    preload: [:external_ratings]
  )
  
  if movie do
    IO.puts("\nSample movie: #{movie.title}")
    IO.puts("IMDb ID: #{movie.imdb_id || "N/A"}")
    IO.puts("External ratings count: #{length(movie.external_ratings)}")
  end
end