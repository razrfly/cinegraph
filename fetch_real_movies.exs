# Script to fetch real movies from TMDB API and populate database
# Run with: mix run fetch_real_movies.exs

Mix.Task.run("app.start")

import Ecto.Query

IO.puts("🎬 Fetching Real Movies from TMDB")
IO.puts("=" <> String.duplicate("=", 60))

# Get TMDB API key from environment or config
tmdb_api_key = System.get_env("TMDB_API_KEY") || "569d36799113067889ac91b76e5dc8f8"

if !tmdb_api_key do
  IO.puts("❌ TMDB_API_KEY not found")
  System.halt(1)
end

IO.puts("🔑 TMDB API Key found")

# Clear existing sample movies (keep any real ones)
IO.puts("🗑️  Clearing sample movies...")
{deleted_count, _} = Cinegraph.Repo.delete_all(
  from m in Cinegraph.Movies.Movie, 
  where: like(m.title, "Sample Movie%")
)
IO.puts("Deleted #{deleted_count} sample movies")

# Function to fetch movie details from TMDB
defmodule TMDBFetcher do
  def fetch_popular_movies(api_key, page \\ 1) do
    url = "https://api.themoviedb.org/3/movie/popular?api_key=#{api_key}&page=#{page}"
    
    case :httpc.request(:get, {String.to_charlist(url), []}, [], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        Jason.decode(List.to_string(body))
      {:error, error} ->
        {:error, error}
    end
  end
  
  def fetch_top_rated_movies(api_key, page \\ 1) do
    url = "https://api.themoviedb.org/3/movie/top_rated?api_key=#{api_key}&page=#{page}"
    
    case :httpc.request(:get, {String.to_charlist(url), []}, [], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        Jason.decode(List.to_string(body))
      {:error, error} ->
        {:error, error}
    end
  end
  
  def fetch_movie_details(api_key, movie_id) do
    url = "https://api.themoviedb.org/3/movie/#{movie_id}?api_key=#{api_key}"
    
    case :httpc.request(:get, {String.to_charlist(url), []}, [], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        Jason.decode(List.to_string(body))
      {:error, error} ->
        {:error, error}
    end
  end
  
  def transform_movie_data(tmdb_movie) do
    %{
      tmdb_id: tmdb_movie["id"],
      title: tmdb_movie["title"],
      original_title: tmdb_movie["original_title"],
      release_date: parse_date(tmdb_movie["release_date"]),
      runtime: tmdb_movie["runtime"],
      overview: tmdb_movie["overview"],
      tagline: tmdb_movie["tagline"],
      original_language: tmdb_movie["original_language"],
      budget: tmdb_movie["budget"],
      revenue: tmdb_movie["revenue"], 
      status: tmdb_movie["status"] || "Released",
      poster_path: tmdb_movie["poster_path"],
      backdrop_path: tmdb_movie["backdrop_path"],
      adult: tmdb_movie["adult"] || false,
      homepage: tmdb_movie["homepage"],
      imdb_id: tmdb_movie["imdb_id"],
      genre_ids: tmdb_movie["genres"] |> Enum.map(& &1["id"]) || [],
      production_countries: tmdb_movie["production_countries"] || [],
      spoken_languages: tmdb_movie["spoken_languages"] || [],
      tmdb_raw_data: tmdb_movie,
      tmdb_fetched_at: DateTime.utc_now()
    }
  end
  
  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil
  defp parse_date(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end
end

# Check current movie count
current_count = Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count)
IO.puts("📊 Current movies in database: #{current_count}")

target_movies = 150
movies_to_fetch = max(0, target_movies - current_count)

if movies_to_fetch <= 0 do
  IO.puts("✅ Already have sufficient movies!")
else
  IO.puts("🎯 Fetching #{movies_to_fetch} movies from TMDB...")
  
  # Fetch popular movies (pages 1-4)
  popular_movies = for page <- 1..4 do
    IO.write("Fetching popular movies page #{page}...")
    case TMDBFetcher.fetch_popular_movies(tmdb_api_key, page) do
      {:ok, %{"results" => movies}} ->
        IO.puts(" ✅ #{length(movies)} movies")
        movies
      {:error, error} ->
        IO.puts(" ❌ Error: #{inspect(error)}")
        []
    end
    :timer.sleep(100) # Rate limiting
  end |> List.flatten()
  
  # Fetch top rated movies (pages 1-4)
  top_rated_movies = for page <- 1..4 do
    IO.write("Fetching top rated movies page #{page}...")
    case TMDBFetcher.fetch_top_rated_movies(tmdb_api_key, page) do
      {:ok, %{"results" => movies}} ->
        IO.puts(" ✅ #{length(movies)} movies")
        movies
      {:error, error} ->
        IO.puts(" ❌ Error: #{inspect(error)}")
        []
    end
    :timer.sleep(100) # Rate limiting
  end |> List.flatten()
  
  # Combine and deduplicate movies
  all_movies = (popular_movies ++ top_rated_movies)
               |> Enum.filter(& is_map(&1) and Map.has_key?(&1, "id"))
               |> Enum.uniq_by(& &1["id"])
               |> Enum.take(movies_to_fetch)
  
  IO.puts("🎬 Found #{length(all_movies)} unique movies to process")
  
  # Fetch detailed data for each movie and insert
  inserted_count = 0
  
  all_movies
  |> Enum.with_index()
  |> Enum.reduce(0, fn {movie, index}, acc ->
    IO.write("Processing movie #{index + 1}/#{length(all_movies)}: #{movie["title"]}...")
    
    # Check if movie already exists
    existing = Cinegraph.Repo.get_by(Cinegraph.Movies.Movie, tmdb_id: movie["id"])
    
    if existing do
      IO.puts(" (already exists)")
      acc
    else
      # Fetch detailed movie data
      case TMDBFetcher.fetch_movie_details(tmdb_api_key, movie["id"]) do
        {:ok, detailed_movie} ->
          movie_attrs = TMDBFetcher.transform_movie_data(detailed_movie)
          
          case Cinegraph.Movies.create_movie(movie_attrs) do
            {:ok, _created_movie} ->
              IO.puts(" ✅")
              acc + 1
            {:error, changeset} ->
              IO.puts(" ❌ #{inspect(changeset.errors)}")
              acc
          end
          
        {:error, error} ->
          IO.puts(" ❌ API Error: #{inspect(error)}")
          acc
      end
      
      :timer.sleep(100) # Rate limiting
    end
  end)
  
  IO.puts("✅ Successfully inserted #{inserted_count} new movies")
end

# Seed authorities if needed
authorities_count = Cinegraph.Repo.aggregate(Cinegraph.Cultural.Authority, :count)
if authorities_count == 0 do
  IO.puts("🏛️ Seeding cultural authorities...")
  Cinegraph.Cultural.seed_authorities()
  IO.puts("✅ Authorities seeded")
end

# Add some movies to cultural lists
IO.puts("🎭 Adding movies to cultural lists...")

movies = Cinegraph.Movies.list_movies() |> Enum.take(30)
afi_list = Cinegraph.Repo.get_by(Cinegraph.Cultural.CuratedList, name: "AFI's 100 Years...100 Movies")
best_picture_list = Cinegraph.Repo.get_by(Cinegraph.Cultural.CuratedList, name: "Best Picture")

if afi_list && length(movies) > 0 do
  movies
  |> Enum.take(15)
  |> Enum.with_index(1)
  |> Enum.each(fn {movie, rank} ->
    case Cinegraph.Repo.get_by(Cinegraph.Cultural.MovieListItem, movie_id: movie.id, list_id: afi_list.id) do
      nil ->
        Cinegraph.Cultural.add_movie_to_list(movie.id, afi_list.id, %{
          rank: rank,
          notes: "Great American film"
        })
      _existing -> :ok
    end
  end)
  
  IO.puts("✅ Added movies to AFI list")
end

if best_picture_list && length(movies) > 5 do
  movies
  |> Enum.take(10)
  |> Enum.with_index()
  |> Enum.each(fn {movie, index} ->
    result = if rem(index, 3) == 0, do: "winner", else: "nominee"
    year = 2000 + index
    
    case Cinegraph.Repo.get_by(Cinegraph.Cultural.MovieListItem, movie_id: movie.id, list_id: best_picture_list.id) do
      nil ->
        Cinegraph.Cultural.add_movie_to_list(movie.id, best_picture_list.id, %{
          award_category: "Best Picture",
          award_result: result,
          year_added: year,
          notes: "#{year} Academy Awards"
        })
      _existing -> :ok
    end
  end)
  
  IO.puts("✅ Added award data")
end

# Calculate CRI scores for movies
IO.puts("📊 Calculating CRI scores...")
movies
|> Enum.take(25)
|> Enum.each(fn movie ->
  Cinegraph.Cultural.calculate_cri_score(movie.id)
end)

IO.puts("✅ CRI scores calculated")

# Final summary
final_count = Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count)
authorities = Cinegraph.Repo.aggregate(Cinegraph.Cultural.Authority, :count)
lists = Cinegraph.Repo.aggregate(Cinegraph.Cultural.CuratedList, :count) 
cri_scores = Cinegraph.Repo.aggregate(Cinegraph.Cultural.CRIScore, :count)

IO.puts("\n🎉 Real Movie Data Complete!")
IO.puts("Movies: #{final_count}")
IO.puts("Authorities: #{authorities}")
IO.puts("Lists: #{lists}")
IO.puts("CRI Scores: #{cri_scores}")
IO.puts("\n🌐 Visit: http://localhost:4000/movies")