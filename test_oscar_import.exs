# Test Oscar import functionality
# Run with: mix run test_oscar_import.exs

require Logger

# Load environment variables
case Dotenvy.source([".env"]) do
  {:ok, env} -> 
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)
  {:error, reason} -> 
    Logger.error("Failed to load .env: #{inspect(reason)}")
end

# Get current stats
Logger.info("=== Current Oscar Import Stats ===")
stats = Cinegraph.Cultural.OscarImporter.import_stats()
Logger.info(inspect(stats, pretty: true))

# Import just the 2023 ceremony as a test
ceremony = Cinegraph.Repo.get_by!(Cinegraph.Cultural.OscarCeremony, year: 2023)

Logger.info("\n=== Importing 2023 Oscar Ceremony ===")

# Run import with options
result = Cinegraph.Cultural.OscarImporter.import_ceremony(ceremony, [
  create_movies: true,
  queue_enrichment: false  # Don't queue jobs for this test
])

Logger.info("\nImport result:")
Logger.info(inspect(result, pretty: true))

# Check a specific movie
Logger.info("\n=== Checking Sample Movie ===")

case Cinegraph.Repo.get_by(Cinegraph.Movies.Movie, imdb_id: "tt6710474") do
  nil ->
    Logger.info("Movie not found - might need to be created")
  
  movie ->
    Logger.info("Found: #{movie.title}")
    Logger.info("IMDb ID: #{movie.imdb_id}")
    Logger.info("Import status: #{movie.import_status}")
    
    if movie.awards && movie.awards["oscar_nominations"] do
      Logger.info("Oscar nominations: #{length(movie.awards["oscar_nominations"])}")
      
      # Show first nomination
      first_nom = List.first(movie.awards["oscar_nominations"])
      if first_nom do
        Logger.info("  Category: #{first_nom["category"]}")
        Logger.info("  Winner: #{first_nom["winner"]}")
        Logger.info("  Nominees: #{first_nom["nominees"]}")
      end
    end
end

# Get new stats
Logger.info("\n=== Updated Oscar Import Stats ===")
new_stats = Cinegraph.Cultural.OscarImporter.import_stats()
Logger.info(inspect(new_stats, pretty: true))