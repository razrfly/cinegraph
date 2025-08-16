# Quick script to fetch specific real movies from TMDB
# Run with: mix run quick_real_movies.exs

Mix.Task.run("app.start")
import Ecto.Query

IO.puts("🎬 Fetching Specific Real Movies from TMDB")
IO.puts("=" <> String.duplicate("=", 60))

tmdb_api_key = "569d36799113067889ac91b76e5dc8f8"

# Popular movie IDs we want to fetch
movie_ids = [
  238,    # The Godfather
  680,    # Pulp Fiction  
  155,    # The Dark Knight
  550,    # Fight Club
  13,     # Forrest Gump
  122,    # The Lord of the Rings: The Return of the King
  424,    # Schindler's List
  389,    # 12 Angry Men
  129,    # Spirited Away
  120,    # The Lord of the Rings: The Fellowship of the Ring
  539,    # Psycho
  807,    # Se7en
  496243, # Parasite
  872585, # Oppenheimer
  27205,  # Inception
  346698, # Barbie
  103,    # Taxi Driver
  274,    # The Silence of the Lambs
  240,    # The Godfather Part II
  121,    # The Lord of the Rings: The Two Towers
  329,    # Jurassic Park
  598,    # City of God
  11,     # Star Wars
  348,    # Alien
  1891,   # The Empire Strikes Back
  637,    # Life Is Beautiful
  497,    # The Green Mile
  862,    # Toy Story
  599,    # Il Postino
  157336, # Interstellar
  12,     # Finding Nemo
  105,    # Back to the Future
  429,    # The Good, the Bad and the Ugly
  14,     # Raiders of the Lost Ark
  165,    # Back to the Future Part II
  769,    # GoodFellas
  15,     # Citizen Kane
  73,     # American Graffiti
  289,    # Casablanca
  207,    # Dead Poets Society
  255,    # Singin' in the Rain
  423,    # The Piano
  423,    # Some Like It Hot
  73,     # The Apartment
  562,    # Sunset Boulevard
  755,    # The Bridge on the River Kwai
  85,     # Raiders of the Lost Ark
  489,    # The Maltese Falcon
  129,    # My Fair Lady
  637,    # Ben-Hur
  103,    # Lawrence of Arabia
  379,    # Dr. Strangelove
  539,    # North by Northwest
  769,    # Vertigo
  103,    # The Treasure of the Sierra Madre
  378064, # A Silent Voice
  372058, # Your Name
  545611, # Everything Everywhere All at Once
  634649, # Spider-Man: No Way Home
  299534, # Avengers: Endgame
  140607, # Star Wars: The Force Awakens
  181808, # Star Wars: The Last Jedi
  762441, # A Quiet Place Part II
  438631, # Dune
  475557, # Joker
  420818, # The Lion King (2019)
  315635, # Spider-Man: Homecoming
  284054, # Black Panther
  566525, # Shang-Chi and the Legend of the Ten Rings
  508943, # Luca
  618344, # Encanto
  508947, # Turning Red
  354912, # Coco
  508442, # Roma
  515001, # Jojo Rabbit
  332562, # A Star Is Born
  490132, # Green Book
  313369, # La La Land
  376867, # Moonlight
  419704, # Get Out
  391713, # Lady Bird
  399055, # The Shape of Water
  383498, # Three Billboards Outside Ebbing, Missouri
  530915, # 1917
  466272, # Once Upon a Time in Hollywood
  398978, # The Irishman
  399174, # The Post
  472033, # Vice
  424694, # Bohemian Rhapsody
  341013, # Call Me by Your Name
  400535, # Phantom Thread
  334533, # Manchester by the Sea
  360814, # Fences
  381284, # Hidden Figures
  324786, # Hacksaw Ridge
  335984, # Blade Runner 2049
  49026,  # The Dark Knight Rises
  76341,  # Mad Max: Fury Road
  329865, # Arrival
  359724, # Ford v Ferrari
  331482, # Little Women
  546554, # Knives Out
]

# Clear sample movies first
{deleted_count, _} = Cinegraph.Repo.delete_all(
  from m in Cinegraph.Movies.Movie, 
  where: like(m.title, "Sample Movie%")
)
IO.puts("🗑️  Deleted #{deleted_count} sample movies")

