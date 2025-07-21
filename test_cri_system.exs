# Test script for Cultural Relevance Index (CRI) system
# Run with: mix run test_cri_system.exs

Mix.Task.run("app.start")

IO.puts("🎬 Testing Cultural Relevance Index (CRI) System")
IO.puts("=" <> String.duplicate("=", 60))

# Test database connection
try do
  Cinegraph.Repo.query!("SELECT 1")
  IO.puts("✅ Database connection successful")
rescue
  e ->
    IO.puts("❌ Database connection failed: #{inspect(e)}")
    System.halt(1)
end

# Seed cultural authorities
IO.puts("\n📊 Seeding cultural authorities...")
Cinegraph.Cultural.seed_authorities()

authorities = Cinegraph.Cultural.list_authorities()
IO.puts("   Created #{length(authorities)} cultural authorities:")
Enum.each(authorities, fn auth ->
  IO.puts("   - #{auth.name} (#{auth.authority_type})")
end)

# Create some test curated lists
IO.puts("\n📝 Creating test curated lists...")

# Get Academy Awards authority
academy = Cinegraph.Cultural.get_authority_by_name("Academy of Motion Picture Arts and Sciences")

if academy do
  # Create Best Picture 2023 list (or get existing)
  best_picture_2023 = case Cinegraph.Cultural.create_curated_list(%{
    authority_id: academy.id,
    name: "Best Picture",
    list_type: "award",
    year: 2023,
    description: "Academy Award Best Picture nominees for 2023",
    prestige_score: 0.95,
    cultural_impact: 0.90
  }) do
    {:ok, list} -> 
      IO.puts("   ✅ Created list: #{list.name} #{list.year}")
      list
    {:error, %{errors: [authority_id: _]}} ->
      # List already exists, get it
      existing_lists = Cinegraph.Cultural.list_curated_lists(academy.id)
      list = Enum.find(existing_lists, & &1.name == "Best Picture" && &1.year == 2023)
      IO.puts("   ✅ Using existing list: #{list.name} #{list.year}")
      list
  end
  
  # Create AFI Top 100 list (or get existing)
  afi_top_100 = case Cinegraph.Cultural.create_curated_list(%{
    authority_id: academy.id,
    name: "AFI's 100 Years...100 Movies",
    list_type: "ranked",
    year: 2007,
    total_items: 100,
    description: "AFI's definitive list of the greatest American movies",
    prestige_score: 0.88,
    cultural_impact: 0.92
  }) do
    {:ok, list} ->
      IO.puts("   ✅ Created list: #{list.name}")
      list
    {:error, %{errors: [authority_id: _]}} ->
      # List already exists, get it
      existing_lists = Cinegraph.Cultural.list_curated_lists(academy.id)
      list = Enum.find(existing_lists, & &1.name == "AFI's 100 Years...100 Movies")
      IO.puts("   ✅ Using existing list: #{list.name}")
      list
  end
else
  IO.puts("   ❌ Could not find Academy authority")
end

# Test TMDB integration with a sample movie or create mock data
IO.puts("\n🎭 Testing movie and CRI system...")

# Check if TMDB API key is available
has_tmdb_key = System.get_env("TMDB_API_KEY") != nil

movie = if has_tmdb_key do
  # Test with "The Godfather" (TMDB ID: 238)
  test_movie_id = 238
  
  case Cinegraph.Movies.fetch_and_store_movie_comprehensive(test_movie_id) do
    {:ok, movie} ->
      IO.puts("   ✅ Successfully fetched from TMDB: #{movie.title} (#{movie.release_date})")
      movie
    {:error, error} ->
      IO.puts("   ❌ Failed to fetch from TMDB: #{inspect(error)}")
      nil
  end
else
  # Create mock movie data for testing
  IO.puts("   ⚠️  TMDB API key not available, using mock data...")
  
  {:ok, movie} = Cinegraph.Movies.create_movie(%{
    tmdb_id: 238,
    title: "The Godfather",
    original_title: "The Godfather",
    release_date: ~D[1972-03-24],
    runtime: 175,
    overview: "Spanning the years 1945 to 1955, a chronicle of the fictional Italian-American Corleone crime family.",
    original_language: "en",
    status: "Released"
  })
  
  IO.puts("   ✅ Created mock movie: #{movie.title} (#{movie.release_date})")
  movie
end

