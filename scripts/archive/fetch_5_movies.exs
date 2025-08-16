# Simple test to fetch 5 movies
import Ecto.Query
alias Cinegraph.{Movies, Repo}

IO.puts("Testing comprehensive movie fetch...")

# Sync genres first
Movies.sync_genres()

# Get a specific movie ID that we know exists
movie_ids = [238, 278, 240, 424, 389]  # Godfather, Shawshank, Godfather II, Schindler's List, 12 Angry Men

Enum.each(movie_ids, fn movie_id ->
  IO.write("\nFetching movie #{movie_id}... ")
  
  case Movies.fetch_and_store_movie_comprehensive(movie_id) do
    {:ok, movie} ->
      IO.puts("✅ #{movie.title}")
      
      # Check what data was collected
      keywords = Movies.get_movie_keywords(movie.id)
      videos = Movies.get_movie_videos(movie.id)
      credits = Repo.all(Ecto.Query.from(c in Movies.Credit, where: c.movie_id == ^movie.id))
      
      IO.puts("  - Keywords: #{length(keywords)}")
      IO.puts("  - Videos: #{length(videos)}")
      IO.puts("  - Credits: #{length(credits)}")
      
    {:error, reason} ->
      IO.puts("❌ Error: #{inspect(reason)}")
  end
  
  Process.sleep(500)
end)

# Final check
IO.puts("\nFinal database counts:")
IO.puts("Movies: #{Repo.aggregate(Movies.Movie, :count)}")
IO.puts("People: #{Repo.aggregate(Movies.Person, :count)}")
IO.puts("Keywords: #{Repo.aggregate(Movies.Keyword, :count)}")
IO.puts("Videos: #{Repo.aggregate(Movies.MovieVideo, :count)}")
IO.puts("Credits: #{Repo.aggregate(Movies.Credit, :count)}")