# Test fetching real award data
alias Cinegraph.{Repo, Movies}
alias Cinegraph.Cultural.AwardFetcher

IO.puts("🎬 Testing real award data fetching...\n")

# Get The Godfather
godfather = Repo.get_by(Movies.Movie, tmdb_id: 238)

if godfather do
  IO.puts("Testing with: #{godfather.title}")
  IO.puts("IMDb ID: #{godfather.imdb_id || "MISSING!"}")
  
  if godfather.imdb_id do
    IO.puts("\nFetching awards from Wikidata...")
    
    case AwardFetcher.fetch_and_store_awards(godfather) do
      {:ok, count} ->
        IO.puts("✅ Successfully fetched #{count} award entries")
        
        # Now check what we stored
        movie_lists = Cinegraph.Cultural.get_list_movies_for_movie(godfather.id)
        IO.puts("\nStored award data:")
        Enum.each(movie_lists, fn item ->
          IO.puts("  - #{item.list.name} (#{item.list.authority.name})")
          IO.puts("    Result: #{item.award_result || "unknown"}")
          IO.puts("    Category: #{item.award_category || "N/A"}")
        end)
        
      {:error, reason} ->
        IO.puts("❌ Failed to fetch awards: #{inspect(reason)}")
    end
  else
    IO.puts("\n⚠️  The Godfather has no IMDb ID in our database!")
    IO.puts("Let's check the external_ids field...")
    IO.inspect(godfather.external_ids, label: "External IDs")
    
    # The IMDb ID might be in external_ids JSON
    imdb_from_external = godfather.external_ids["imdb_id"]
    if imdb_from_external do
      IO.puts("\nFound IMDb ID in external_ids: #{imdb_from_external}")
      IO.puts("We need to update the movie record to have this in the imdb_id field")
    end
  end
else
  IO.puts("❌ The Godfather not found in database!")
end

# Show what authorities we have
IO.puts("\n📋 Current authorities:")
authorities = Cinegraph.Cultural.list_authorities()
Enum.each(authorities, fn auth ->
  lists = Cinegraph.Cultural.list_curated_lists(auth.id)
  IO.puts("  - #{auth.name}: #{length(lists)} lists")
end)