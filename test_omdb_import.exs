# Test script to verify OMDb integration
# Run with: mix run test_omdb_import.exs

alias Cinegraph.{Repo, Movies}
alias Cinegraph.Movies.Movie
alias Cinegraph.Services.OMDb
alias Cinegraph.Importers.ComprehensiveMovieImporter

import Ecto.Query
require Logger

# Test with a few well-known movies
test_movies = [
  {111161, "The Shawshank Redemption", "tt0111161"},
  {550, "Fight Club", "tt0137523"},
  {27205, "Inception", "tt1375666"}
]

Logger.info("Testing OMDb integration...")

# Ensure OMDb source exists
omdb_source = OMDb.Transformer.get_or_create_source!()
Logger.info("OMDb source ID: #{omdb_source.id}")

# Test each movie
Enum.each(test_movies, fn {tmdb_id, title, _expected_imdb_id} ->
  Logger.info("\n=== Testing #{title} ===")
  
  # Import from TMDb first
  case ComprehensiveMovieImporter.import_single_movie(tmdb_id, omdb_source) do
    {:ok, movie} ->
      Logger.info("✓ Movie imported: #{movie.title}")
      Logger.info("  TMDb ID: #{movie.tmdb_id}")
      Logger.info("  IMDb ID: #{movie.imdb_id}")
      
      # Check if OMDb data was stored
      ratings = movie
      |> Ecto.assoc(:external_ratings)
      |> Repo.all()
      |> Repo.preload(:source)
      |> Enum.filter(& &1.source.name == "OMDb")
      
      Logger.info("  OMDb ratings stored: #{length(ratings)}")
      
      Enum.each(ratings, fn rating ->
        Logger.info("    - #{rating.rating_type}: #{rating.value}/#{rating.scale_max}")
        if rating.metadata["source_name"] do
          Logger.info("      Source: #{rating.metadata["source_name"]}")
        end
        if rating.metadata["consensus"] do
          Logger.info("      Consensus: #{String.slice(rating.metadata["consensus"], 0..50)}...")
        end
      end)
      
      # Check awards
      if awards = movie.external_ids["omdb_awards"] do
        Logger.info("  Awards: #{awards["raw_text"]}")
        Logger.info("    Oscar wins: #{awards["oscar_wins"]}")
        Logger.info("    Total wins: #{awards["total_wins"]}")
      end
      
    {:error, reason} ->
      Logger.error("✗ Failed to import #{title}: #{inspect(reason)}")
  end
  
  # Wait between requests
  Process.sleep(1500)
end)

Logger.info("\n=== Test complete! ===")

# Show summary
total_movies = Repo.one(from m in Movie, select: count(m.id))
movies_with_imdb = Repo.one(from m in Movie, where: not is_nil(m.imdb_id), select: count(m.id))
total_ratings = Repo.one(from r in Cinegraph.ExternalSources.Rating, select: count(r.id))

Logger.info("\nDatabase summary:")
Logger.info("  Total movies: #{total_movies}")
Logger.info("  Movies with IMDb ID: #{movies_with_imdb}")
Logger.info("  Total ratings: #{total_ratings}")