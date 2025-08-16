# Check movie associations
alias Cinegraph.Repo
alias Cinegraph.Movies
alias Cinegraph.Movies.Movie
alias Cinegraph.ExternalSources.Rating
import Ecto.Query

# Get the first movie
movie_id = 323  # How to Train Your Dragon
movie = Repo.get(Movie, movie_id)

IO.puts("Checking movie: #{movie.title} (ID: #{movie.id})")
IO.puts("=" <> String.duplicate("=", 50))

# Check keywords
IO.puts("\n1. KEYWORDS:")
keywords = Movies.get_movie_keywords(movie_id)
IO.puts("Found #{length(keywords)} keywords")
if length(keywords) > 0 do
  Enum.each(keywords, fn keyword ->
    IO.puts("  - #{keyword.name}")
  end)
end

# Check videos
IO.puts("\n2. VIDEOS:")
videos = Movies.get_movie_videos(movie_id)
IO.puts("Found #{length(videos)} videos")
if length(videos) > 0 do
  Enum.each(videos, fn video ->
    IO.puts("  - #{video.name} (#{video.type} on #{video.site})")
  end)
end

# Check credits
IO.puts("\n3. CREDITS:")
credits = Movies.get_movie_credits(movie_id)
IO.puts("Found #{length(credits)} credits total")
cast = Enum.filter(credits, & &1.credit_type == "cast")
crew = Enum.filter(credits, & &1.credit_type == "crew")
IO.puts("  Cast: #{length(cast)}")
IO.puts("  Crew: #{length(crew)}")

# Check release dates
IO.puts("\n4. RELEASE DATES:")
release_dates = Movies.get_movie_release_dates(movie_id)
IO.puts("Found #{length(release_dates)} release dates")
if length(release_dates) > 0 do
  Enum.take(release_dates, 5) |> Enum.each(fn rd ->
    IO.puts("  - #{rd.country_code}: #{rd.release_date} (#{rd.certification || "No cert"})")
  end)
end

# Check production companies
IO.puts("\n5. PRODUCTION COMPANIES:")
companies = Movies.get_movie_production_companies(movie_id)
IO.puts("Found #{length(companies)} production companies")
if length(companies) > 0 do
  Enum.each(companies, fn company ->
    IO.puts("  - #{company.name}")
  end)
end

# Check external ratings
IO.puts("\n6. EXTERNAL RATINGS:")
ratings = Repo.all(from r in Rating, where: r.movie_id == ^movie_id, preload: :source)
IO.puts("Found #{length(ratings)} external ratings")
if length(ratings) > 0 do
  Enum.each(ratings, fn rating ->
    IO.puts("  - #{rating.source.name} (#{rating.rating_type}): #{rating.value}")
  end)
end

# Check the many-to-many associations directly
IO.puts("\n7. DIRECT ASSOCIATION CHECKS:")

# Movie keywords junction
keyword_count = Repo.one(from mk in "movie_keywords", where: mk.movie_id == ^movie_id, select: count())
IO.puts("Movie-Keywords junction records: #{keyword_count}")

# Movie production companies junction
company_count = Repo.one(from mpc in "movie_production_companies", where: mpc.movie_id == ^movie_id, select: count())
IO.puts("Movie-ProductionCompanies junction records: #{company_count}")

# Check if the movie has the associations configured properly
IO.puts("\n8. PRELOADING TEST:")
movie_with_preloads = Repo.get(Movie, movie_id) |> Repo.preload([:keywords, :production_companies])
IO.puts("Keywords via preload: #{length(movie_with_preloads.keywords || [])}")
IO.puts("Production companies via preload: #{length(movie_with_preloads.production_companies || [])}")