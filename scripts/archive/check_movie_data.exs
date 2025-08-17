# Check movie data in database
alias Cinegraph.Repo
alias Cinegraph.Movies.Movie
alias Cinegraph.ExternalSources.Rating
import Ecto.Query

# Check if movie 2 exists
movie = Repo.get(Movie, 2)
if movie do
  IO.puts("Movie found: #{movie.title}")
  IO.puts("ID: #{movie.id}")
  IO.puts("TMDB ID: #{movie.tmdb_id}")
else
  # Try to find a movie that exists
  first_movie = Repo.one(from m in Movie, limit: 1, order_by: [asc: m.id])
  if first_movie do
    IO.puts("Movie ID 2 not found. First movie in DB:")
    IO.puts("ID: #{first_movie.id}")
    IO.puts("Title: #{first_movie.title}")
    IO.puts("TMDB ID: #{first_movie.tmdb_id}")
  end
end

# Check related data counts
IO.puts("\nRelated data counts:")
IO.puts("Total movies: #{Repo.aggregate(Movie, :count)}")
IO.puts("Keywords: #{Repo.aggregate(Cinegraph.Movies.Keyword, :count)}")
IO.puts("Videos: #{Repo.aggregate(Cinegraph.Movies.MovieVideo, :count)}")
IO.puts("Credits: #{Repo.aggregate(Cinegraph.Movies.Credit, :count)}")
IO.puts("Release Dates: #{Repo.aggregate(Cinegraph.Movies.MovieReleaseDate, :count)}")
IO.puts("Production Companies: #{Repo.aggregate(Cinegraph.Movies.ProductionCompany, :count)}")
IO.puts("External Ratings: #{Repo.aggregate(Rating, :count)}")

# Check if movie 2 has any ratings
if movie do
  ratings = Repo.all(from r in Rating, where: r.movie_id == ^movie.id)
  IO.puts("\nMovie ID #{movie.id} has #{length(ratings)} ratings")
end

# Show a few available movie IDs
available_ids = Repo.all(from m in Movie, select: {m.id, m.title}, limit: 10, order_by: [asc: m.id])
IO.puts("\nAvailable movies:")
for {id, title} <- available_ids do
  IO.puts("  #{id}: #{title}")
end