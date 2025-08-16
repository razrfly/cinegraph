# This script populates the database with real movie data
# It ensures data persists by running in the correct environment

# First, let's verify we're not in sandbox mode
IO.puts("Starting movie population script...")
IO.puts("Environment: #{Mix.env()}")

# Check repo configuration
repo_config = Application.get_env(:cinegraph, Cinegraph.Repo)
pool_type = Keyword.get(repo_config, :pool)
IO.puts("Repo pool type: #{inspect(pool_type)}")

# Import required modules
import Ecto.Query
alias Cinegraph.{Movies, Repo}
alias Cinegraph.Services.TMDb

# Define our movie list
movie_ids = [
  238,    # The Godfather
  278,    # The Shawshank Redemption
  240,    # The Godfather Part II
  424,    # Schindler's List
  389,    # 12 Angry Men
  155,    # The Dark Knight
  550,    # Fight Club
  680,    # Pulp Fiction
  122,    # The Lord of the Rings: The Return of the King
  13,     # Forrest Gump
  769,    # GoodFellas
  129,    # Spirited Away
  497,    # The Green Mile
  311,    # Once Upon a Time in America
  539,    # Psycho
  19404,  # Dilwale Dulhania Le Jayenge
  637,    # Life Is Beautiful
  11216,  # Cinema Paradiso
  12477,  # Grave of the Fireflies
  510,    # One Flew Over the Cuckoo's Nest
]

# Clean up test data first
IO.puts("\nCleaning up test data...")
Repo.delete_all(from m in Movies.Movie, where: m.tmdb_id == 999999)

# Show initial state
initial_count = Repo.aggregate(Movies.Movie, :count)
IO.puts("Initial movie count: #{initial_count}")

# First sync genres
IO.puts("\n📚 Syncing genres...")
case Movies.sync_genres() do
  {:ok, :genres_synced} ->
    genres = Movies.list_genres()
    IO.puts("✅ Synced #{length(genres)} genres")
  {:error, reason} ->
    IO.puts("❌ Failed to sync genres: #{inspect(reason)}")
end

# Track results - use Agent to properly handle state
{:ok, agent} = Agent.start_link(fn -> %{successful: [], failed: []} end)

# Process each movie
IO.puts("\n🎥 Fetching #{length(movie_ids)} classic movies...")
Enum.each(movie_ids, fn movie_id ->
  IO.write("Fetching movie #{movie_id}... ")
  
  case Movies.fetch_and_store_movie_comprehensive(movie_id) do
    {:ok, movie} ->
      IO.puts("✅ #{movie.title}")
      
      # Verify it's actually in the database
      if Repo.get(Movies.Movie, movie.id) do
        Agent.update(agent, fn state ->
          Map.update!(state, :successful, &[movie.title | &1])
        end)
      else
        IO.puts("  ⚠️  Movie not found in database after save!")
        Agent.update(agent, fn state ->
          Map.update!(state, :failed, &[{movie.title, :not_persisted} | &1])
        end)
      end
      
    {:error, reason} ->
      IO.puts("❌ Failed: #{inspect(reason)}")
      Agent.update(agent, fn state ->
        Map.update!(state, :failed, &[{movie_id, reason} | &1])
      end)
  end
  
  # Small delay to avoid rate limiting
  Process.sleep(300)
end)

# Final verification
IO.puts("\n\n📊 FINAL VERIFICATION")
IO.puts("=" <> String.duplicate("=", 60))

# Get real counts from database
movie_count = Repo.aggregate(Movies.Movie, :count)
credit_count = Repo.aggregate(Movies.Credit, :count)
keyword_count = Repo.aggregate(Movies.Keyword, :count)
video_count = Repo.aggregate(Movies.MovieVideo, :count)
person_count = Repo.aggregate(Movies.Person, :count)
company_count = Repo.aggregate(Movies.ProductionCompany, :count)
release_dates_count = Repo.aggregate(Movies.MovieReleaseDate, :count)

IO.puts("\nDatabase contents:")
IO.puts("  Movies: #{movie_count}")
IO.puts("  Credits: #{credit_count}")
IO.puts("  People: #{person_count}")
IO.puts("  Keywords: #{keyword_count}")
IO.puts("  Videos: #{video_count}")
IO.puts("  Release dates: #{release_dates_count}")
IO.puts("  Production companies: #{company_count}")

# Get final results
results = Agent.get(agent, & &1)

IO.puts("\nSuccessful imports (#{length(results.successful)}):")
Enum.each(Enum.reverse(results.successful), &IO.puts("  ✅ #{&1}"))

if length(results.failed) > 0 do
  IO.puts("\nFailed imports (#{length(results.failed)}):")
  Enum.each(Enum.reverse(results.failed), fn {title, reason} ->
    IO.puts("  ❌ #{title}: #{inspect(reason)}")
  end)
end

# Show sample movie with all data
if movie_count > 0 do
  # Get The Godfather if it exists
  godfather = Repo.get_by(Movies.Movie, tmdb_id: 238)
  
  if godfather do
    IO.puts("\n📽️ The Godfather Data Check:")
    
    # Load all associated data
    keywords = Movies.get_movie_keywords(godfather.id)
    videos = Movies.get_movie_videos(godfather.id)
    release_dates = Movies.get_movie_release_dates(godfather.id)
    {cast, crew} = Movies.get_movie_credits(godfather.id)
    production_companies = Movies.get_movie_production_companies(godfather.id)
    
    IO.puts("  Keywords: #{length(keywords)}")
    IO.puts("  Videos: #{length(videos)}")
    IO.puts("  Cast: #{length(cast)}")
    IO.puts("  Crew: #{length(crew)}")
    IO.puts("  Release dates: #{length(release_dates)}")
    IO.puts("  Production companies: #{length(production_companies)}")
    IO.puts("  Has external IDs: #{map_size(godfather.external_ids || %{}) > 0}")
    IO.puts("  Has images: #{map_size(godfather.images || %{}) > 0}")
  end
end

IO.puts("\n✅ Script complete!")
IO.puts("Movies added this run: #{movie_count - initial_count}")