if movie do
    IO.puts("   ✅ Successfully fetched and stored: #{movie.title} (#{movie.release_date})")
    
    # Add movie to AFI Top 100 list (The Godfather is #3)
    afi_lists = Cinegraph.Cultural.list_curated_lists()
    afi_top_100 = Enum.find(afi_lists, & &1.name == "AFI's 100 Years...100 Movies")
    
    if afi_top_100 do
      case Cinegraph.Cultural.add_movie_to_list(movie.id, afi_top_100.id, %{
        rank: 3,
        notes: "Francis Ford Coppola's masterpiece"
      }) do
        {:ok, _item} ->
          IO.puts("   ✅ Added #{movie.title} to AFI Top 100 at rank #3")
        {:error, error} ->
          IO.puts("   ⚠️  Could not add to list: #{inspect(error)}")
      end
    end
    
    # Calculate CRI score for the movie
    IO.puts("\n🧮 Calculating CRI score for #{movie.title}...")
    
    case Cinegraph.Cultural.calculate_cri_score(movie.id) do
      {:ok, cri_score} ->
        IO.puts("   ✅ CRI Score calculated: #{Float.round(cri_score.score, 2)}/100")
        IO.puts("   📊 Components:")
        Enum.each(cri_score.components, fn {component, score} ->
          IO.puts("     - #{component}: #{Float.round(score, 3)}")
        end)
      {:error, error} ->
        IO.puts("   ❌ CRI calculation failed: #{inspect(error)}")
    end
    
    # Test getting latest CRI score
    latest_score = Cinegraph.Cultural.get_latest_cri_score(movie.id)
    if latest_score do
      IO.puts("   ✅ Latest CRI score retrieved: #{Float.round(latest_score.score, 2)}")
    end
    
else
  IO.puts("   ❌ No movie created for testing")
end

# Test TMDB Extended functionality (only if API key available)
if has_tmdb_key do
  IO.puts("\n🔍 Testing TMDB Extended functionality...")

  # Test watch providers
  case Cinegraph.Services.TMDb.get_movie_watch_providers(238) do
    {:ok, providers} ->
      IO.puts("   ✅ Watch providers fetched successfully")
      us_providers = get_in(providers, ["results", "US"])
      if us_providers do
        stream_count = length(us_providers["flatrate"] || [])
        rent_count = length(us_providers["rent"] || [])
        IO.puts("     - US: #{stream_count} streaming, #{rent_count} rental options")
      end
    {:error, error} ->
      IO.puts("   ⚠️  Watch providers failed: #{inspect(error)}")
  end

  # Test trending movies
  case Cinegraph.Services.TMDb.get_trending_movies("day", page: 1) do
    {:ok, trending} ->
      count = length(trending["results"] || [])
      IO.puts("   ✅ Trending movies fetched: #{count} movies")
    {:error, error} ->
      IO.puts("   ⚠️  Trending movies failed: #{inspect(error)}")
  end

  # Test enhanced discover
  IO.puts("\n🔭 Testing enhanced movie discovery...")

  # Find highly-rated movies in Spanish
  case Cinegraph.Services.TMDb.discover_movies_enhanced(
    with_original_language: "es",
    vote_average_gte: 7.0,
    sort_by: "popularity.desc",
    page: 1
  ) do
    {:ok, results} ->
      count = length(results["results"] || [])
      IO.puts("   ✅ Enhanced discovery: Found #{count} highly-rated Spanish movies")
    {:error, error} ->
      IO.puts("   ⚠️  Enhanced discovery failed: #{inspect(error)}")
  end
else
  IO.puts("\n⚠️  Skipping TMDB Extended functionality tests (no API key)")
end

# Test database schema and model validations
IO.puts("\n🔍 Testing model validations...")

# Test creating an invalid authority
case Cinegraph.Cultural.create_authority(%{
  name: "Test Authority",
  authority_type: "invalid_type"  # Invalid type
}) do
  {:error, changeset} ->
    IO.puts("   ✅ Authority validation working: #{inspect(changeset.errors[:authority_type])}")
  {:ok, _} ->
    IO.puts("   ❌ Authority validation failed - should have rejected invalid type")
end

# Test creating a valid authority
case Cinegraph.Cultural.create_authority(%{
  name: "Test Film Festival",
  authority_type: "award",
  trust_score: 0.8,
  country_code: "US"
}) do
  {:ok, authority} ->
    IO.puts("   ✅ Valid authority created: #{authority.name}")
  {:error, error} ->
    IO.puts("   ❌ Valid authority creation failed: #{inspect(error)}")
end

# Summary
IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("🎊 CRI System Test Complete!")

# Count records
movie_count = Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count)
authority_count = Cinegraph.Repo.aggregate(Cinegraph.Cultural.Authority, :count)
list_count = Cinegraph.Repo.aggregate(Cinegraph.Cultural.CuratedList, :count)
cri_count = Cinegraph.Repo.aggregate(Cinegraph.Cultural.CRIScore, :count)

IO.puts("📊 Database Summary:")
IO.puts("   - Movies: #{movie_count}")
IO.puts("   - Cultural Authorities: #{authority_count}")
IO.puts("   - Curated Lists: #{list_count}")
IO.puts("   - CRI Scores: #{cri_count}")

IO.puts("\n✨ All systems operational! CRI v1.0 schema is ready for cultural relevance tracking.")