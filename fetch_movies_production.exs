# Production movie fetching script
# Run with: export $(grep -v '^#' .env | xargs) && mix run fetch_movies_production.exs

import Ecto.Query
alias Cinegraph.{Movies, Repo}
alias Cinegraph.Services.TMDb

IO.puts("\n🎬 Fetching 100 movies with comprehensive data...")
IO.puts("=" <> String.duplicate("=", 60))

# Step 1: Sync genres
IO.puts("\n📚 Syncing genres...")
case Movies.sync_genres() do
  {:ok, :genres_synced} ->
    genres = Movies.list_genres()
    IO.puts("✅ Synced #{length(genres)} genres")
  {:error, reason} ->
    IO.puts("❌ Failed to sync genres: #{inspect(reason)}")
    exit(:genre_sync_failed)
end

# Step 2: Fetch popular movies
movie_count = 100
batch_size = 20
pages_needed = div(movie_count - 1, batch_size) + 1

processed = 0
failed = 0

Enum.each(1..pages_needed, fn page ->
  IO.puts("\n📄 Fetching page #{page}/#{pages_needed}...")
  
  case TMDb.get_popular_movies(page: page) do
    {:ok, %{"results" => movies}} ->
      movies
      |> Enum.take(batch_size)
      |> Enum.each(fn basic_movie ->
        movie_id = basic_movie["id"]
        title = basic_movie["title"]
        
        IO.write("  Processing: #{title} (#{movie_id})... ")
        
        # Use comprehensive fetch that gets ALL data
        case Movies.fetch_and_store_movie_comprehensive(movie_id) do
          {:ok, _movie} ->
            IO.puts("✅")
            processed = processed + 1
            
          {:error, reason} ->
            IO.puts("❌ #{inspect(reason)}")
            failed = failed + 1
        end
        
        # Small delay to avoid rate limiting
        Process.sleep(250)
      end)
      
    {:error, reason} ->
      IO.puts("❌ Failed to fetch page #{page}: #{inspect(reason)}")
  end
end)

# Display final statistics
IO.puts("\n\n📊 FINAL STATISTICS")
IO.puts("=" <> String.duplicate("=", 60))

# Get counts from database
movie_count = Repo.aggregate(Movies.Movie, :count)
credit_count = Repo.aggregate(Movies.Credit, :count)
keyword_count = Repo.aggregate(Movies.Keyword, :count)
video_count = Repo.aggregate(Movies.MovieVideo, :count)
person_count = Repo.aggregate(Movies.Person, :count)
company_count = Repo.aggregate(Movies.ProductionCompany, :count)

IO.puts("Movies in database: #{movie_count}")
IO.puts("Credits: #{credit_count}")
IO.puts("People: #{person_count}")
IO.puts("Keywords: #{keyword_count}")
IO.puts("Videos: #{video_count}")
IO.puts("Production companies: #{company_count}")

# Check a sample movie
sample_movie = Repo.one(from m in Movies.Movie, limit: 1)
if sample_movie do
  IO.puts("\n📽️ Sample movie check: #{sample_movie.title}")
  keywords = Movies.get_movie_keywords(sample_movie.id)
  videos = Movies.get_movie_videos(sample_movie.id)
  IO.puts("  Keywords: #{length(keywords)}")
  IO.puts("  Videos: #{length(videos)}")
end

IO.puts("\n✅ Data fetching complete!")