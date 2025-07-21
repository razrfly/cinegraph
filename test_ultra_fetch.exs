# Test the ultra comprehensive fetch
alias Cinegraph.{Repo, Movies}

IO.puts("🎬 Testing ultra comprehensive movie fetch...\n")

# Delete The Godfather first to test fresh
godfather = Repo.get_by(Movies.Movie, tmdb_id: 238)
if godfather do
  IO.puts("Deleting existing Godfather record...")
  Repo.delete(godfather)
end

IO.puts("Fetching The Godfather with ULTRA comprehensive data...")
case Movies.fetch_and_store_movie_comprehensive(238) do
  {:ok, movie} ->
    IO.puts("\n✅ Successfully fetched and stored: #{movie.title}")
    
    # Check what data we collected
    IO.puts("\nData collected:")
    IO.puts("  Credits: #{length(Movies.get_movie_credits(movie.id))}")
    IO.puts("  Keywords: #{length(Movies.get_movie_keywords(movie.id))}")
    IO.puts("  Videos: #{length(Movies.get_movie_videos(movie.id))}")
    IO.puts("  Release dates: #{length(Movies.get_movie_release_dates(movie.id))}")
    IO.puts("  Production companies: #{length(Movies.get_movie_production_companies(movie.id))}")
    
    # Check external sources
    ratings = Cinegraph.ExternalSources.get_movie_ratings(movie.id)
    IO.puts("  External ratings: #{length(ratings)}")
    
  {:error, reason} ->
    IO.puts("\n❌ Failed to fetch movie: #{inspect(reason)}")
end