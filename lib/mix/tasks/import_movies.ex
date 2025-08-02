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
  
  ## Modular System Options (automatically uses Oban when available)
  
      # Import using Oban job queue (default when Oban is loaded)
      mix import_movies --pages 5
      
      # Force immediate processing without queue
      mix import_movies --pages 5 --queue false
      
      # Import with specific APIs only
      mix import_movies --pages 5 --apis tmdb
      mix import_movies --pages 5 --apis tmdb,omdb
      
      # Enrich with a specific API
      mix import_movies --enrich --api omdb
      mix import_movies --enrich --api tmdb
      
      # Import specific movies with selected APIs
      mix import_movies --ids 550,551 --apis tmdb
  """
  
  def run(args) do
    {opts, _, _} = OptionParser.parse(args,
      switches: [
        pages: :integer,
        ids: :string,
        enrich: :boolean,
        fresh: :boolean,
        reset: :boolean,
        verbose: :boolean,
        queue: :boolean,
        api: :string,
        apis: :string
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
    
    # Determine if we should use the new modular system
    # Default to using queue when Oban is available
    use_queue = if opts[:queue] == false, do: false, else: use_new_system?()
    
    cond do
      opts[:fresh] || opts[:reset] ->
        clear_data()
        if use_new_system?() do
          import_pages_modular(opts[:pages] || 5, opts)
        else
          import_pages(opts[:pages] || 5, opts[:verbose] || false)
        end
        
      opts[:enrich] ->
        api = opts[:api] || "omdb"
        Mix.shell().info("Enriching existing movies with #{String.upcase(api)} data...")
        
        if use_new_system?() do
          Cinegraph.MovieImporter.reprocess_missing_api_data(api, queue: use_queue)
        else
          ComprehensiveMovieImporter.enrich_existing_movies_with_omdb()
        end
        
      opts[:ids] ->
        ids = opts[:ids]
        |> String.split(",")
        |> Enum.map(&String.to_integer/1)
        
        Mix.shell().info("Importing specific movies: #{inspect(ids)}")
        
        if use_new_system?() do
          apis = parse_apis(opts[:apis])
          Enum.each(ids, fn tmdb_id ->
            Cinegraph.MovieImporter.import_movie_from_tmdb(tmdb_id, 
              apis: apis, 
              queue: use_queue
            )
          end)
        else
          ComprehensiveMovieImporter.import_specific_movies(ids)
        end
        
      true ->
        # Default to importing 5 pages = 100 movies
        if use_new_system?() do
          import_pages_modular(opts[:pages] || 5, opts)
        else
          import_pages(opts[:pages] || 5, opts[:verbose] || false)
        end
    end
    
    # Print summary after import
    print_summary()
  end
  
  # Check if we should use the new modular system
  defp use_new_system? do
    # For now, check if Oban is configured
    # In the future, this could be a config option
    Code.ensure_loaded?(Oban)
  end
  
  defp parse_apis(nil), do: ["tmdb", "omdb"]
  defp parse_apis(apis_string) do
    apis_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
  end
  
  defp import_pages_modular(pages, opts) do
    total_movies = pages * 20
    apis = parse_apis(opts[:apis])
    use_queue = opts[:queue] || false
    
    Mix.shell().info("Importing #{pages} pages of popular movies (~#{total_movies} movies)...")
    Mix.shell().info("Using modular system with APIs: #{inspect(apis)}")
    Mix.shell().info("Queue mode: #{use_queue}")
    
    start_time = System.monotonic_time(:second)
    
    # Get popular movies from TMDb
    movie_ids = 1..pages
    |> Enum.flat_map(fn page ->
      case Cinegraph.Services.TMDb.get_popular_movies(page: page) do
        {:ok, %{"results" => movies}} ->
          Enum.map(movies, & &1["id"])
        {:error, reason} ->
          Mix.shell().error("Failed to fetch page #{page}: #{inspect(reason)}")
          []
      end
    end)
    
    Mix.shell().info("Found #{length(movie_ids)} movies to import")
    
    # Import each movie using the modular system
    Enum.with_index(movie_ids, 1)
    |> Enum.each(fn {tmdb_id, index} ->
      if opts[:verbose] do
        Mix.shell().info("[#{index}/#{length(movie_ids)}] Importing TMDb ID #{tmdb_id}...")
      end
      
      Cinegraph.MovieImporter.import_movie_from_tmdb(tmdb_id, 
        apis: apis,
        queue: use_queue
      )
      
      # Small delay to avoid overwhelming the APIs
      unless use_queue, do: Process.sleep(100)
    end)
    
    elapsed = System.monotonic_time(:second) - start_time
    
    if use_queue do
      Mix.shell().info("✓ Queued #{length(movie_ids)} movies for import in #{elapsed}s")
      Mix.shell().info("Jobs will be processed by Oban workers")
    else
      Mix.shell().info("✓ Import completed in #{elapsed}s")
    end
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