# Helper function to parse dates
parse_date = fn
  nil -> nil
  "" -> nil
  date_string ->
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
end

# Function to fetch and create movie
fetch_and_create_movie = fn movie_id, api_key ->
  url = "https://api.themoviedb.org/3/movie/#{movie_id}?api_key=#{api_key}"
  
  case :httpc.request(:get, {String.to_charlist(url), []}, [], []) do
    {:ok, {{_, 200, _}, _, body}} ->
      case Jason.decode(List.to_string(body)) do
        {:ok, movie_data} ->
          # Check if movie already exists
          existing = Cinegraph.Repo.get_by(Cinegraph.Movies.Movie, tmdb_id: movie_data["id"])
          
          if existing do
            {:ok, :already_exists}
          else
            attrs = %{
              tmdb_id: movie_data["id"],
              title: movie_data["title"],
              original_title: movie_data["original_title"],
              release_date: parse_date.(movie_data["release_date"]),
              runtime: movie_data["runtime"],
              overview: movie_data["overview"],
              tagline: movie_data["tagline"],
              original_language: movie_data["original_language"],
              budget: movie_data["budget"],
              revenue: movie_data["revenue"],
              status: movie_data["status"] || "Released",
              poster_path: movie_data["poster_path"],
              backdrop_path: movie_data["backdrop_path"],
              adult: movie_data["adult"] || false,
              homepage: movie_data["homepage"],
              imdb_id: movie_data["imdb_id"],
              genre_ids: (movie_data["genres"] || []) |> Enum.map(& &1["id"]),
              production_countries: (movie_data["production_countries"] || []) |> Enum.map(& &1["iso_3166_1"]),
              spoken_languages: (movie_data["spoken_languages"] || []) |> Enum.map(& &1["iso_639_1"]),
              tmdb_raw_data: movie_data,
              tmdb_fetched_at: DateTime.utc_now()
            }
            
            Cinegraph.Movies.create_movie(attrs)
          end
        {:error, error} ->
          {:error, {:json_decode, error}}
      end
    {:error, error} ->
      {:error, {:http_request, error}}
  end
end

# Fetch movies
IO.puts("🎯 Fetching #{length(movie_ids)} specific movies...")

{success_count, error_count, exists_count} = 
  movie_ids
  |> Enum.with_index()
  |> Enum.reduce({0, 0, 0}, fn {movie_id, index}, {success, errors, exists} ->
    IO.write("#{index + 1}/#{length(movie_ids)}: Movie #{movie_id}...")
    
    result = case fetch_and_create_movie.(movie_id, tmdb_api_key) do
      {:ok, :already_exists} ->
        IO.puts(" (exists)")
        {success, errors, exists + 1}
      {:ok, _movie} ->
        IO.puts(" ✅")
        {success + 1, errors, exists}
      {:error, error} ->
        IO.puts(" ❌ #{inspect(error)}")
        {success, errors + 1, exists}
    end
    
    # Rate limiting
    :timer.sleep(50)
    
    result
  end)

IO.puts("\n📊 Results:")
IO.puts("✅ New movies added: #{success_count}")
IO.puts("♻️  Already existed: #{exists_count}")
IO.puts("❌ Errors: #{error_count}")

# Seed authorities if needed
authorities_count = Cinegraph.Repo.aggregate(Cinegraph.Cultural.Authority, :count)
if authorities_count == 0 do
  IO.puts("🏛️ Seeding cultural authorities...")
  Cinegraph.Cultural.seed_authorities()
  IO.puts("✅ Authorities seeded")
end

# Add movies to cultural lists
IO.puts("🎭 Adding movies to cultural lists...")

movies = Cinegraph.Movies.list_movies() |> Enum.take(30)
afi_list = Cinegraph.Repo.get_by(Cinegraph.Cultural.CuratedList, name: "AFI's 100 Years...100 Movies")

if afi_list && length(movies) > 0 do
  movies
  |> Enum.take(20)
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

# Calculate CRI scores
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

IO.puts("\n🎉 Real Movie Database Complete!")
IO.puts("Movies: #{final_count}")
IO.puts("Authorities: #{authorities}")
IO.puts("Lists: #{lists}")
IO.puts("CRI Scores: #{cri_scores}")
IO.puts("\n🌐 Visit: http://localhost:4000/movies")