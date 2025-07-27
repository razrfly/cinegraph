alias Cinegraph.Repo
alias Cinegraph.Movies.Movie
import Ecto.Query

# Get a sample movie with all associations
movie = Movie 
  |> where([m], not is_nil(m.omdb_data) and not is_nil(m.tmdb_data))
  |> preload([:genres, :production_countries, :spoken_languages, :keywords, :production_companies, 
             :movie_videos, :movie_release_dates, :movie_credits, :external_ratings])
  |> limit(1)
  |> Repo.one!()

IO.puts("=== AUDITING MOVIE: #{movie.title} ===\n")

# Fields we're storing directly in movies table
stored_fields = [
  :tmdb_id, :imdb_id, :title, :original_title, :release_date, :runtime, :overview, 
  :tagline, :original_language, :budget, :revenue, :status, :adult, :homepage, 
  :vote_average, :vote_count, :popularity, :collection_id, :poster_path, :backdrop_path,
  :awards_text, :box_office_domestic, :origin_country, :tmdb_data, :omdb_data
]

IO.puts("=== FIELDS STORED IN MOVIES TABLE ===")
Enum.each(stored_fields, fn field ->
  value = Map.get(movie, field)
  if value != nil && value != [] && value != "" do
    IO.puts("✓ #{field}: #{inspect(value, limit: 50)}")
  else
    IO.puts("✗ #{field}: nil/empty")
  end
end)

# Analyze TMDb JSON
IO.puts("\n=== TMDB JSON ANALYSIS ===")
IO.puts("Total TMDb fields: #{map_size(movie.tmdb_data)}")
tmdb_keys = Map.keys(movie.tmdb_data) |> Enum.sort()
IO.puts("TMDb fields: #{inspect(tmdb_keys)}")

# Check what TMDb fields we're NOT using
tmdb_extracted = [
  "id", "imdb_id", "title", "original_title", "release_date", "runtime", "overview",
  "tagline", "original_language", "budget", "revenue", "status", "adult", "homepage",
  "vote_average", "vote_count", "popularity", "belongs_to_collection", "poster_path",
  "backdrop_path", "origin_country", "genres", "production_countries", "spoken_languages",
  "keywords", "production_companies", "videos", "release_dates", "credits",
  "recommendations", "similar", "reviews", "lists"
]

tmdb_unused = tmdb_keys -- tmdb_extracted
IO.puts("\nTMDb fields we're NOT extracting:")
Enum.each(tmdb_unused, fn field ->
  IO.puts("  - #{field}: #{inspect(Map.get(movie.tmdb_data, field), limit: 100)}")
end)

# Analyze OMDb JSON
IO.puts("\n=== OMDB JSON ANALYSIS ===")
IO.puts("Total OMDb fields: #{map_size(movie.omdb_data)}")
omdb_keys = Map.keys(movie.omdb_data) |> Enum.sort()
IO.puts("OMDb fields: #{inspect(omdb_keys)}")

# Check what OMDb fields we're NOT using
omdb_extracted = [
  "Awards", "BoxOffice", "imdbRating", "imdbVotes", "Metascore",
  "Ratings" # Ratings array contains Rotten Tomatoes scores
]

omdb_unused = omdb_keys -- omdb_extracted
IO.puts("\nOMDb fields we're NOT extracting:")
Enum.each(omdb_unused, fn field ->
  value = Map.get(movie.omdb_data, field)
  if value != "N/A" do
    IO.puts("  - #{field}: #{inspect(value, limit: 100)}")
  end
end)

# Check associations
IO.puts("\n=== ASSOCIATIONS CHECK ===")
IO.puts("Genres: #{length(movie.genres)} - #{Enum.map(movie.genres, & &1.name) |> Enum.join(", ")}")
IO.puts("Production Countries: #{length(movie.production_countries)}")
IO.puts("Spoken Languages: #{length(movie.spoken_languages)}")
IO.puts("Keywords: #{length(movie.keywords)}")
IO.puts("Production Companies: #{length(movie.production_companies)}")
IO.puts("Videos: #{length(movie.movie_videos)}")
IO.puts("Release Dates: #{length(movie.movie_release_dates)}")
IO.puts("Credits: #{length(movie.movie_credits)}")
IO.puts("External Ratings: #{length(movie.external_ratings)}")

# Check for unused tables in the database
IO.puts("\n=== DATABASE TABLES AUDIT ===")
{:ok, %{rows: tables}} = Repo.query("""
  SELECT tablename 
  FROM pg_tables 
  WHERE schemaname = 'public' 
  AND tablename NOT IN ('schema_migrations')
  ORDER BY tablename
""")

expected_tables = [
  "collections", "external_ratings", "external_recommendations", "external_sources",
  "genres", "keywords", "movie_credits", "movie_genres", "movie_keywords",
  "movie_production_companies", "movie_production_countries", "movie_release_dates",
  "movie_spoken_languages", "movie_videos", "movies", "people", 
  "production_companies", "production_countries", "spoken_languages"
]

IO.puts("\nCurrent tables in database:")
Enum.each(tables, fn [table] ->
  if table in expected_tables do
    IO.puts("✓ #{table}")
  else
    IO.puts("✗ #{table} (UNEXPECTED/UNUSED)")
  end
end)

# Check for empty tables
IO.puts("\n=== EMPTY TABLES CHECK ===")
Enum.each(tables, fn [table] ->
  {:ok, %{rows: [[count]]}} = Repo.query("SELECT COUNT(*) FROM #{table}")
  if count == 0 do
    IO.puts("⚠️  #{table} is EMPTY (#{count} records)")
  end
end)

# Summary of potentially useful fields not being stored
IO.puts("\n=== POTENTIALLY USEFUL FIELDS NOT BEING EXTRACTED ===")

IO.puts("\nFrom TMDb:")
IO.puts("1. video (boolean) - indicates if videos are available")
IO.puts("2. alternative_titles - different titles in various regions")
IO.puts("3. images - additional poster/backdrop images")
IO.puts("4. translations - overview in different languages")
IO.puts("5. watch_providers - streaming availability")
IO.puts("6. external_ids - links to other databases")

IO.puts("\nFrom OMDb:")
IO.puts("1. Plot - detailed plot description")
IO.puts("2. Director - director name(s)")
IO.puts("3. Writer - writer name(s)")
IO.puts("4. Actors - main cast list")
IO.puts("5. Genre - genre as string (we use TMDb's structured data)")
IO.puts("6. Country - production countries as string")
IO.puts("7. Language - languages as string")
IO.puts("8. DVD - DVD release date")
IO.puts("9. Production - production company names")
IO.puts("10. Website - movie website (different from homepage)")

# Check external_recommendations usage
recs_count = Repo.one(from(er in "external_recommendations", select: count(er.id)))
IO.puts("\n=== RECOMMENDATIONS CHECK ===")
IO.puts("External recommendations stored: #{recs_count}")