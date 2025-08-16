# Populate database with real movies
# This script will NOT use sandbox mode and will persist data

# Ensure we're not in sandbox mode
Application.put_env(:cinegraph, :sql_sandbox, false)

import Ecto.Query
alias Cinegraph.{Movies, Repo}
alias Cinegraph.Services.TMDb

IO.puts("🎬 Starting database population...")
IO.puts("Current environment: #{Mix.env()}")

# First sync genres
IO.puts("\n📚 Syncing genres...")
case Movies.sync_genres() do
  {:ok, :genres_synced} ->
    genres = Movies.list_genres()
    IO.puts("✅ Synced #{length(genres)} genres")
  {:error, reason} ->
    IO.puts("❌ Failed to sync genres: #{inspect(reason)}")
    exit(:genre_sync_failed)
end

# Fetch a smaller batch of popular movies
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

successful = 0
failed = 0

IO.puts("\n🎥 Fetching #{length(movie_ids)} classic movies...")

Enum.each(movie_ids, fn movie_id ->
  IO.write("Fetching movie #{movie_id}... ")
  
  case Movies.fetch_and_store_movie_comprehensive(movie_id) do
    {:ok, movie} ->
      IO.puts("✅ #{movie.title}")
      successful = successful + 1
    {:error, reason} ->
      IO.puts("❌ Failed: #{inspect(reason)}")
      failed = failed + 1
  end
  
  # Small delay to avoid rate limiting
  Process.sleep(300)
end)

# Fetch some popular movies from TMDb
IO.puts("\n📄 Fetching additional popular movies...")
case TMDb.get_popular_movies(page: 1) do
  {:ok, %{"results" => movies}} ->
    movies
    |> Enum.take(10)
    |> Enum.each(fn basic_movie ->
      movie_id = basic_movie["id"]
      title = basic_movie["title"]
      
      IO.write("Processing: #{title} (#{movie_id})... ")
      
      case Movies.fetch_and_store_movie_comprehensive(movie_id) do
        {:ok, _movie} ->
          IO.puts("✅")
          successful = successful + 1
        {:error, reason} ->
          IO.puts("❌ #{inspect(reason)}")
          failed = failed + 1
      end
      
      Process.sleep(300)
    end)
    
  {:error, reason} ->
    IO.puts("❌ Failed to fetch popular movies: #{inspect(reason)}")
end

# Final statistics
IO.puts("\n\n📊 FINAL STATISTICS")
IO.puts("=" <> String.duplicate("=", 60))
IO.puts("Successful: #{successful}")
IO.puts("Failed: #{failed}")

# Get counts from database
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

# Show sample movie
if movie_count > 0 do
  sample_movie = Repo.one!(from m in Movies.Movie, limit: 1, order_by: [desc: m.id])
  keywords = Movies.get_movie_keywords(sample_movie.id)
  videos = Movies.get_movie_videos(sample_movie.id)
  
  IO.puts("\n📽️ Sample movie: #{sample_movie.title}")
  IO.puts("  Keywords: #{length(keywords)}")
  IO.puts("  Videos: #{length(videos)}")
  IO.puts("  Has images: #{map_size(sample_movie.images) > 0}")
  IO.puts("  Has external IDs: #{map_size(sample_movie.external_ids) > 0}")
end

IO.puts("\n✅ Database population complete!")