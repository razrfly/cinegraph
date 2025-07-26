defmodule Mix.Tasks.ImportMovies do
  use Mix.Task
  
  import Ecto.Query
  alias Cinegraph.Importers.ComprehensiveMovieImporter
  require Logger
  
  @shortdoc "Import 100+ movies from TMDb and enrich with OMDb data"
  
  @moduledoc """
  Import movies from TMDb and enrich with OMDb data. Default imports 100+ movies.
  
  ## Usage
  
      # Import 100+ popular movies (default - 5 pages of 20 movies each)
      mix import_movies
      
      # Import specific number of pages (100+ movies recommended)
      mix import_movies --pages 10
      
      # Import specific TMDb IDs
      mix import_movies --ids 550,551,552
      
      # Enrich existing movies with OMDb data
      mix import_movies --enrich
      
      # Fresh start - clear all data first and import 100+ movies
      mix import_movies --fresh
      
      # Fresh start with custom page count
      mix import_movies --fresh --pages 10
      
      # Complete reset - drop, create, migrate, then import
      mix import_movies --reset --pages 10
      
      # Show progress during import
      mix import_movies --pages 10 --verbose
  """
  
  def run(args) do
    {opts, _, _} = OptionParser.parse(args,
      switches: [
        pages: :integer,
        ids: :string,
        enrich: :boolean,
        fresh: :boolean,
        reset: :boolean,
        verbose: :boolean
      ]
    )
    
    # Configure logging based on verbose flag
    if opts[:verbose] do
      Logger.configure(level: :info)
    else
      Logger.configure(level: :warning)
    end
    
    # Handle complete reset first
    if opts[:reset] do
      reset_database()
    end
    
    # Start app after potential reset
    Mix.Task.run("app.start")
    
    cond do
      opts[:fresh] || opts[:reset] ->
        clear_data()
        import_pages(opts[:pages] || 5, opts[:verbose] || false)
        
      opts[:enrich] ->
        Mix.shell().info("Enriching existing movies with OMDb data...")
        ComprehensiveMovieImporter.enrich_existing_movies_with_omdb()
        
      opts[:ids] ->
        ids = opts[:ids]
        |> String.split(",")
        |> Enum.map(&String.to_integer/1)
        
        Mix.shell().info("Importing specific movies: #{inspect(ids)}")
        ComprehensiveMovieImporter.import_specific_movies(ids)
        
      true ->
        # Default to importing 5 pages = 100 movies
        import_pages(opts[:pages] || 5, opts[:verbose] || false)
    end
    
    # Print summary after import
    print_summary()
  end
  
  defp import_pages(pages, verbose) do
    total_movies = pages * 20
    Mix.shell().info("Importing #{pages} pages of popular movies (~#{total_movies} movies)...")
    Mix.shell().info("Each movie will be enriched with both TMDb and OMDb data...")
    
    start_time = System.monotonic_time(:second)
    
    # Import with progress tracking if verbose
    if verbose do
      import_with_progress(pages)
    else
      ComprehensiveMovieImporter.import_popular_movies(pages)
    end
    
    elapsed = System.monotonic_time(:second) - start_time
    minutes = div(elapsed, 60)
    seconds = rem(elapsed, 60)
    Mix.shell().info("\nImport completed in #{minutes}m #{seconds}s")
  end
  
  defp import_with_progress(pages) do
    # This is a placeholder - the actual progress tracking would need
    # to be implemented in ComprehensiveMovieImporter
    Mix.shell().info("Progress tracking enabled...")
    ComprehensiveMovieImporter.import_popular_movies(pages)
  end
  
  defp clear_data do
    Mix.shell().info("Clearing existing data...")
    
    # Clear in order to respect foreign keys - only tables that exist in clean schema
    tables = [
      "cri_scores",
      "external_ratings",
      "external_recommendations",
      "movie_list_items",
      "movie_credits",
      "movie_keywords",
      "movie_production_companies",
      "movie_videos",
      "movie_release_dates",
      "movies",
      "curated_lists",
      "cultural_authorities",
      "people",
      "genres",
      "collections",
      "production_companies",
      "keywords",
      "external_sources"
    ]
    
    Enum.each(tables, fn table ->
      try do
        Cinegraph.Repo.query!("TRUNCATE #{table} CASCADE")
        Mix.shell().info("  ✓ Cleared #{table}")
      rescue
        e ->
          Mix.shell().error("  ✗ Failed to clear #{table}: #{inspect(e)}")
      end
    end)
    
    Mix.shell().info("Data cleared!")
  end
  
  defp reset_database do
    Mix.shell().info("Performing complete database reset...")
    
    Mix.shell().info("Dropping database...")
    Mix.Task.run("ecto.drop", ["--quiet"])
    
    Mix.shell().info("Creating database...")
    Mix.Task.run("ecto.create", ["--quiet"])
    
    Mix.shell().info("Running migrations...")
    Mix.Task.run("ecto.migrate", ["--quiet"])
    
    Mix.shell().info("Database reset complete!")
  end
  
  defp print_summary do
    Mix.shell().info("\n📊 Import Summary:")
    
    try do
      movies = Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count)
      keywords = Cinegraph.Repo.aggregate(Cinegraph.Movies.Keyword, :count)
      videos = Cinegraph.Repo.aggregate(Cinegraph.Movies.MovieVideo, :count)
      credits = Cinegraph.Repo.aggregate(Cinegraph.Movies.Credit, :count)
      people = Cinegraph.Repo.aggregate(Cinegraph.Movies.Person, :count)
      ratings = Cinegraph.Repo.aggregate(Cinegraph.ExternalSources.Rating, :count)
      
      Mix.shell().info("  Movies: #{movies}")
      Mix.shell().info("  People: #{people}")
      Mix.shell().info("  Keywords: #{keywords}")
      Mix.shell().info("  Videos: #{videos}")
      Mix.shell().info("  Credits: #{credits}")
      Mix.shell().info("  External Ratings: #{ratings}")
      
      # Show some sample movies
      sample_movies = 
        Cinegraph.Repo.all(
          from m in Cinegraph.Movies.Movie,
          order_by: [desc: m.popularity],
          limit: 5,
          select: {m.id, m.title}
        )
      
      if length(sample_movies) > 0 do
        Mix.shell().info("\n  Sample movies (by popularity):")
        Enum.each(sample_movies, fn {id, title} ->
          Mix.shell().info("    - [#{id}] #{title}")
        end)
      end
    rescue
      _ ->
        Mix.shell().error("  Unable to query database")
    end
  end
end