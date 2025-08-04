defmodule Cinegraph.Cultural.CanonicalImporter do
  @moduledoc """
  Imports canonical movie lists and creates movie relationships.
  Follows the same pattern as OscarImporter for consistency.
  """
  
  alias Cinegraph.{Repo, Movies}
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Scrapers.ImdbCanonicalScraper
  alias Cinegraph.Workers.TMDbDetailsWorker
  require Logger
  
  @doc """
  Import a single canonical movie list and create/update movies.
  
  ## Parameters
  - `list_id`: The IMDb list ID (e.g., "ls024863935")
  - `source_key`: Internal key for this canonical source (e.g., "1001_movies")
  - `list_name`: Human-readable name for the list
  - `options`: Import options (create_movies: true/false, create_partial: true/false)
  - `metadata`: Optional additional metadata to store with each movie
  
  ## Examples
      # Import 1001 Movies list
      import_canonical_list("ls024863935", "1001_movies", "1001 Movies You Must See Before You Die")
      
      # Import with custom metadata
      import_canonical_list("ls123456789", "sight_sound", "Sight & Sound Greatest Films", [], %{"edition" => "2022"})
  """
  def import_canonical_list(list_id, source_key, list_name, options \\ [], metadata \\ %{}) do
    Logger.info("Processing canonical list: #{list_name}")
    Logger.info("List ID: #{list_id}, Source Key: #{source_key}")
    
    # First, determine how many pages we need to process
    case ImdbCanonicalScraper.get_total_pages(list_id) do
      {:ok, total_pages} ->
        Logger.info("List has #{total_pages} page(s) to process")
        
        # Process page by page to avoid timeouts
        results = 
          1..total_pages
          |> Enum.reduce([], fn page, acc ->
            Logger.info("Processing page #{page} of #{total_pages}...")
            
            case ImdbCanonicalScraper.fetch_single_page(list_id, page) do
              {:ok, movie_data} ->
                Logger.info("Found #{length(movie_data)} movies on page #{page}")
                
                # Process each movie on this page
                page_results = 
                  movie_data
                  |> Enum.map(fn movie ->
                    # Adjust position for pagination
                    movie = %{movie | position: (page - 1) * 250 + movie.position}
                    process_canonical_movie(movie, source_key, list_name, options, metadata)
                  end)
                
                acc ++ page_results
                
              {:error, reason} ->
                Logger.error("Failed to fetch page #{page}: #{inspect(reason)}")
                acc
            end
          end)
        
        %{
          list_id: list_id,
          source_key: source_key,
          list_name: list_name,
          movies_created: Enum.count(results, & &1.action == :created),
          movies_updated: Enum.count(results, & &1.action == :updated),
          movies_queued: Enum.count(results, & &1.action == :queued),
          movies_skipped: Enum.count(results, & &1.action == :skipped),
          total_movies: Enum.count(results),
          results: results
        }
        
      {:error, reason} ->
        Logger.error("Failed to determine pages for #{list_name}: #{inspect(reason)}")
        %{
          list_id: list_id,
          source_key: source_key,
          list_name: list_name,
          error: reason,
          movies_created: 0,
          movies_updated: 0,
          movies_queued: 0,
          movies_skipped: 0,
          total_movies: 0
        }
    end
  end
  
  @doc """
  Import multiple canonical lists from a configuration.
  
  ## Example
      lists = [
        %{list_id: "ls024863935", source_key: "1001_movies", name: "1001 Movies You Must See Before You Die"},
        %{list_id: "ls123456789", source_key: "sight_sound", name: "Sight & Sound Greatest Films"}
      ]
      
      import_multiple_lists(lists)
  """
  def import_multiple_lists(list_configs, options \\ []) do
    Logger.info("Processing #{length(list_configs)} canonical lists...")
    
    results = 
      list_configs
      |> Enum.map(fn config ->
        list_id = config[:list_id] || config["list_id"]
        source_key = config[:source_key] || config["source_key"] 
        name = config[:name] || config["name"]
        metadata = config[:metadata] || config["metadata"] || %{}
        
        import_canonical_list(list_id, source_key, name, options, metadata)
      end)
      |> summarize_results()
    
    Logger.info("Import complete: #{inspect(results)}")
    results
  end
  
  @doc """
  Convenience function to import the 1001 Movies list.
  """
  def import_1001_movies(options \\ []) do
    import_canonical_list(
      "ls024863935", 
      "1001_movies", 
      "1001 Movies You Must See Before You Die",
      options,
      %{"edition" => "2024", "source_url" => "https://www.imdb.com/list/ls024863935/"}
    )
  end
  
  # Private functions following Oscar importer pattern
  
  defp process_canonical_movie(movie_data, source_key, list_name, options, base_metadata) do
    film_imdb_id = movie_data.imdb_id
    film_title = movie_data.title
    
    cond do
      # Skip if no IMDb ID
      is_nil(film_imdb_id) ->
        Logger.debug("Skipping #{film_title} - no IMDb ID")
        %{action: :skipped, reason: :no_imdb_id, title: film_title}
      
      # Process the movie
      true ->
        process_movie(film_imdb_id, movie_data, source_key, list_name, options, base_metadata)
    end
  end
  
  defp process_movie(imdb_id, movie_data, source_key, list_name, options, base_metadata) do
    # Check if movie exists
    existing_movie = Repo.get_by(Movie, imdb_id: imdb_id)
    
    if existing_movie do
      # Update existing movie with canonical data
      update_movie_canonical_data(existing_movie, movie_data, source_key, list_name, base_metadata)
    else
      # Create new movie via TMDbDetailsWorker (same pattern as Oscar import)
      create_movie_from_canonical(imdb_id, movie_data, source_key, list_name, options, base_metadata)
    end
  end
  
  defp update_movie_canonical_data(movie, movie_data, source_key, list_name, base_metadata) do
    Logger.info("Updating #{movie.title} with canonical data for #{source_key}")
    
    # Build canonical metadata
    canonical_metadata = build_canonical_metadata(movie_data, list_name, base_metadata)
    
    # Update canonical sources
    case Movies.update_canonical_sources(movie, source_key, canonical_metadata) do
      {:ok, _updated_movie} ->
        Logger.info("Successfully updated #{movie.title} as canonical in #{source_key}")
        %{action: :updated, movie_id: movie.id, title: movie.title, imdb_id: movie.imdb_id}
      
      {:error, changeset} ->
        Logger.error("Failed to update canonical sources for #{movie.title}: #{inspect(changeset.errors)}")
        %{action: :error, reason: changeset.errors, title: movie.title, imdb_id: movie.imdb_id}
    end
  end
  
  defp create_movie_from_canonical(imdb_id, movie_data, source_key, list_name, options, base_metadata) do
    if Keyword.get(options, :create_movies, true) do
      Logger.info("Queuing movie creation for #{movie_data.title} (#{imdb_id})")
      
      # Build canonical metadata
      canonical_metadata = build_canonical_metadata(movie_data, list_name, base_metadata)
      
      # Queue TMDbDetailsWorker job (same pattern as Oscar import)
      job_args = %{
        "imdb_id" => imdb_id,
        "source" => "canonical_import",
        "canonical_source" => %{
          "source_key" => source_key,
          "metadata" => canonical_metadata
        }
      }
      
      case TMDbDetailsWorker.new(job_args) |> Oban.insert() do
        {:ok, _job} ->
          Logger.info("Successfully queued creation for #{movie_data.title}")
          %{action: :queued, title: movie_data.title, imdb_id: imdb_id, source_key: source_key}
          
        {:error, reason} ->
          Logger.error("Failed to queue creation for #{movie_data.title}: #{inspect(reason)}")
          %{action: :error, reason: reason, title: movie_data.title, imdb_id: imdb_id}
      end
    else
      Logger.debug("Skipping movie creation for #{movie_data.title} - create_movies disabled")
      %{action: :skipped, reason: :create_disabled, title: movie_data.title, imdb_id: imdb_id}
    end
  end
  
  defp build_canonical_metadata(movie_data, list_name, base_metadata) do
    Map.merge(%{
      "included" => true,
      "scraped_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source_name" => list_name,
      "scraped_title" => movie_data.title,
      "scraped_year" => movie_data.year,
      "list_position" => movie_data.position
    }, base_metadata)
  end
  
  defp summarize_results(results) do
    Enum.reduce(results, %{
      total_lists: 0,
      total_movies: 0,
      movies_created: 0,
      movies_updated: 0,
      movies_queued: 0,
      movies_skipped: 0,
      errors: 0
    }, fn result, acc ->
      %{
        total_lists: acc.total_lists + 1,
        total_movies: acc.total_movies + (result.total_movies || 0),
        movies_created: acc.movies_created + (result.movies_created || 0),
        movies_updated: acc.movies_updated + (result.movies_updated || 0),
        movies_queued: acc.movies_queued + (result.movies_queued || 0),
        movies_skipped: acc.movies_skipped + (result.movies_skipped || 0),
        errors: acc.errors + if(result[:error], do: 1, else: 0)
      }
    end)
  end
  
  @doc """
  Get statistics about canonical movie imports.
  """
  def import_stats(source_keys \\ nil) do
    # If no source keys provided, check common ones
    sources_to_check = source_keys || ["1001_movies", "sight_sound", "criterion", "afi", "bfi"]
    
    # Count movies by canonical source
    source_counts = 
      sources_to_check
      |> Enum.map(fn source_key ->
        count = Movies.count_canonical_movies(source_key)
        {source_key, count}
      end)
      |> Enum.into(%{})
    
    # Count movies with any canonical source
    any_canonical = Movies.count_any_canonical_movies()
    
    %{
      by_source: source_counts,
      any_canonical: any_canonical,
      checked_sources: sources_to_check
    }
  end
end