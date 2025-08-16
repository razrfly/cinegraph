# Test storing aggregate metrics
alias Cinegraph.{Repo, Movies}

IO.puts("🎬 Testing aggregate metrics storage...\n")

# Re-fetch The Godfather to get the new metrics
godfather = Repo.get_by(Movies.Movie, tmdb_id: 238)
if godfather do
  IO.puts("Re-fetching The Godfather to populate aggregate metrics...")
  
  # Delete and re-fetch to ensure clean data
  Repo.delete(godfather)
  
  case Movies.fetch_and_store_movie_comprehensive(238) do
    {:ok, movie} ->
      IO.puts("✅ Successfully fetched and stored")
      
      # Check what metrics we stored
      ratings = Cinegraph.ExternalSources.get_movie_ratings(movie.id)
      
      IO.puts("\nStored ratings/metrics:")
      Enum.each(ratings, fn rating ->
        IO.puts("\n#{rating.rating_type}:")
        IO.puts("  Value: #{rating.value}")
        IO.puts("  Sample size: #{rating.sample_size}")
        IO.puts("  Source: #{rating.source.name}")
        if map_size(rating.metadata || %{}) > 0 do
          IO.puts("  Metadata: #{inspect(rating.metadata)}")
        end
      end)
      
    {:error, reason} ->
      IO.puts("❌ Failed: #{inspect(reason)}")
  end
else
  IO.puts("The Godfather not found in database")
end