# Test movie show page loading
alias Cinegraph.Repo
alias Cinegraph.Movies
alias Cinegraph.Cultural
alias Cinegraph.ExternalSources

# Simulate what happens in MovieLive.Show
movie_id = 202  # How to Train Your Dragon

IO.puts("Testing movie show page loading for movie ID: #{movie_id}")
IO.puts("=" <> String.duplicate("=", 60))

# Load movie with all related data (same function used in the show page)
movie = Movies.get_movie!(movie_id)
IO.puts("\n1. BASIC MOVIE DATA:")
IO.puts("Title: #{movie.title}")
IO.puts("ID: #{movie.id}")
IO.puts("TMDB ID: #{movie.tmdb_id}")

# Load credits (cast and crew)
credits = Movies.get_movie_credits(movie_id)
cast = Enum.filter(credits, & &1.credit_type == "cast") |> Enum.sort_by(& &1.cast_order || 999)
crew = Enum.filter(credits, & &1.credit_type == "crew")
directors = Enum.filter(crew, & &1.job == "Director")

IO.puts("\n2. CREDITS:")
IO.puts("Total credits: #{length(credits)}")
IO.puts("Cast: #{length(cast)}")
IO.puts("Crew: #{length(crew)}")
IO.puts("Directors: #{length(directors)}")
if length(directors) > 0 do
  Enum.each(directors, fn d -> IO.puts("  - #{d.person.name}") end)
end

# Load cultural data
cultural_lists = Cultural.get_list_movies_for_movie(movie_id)
latest_cri_score = Cultural.get_latest_cri_score(movie_id)

IO.puts("\n3. CULTURAL DATA:")
IO.puts("Cultural lists: #{length(cultural_lists)}")
IO.puts("Has CRI score: #{if latest_cri_score, do: "Yes (#{latest_cri_score.overall_score})", else: "No"}")

# Load external sources data
external_ratings = ExternalSources.get_movie_ratings(movie_id)

IO.puts("\n4. EXTERNAL RATINGS:")
IO.puts("Total ratings: #{length(external_ratings)}")
if length(external_ratings) > 0 do
  Enum.each(external_ratings, fn rating ->
    IO.puts("  - #{rating.source.name} (#{rating.rating_type}): #{rating.value}")
  end)
end

# Load ALL other connected data
keywords = Movies.get_movie_keywords(movie_id)
videos = Movies.get_movie_videos(movie_id)
release_dates = Movies.get_movie_release_dates(movie_id)
production_companies = Movies.get_movie_production_companies(movie_id)

IO.puts("\n5. OTHER DATA:")
IO.puts("Keywords: #{length(keywords)}")
IO.puts("Videos: #{length(videos)}")
IO.puts("Release dates: #{length(release_dates)}")
IO.puts("Production companies: #{length(production_companies)}")

# Check what data we're missing
missing_data = %{
  has_keywords: length(keywords) > 0,
  has_videos: length(videos) > 0,
  has_release_dates: length(release_dates) > 0,
  has_credits: length(credits) > 0,
  has_production_companies: length(production_companies) > 0,
  has_external_ratings: length(external_ratings) > 0,
  keywords_count: length(keywords),
  videos_count: length(videos),
  credits_count: length(credits),
  release_dates_count: length(release_dates),
  production_companies_count: length(production_companies),
  external_ratings_count: length(external_ratings)
}

IO.puts("\n6. MISSING DATA CHECK:")
IO.inspect(missing_data, pretty: true)