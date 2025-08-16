# This script demonstrates the issue - we need real award data sources
# TMDB does not provide award information

alias Cinegraph.{Repo, Cultural, Movies}
alias Cinegraph.Cultural.{Authority, CuratedList, MovieListItem}

IO.puts("🎬 Checking what award data we can get from our current sources...")

# First, let's check if we have authorities
authorities = Cultural.list_authorities()
IO.puts("\nAuthorities in database: #{length(authorities)}")
Enum.each(authorities, fn auth ->
  IO.puts("  - #{auth.name} (#{auth.authority_type})")
end)

# Check if we have any curated lists
lists = Cultural.list_curated_lists()
IO.puts("\nCurated lists in database: #{length(lists)}")

# Try to fetch TMDB lists for The Godfather
godfather = Repo.get_by(Movies.Movie, tmdb_id: 238)
if godfather do
  IO.puts("\n📽️ Checking TMDB lists for The Godfather...")
  
  case Cinegraph.Services.TMDb.Extended.get_movie_lists(238) do
    {:ok, %{"results" => tmdb_lists}} ->
      IO.puts("TMDB user lists containing The Godfather: #{length(tmdb_lists)}")
      
      # Show first few lists
      tmdb_lists
      |> Enum.take(5)
      |> Enum.each(fn list ->
        IO.puts("  - #{list["name"]} by #{list["created_by"]["username"]} (#{list["item_count"]} items)")
      end)
      
      IO.puts("\n⚠️  These are user-created lists, not authoritative cultural lists!")
      
    {:error, reason} ->
      IO.puts("Failed to fetch TMDB lists: #{inspect(reason)}")
  end
else
  IO.puts("The Godfather not found in database")
end

IO.puts("\n❌ PROBLEM IDENTIFIED:")
IO.puts("1. TMDB does not provide award data (Oscars, Cannes, etc.)")
IO.puts("2. TMDB does not provide authoritative list memberships (Criterion, AFI Top 100, etc.)")
IO.puts("3. We need to implement fetchers for external data sources that have this information")
IO.puts("\nSome potential sources:")
IO.puts("- IMDb (has award data but requires scraping)")
IO.puts("- Wikidata (has structured award data via SPARQL queries)")
IO.puts("- Individual authority APIs/websites (Criterion has an API)")
IO.puts("- Open Movie Database (OMDb) API (has some award data)")

# Example of what we SHOULD be storing (but currently have no way to fetch)
IO.puts("\n📋 Example of data we need to collect:")
IO.puts("The Godfather should have:")
IO.puts("- Academy Awards: Best Picture (Winner), Best Actor (Winner), Best Adapted Screenplay (Winner)")
IO.puts("- Golden Globes: Best Motion Picture - Drama (Winner)")
IO.puts("- AFI's 100 Years...100 Movies: #2")
IO.puts("- National Film Registry: Selected in 1990")
IO.puts("- Criterion Collection: Not included")
IO.puts("- Sight & Sound Critics' Poll: Frequently in top 10")

IO.puts("\n🔧 Next steps:")
IO.puts("1. Implement Wikidata integration for award data")
IO.puts("2. Implement web scraping for lists that don't have APIs")
IO.puts("3. Create manual data entry tools for curated lists")
IO.puts("4. Set up periodic sync jobs to keep data current")