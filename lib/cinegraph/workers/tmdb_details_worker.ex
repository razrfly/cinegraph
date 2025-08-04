defmodule Cinegraph.Workers.TMDbDetailsWorker do
  @moduledoc """
  Simplified details worker that doesn't use import progress tracking.
  """
  
  use Oban.Worker, 
    queue: :tmdb_details,
    max_attempts: 5,
    unique: [fields: [:args], keys: [:tmdb_id], period: 300]
    
  alias Cinegraph.{Repo, Movies}
  alias Cinegraph.Workers.{OMDbEnrichmentWorker, CollaborationWorker}
  alias Cinegraph.Imports.QualityFilter
  alias Cinegraph.Services.TMDb
  require Logger
  
  @impl Oban.Worker
  # Handle nested args format (legacy from broken OscarDiscoveryWorker)
  def perform(%Oban.Job{args: %{"args" => nested_args}} = job) do
    # Extract the nested args and call the correct function
    perform(%Oban.Job{job | args: nested_args})
  end
  
  # Handle IMDb ID lookup (e.g., from Oscar import)
  def perform(%Oban.Job{args: %{"imdb_id" => imdb_id} = args}) do
    Logger.info("Processing movie details for IMDb ID #{imdb_id}")
    
    # Check if movie already exists by IMDb ID
    case Repo.get_by(Movies.Movie, imdb_id: imdb_id) do
      nil ->
        # Look up TMDb ID from IMDb ID
        case TMDb.find_by_imdb_id(imdb_id) do
          {:ok, %{"movie_results" => [movie_data | _]}} ->
            # Found a match, process with TMDb ID but keep original args
            tmdb_id = movie_data["id"]
            Logger.info("Found TMDb ID #{tmdb_id} for IMDb ID #{imdb_id}")
            
            # Process the movie creation directly instead of recursive call
            process_tmdb_movie(tmdb_id, args)
            
          {:ok, %{"movie_results" => []}} ->
            Logger.warning("No TMDb match for IMDb ID #{imdb_id}")
            handle_no_tmdb_match(imdb_id, args)
            
          {:error, reason} ->
            Logger.error("TMDb API error for IMDb ID #{imdb_id}: #{inspect(reason)}")
            {:error, reason}
        end
        
      existing_movie ->
        Logger.info("Movie already exists for IMDb ID #{imdb_id}: #{existing_movie.title}")
        handle_post_creation_tasks(existing_movie.tmdb_id, args)
    end
  end
  
  def perform(%Oban.Job{args: %{"tmdb_id" => tmdb_id}} = job) do
    Logger.info("Processing movie details for TMDb ID #{tmdb_id}")
    process_tmdb_movie(tmdb_id, job.args)
  end
  
  defp process_tmdb_movie(tmdb_id, args) do
    # Skip if already exists
    if Movies.movie_exists?(tmdb_id) do
      Logger.info("Movie #{tmdb_id} already exists, skipping")
      handle_post_creation_tasks(tmdb_id, args)
    else
      # First, get basic movie info to evaluate quality
      case TMDb.get_movie(tmdb_id) do
        {:ok, movie_data} ->
          # Evaluate movie quality
          case QualityFilter.evaluate_movie(movie_data) do
            {:full_import, met_criteria} ->
              Logger.info("Movie #{movie_data["title"]} meets quality criteria: #{inspect(met_criteria)}")
              result = perform_full_import(tmdb_id, movie_data)
              handle_post_creation_tasks(tmdb_id, args)
              result
              
            {:soft_import, failed_criteria} ->
              Logger.info("Movie #{movie_data["title"]} failed quality criteria: #{inspect(failed_criteria)}")
              result = perform_soft_import(tmdb_id, movie_data)
              handle_post_creation_tasks(tmdb_id, args)
              result
          end
          
        {:error, reason} ->
          Logger.error("Failed to fetch movie #{tmdb_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
  
  defp perform_full_import(tmdb_id, _basic_data) do
    # Fetch and store comprehensive movie data with all relationships
    case Movies.fetch_and_store_movie_comprehensive(tmdb_id) do
      {:ok, movie} ->
        Logger.info("Successfully fully imported movie: #{movie.title} (#{movie.tmdb_id})")
        
        # Queue OMDb enrichment if we have an IMDb ID
        if movie.imdb_id do
          queue_omdb_enrichment(movie)
        else
          Logger.info("No IMDb ID for movie #{movie.title}, skipping OMDb enrichment")
        end
        
        # Queue collaboration building
        queue_collaboration_building(movie)
        
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to import movie #{tmdb_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp perform_soft_import(tmdb_id, movie_data) do
    # Create minimal movie record with basic data only
    case Movies.create_soft_import_movie(movie_data) do
      {:ok, movie} ->
        Logger.info("Successfully soft imported movie: #{movie.title} (#{movie.tmdb_id})")
        
        # Track the soft import for analytics
        track_soft_import(movie, movie_data)
        
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to soft import movie #{tmdb_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp queue_omdb_enrichment(movie) do
    %{
      "movie_id" => movie.id,
      "imdb_id" => movie.imdb_id,
      "title" => movie.title
    }
    |> OMDbEnrichmentWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _} ->
        Logger.info("Queued OMDb enrichment for #{movie.title}")
        :ok
      {:error, reason} ->
        Logger.error("Failed to queue OMDb enrichment: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp queue_collaboration_building(movie) do
    %{
      "movie_id" => movie.id
    }
    |> CollaborationWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _} ->
        Logger.info("Queued collaboration building for #{movie.title}")
        :ok
      {:error, reason} ->
        Logger.warning("Failed to queue collaboration building: #{inspect(reason)}")
        # Not critical, so we don't fail the import
        :ok
    end
  end
  
  defp track_soft_import(movie, movie_data) do
    # Track why this movie was soft imported
    analysis = QualityFilter.analyze_movie_failure(movie_data)
    
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:skipped_import, %Cinegraph.Imports.SkippedImport{
      tmdb_id: movie.tmdb_id,
      title: movie.title,
      reason: "quality_criteria",
      criteria_failed: analysis
    })
    |> Cinegraph.Repo.transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, _, _, _} -> 
        Logger.warning("Failed to track soft import for movie #{movie.id}")
        :ok
    end
  end
  
  defp handle_post_creation_tasks(tmdb_id, args) do
    # Handle any post-creation tasks for movies
    cond do
      # Oscar import - create nominations
      args["source"] == "oscar_import" && args["metadata"] ->
        metadata = args["metadata"]
        if metadata["ceremony_year"] && metadata["category"] do
          Logger.info("Creating Oscar nomination for movie with TMDb ID #{tmdb_id}")
          create_oscar_nomination(tmdb_id, metadata)
        else
          Logger.error("Invalid Oscar metadata: missing ceremony_year or category")
        end
      
      # Canonical import - mark as canonical source  
      args["source"] == "canonical_import" && args["canonical_source"] ->
        canonical_source = args["canonical_source"]
        source_key = canonical_source["source_key"]
        metadata = canonical_source["metadata"]
        
        Logger.info("Marking movie with TMDb ID #{tmdb_id} as canonical in #{source_key}")
        mark_movie_canonical(tmdb_id, source_key, metadata)
      
      true ->
        # No special post-processing needed
        :ok
    end
    
    :ok
  end
  
  defp create_oscar_nomination(tmdb_id, metadata) do
    # Find the movie by TMDb ID
    case Repo.get_by(Movies.Movie, tmdb_id: tmdb_id) do
      nil ->
        Logger.error("Movie with TMDb ID #{tmdb_id} not found for Oscar nomination")
        
      movie ->
        # Find the ceremony and category
        ceremony_year = metadata["ceremony_year"]
        category_name = metadata["category"]
        
        ceremony = Repo.get_by(Cinegraph.Cultural.OscarCeremony, year: ceremony_year)
        category = Repo.get_by(Cinegraph.Cultural.OscarCategory, name: category_name)
        
        if ceremony && category do
          # Use insert with on_conflict option for idempotent operation
          attrs = %{
            ceremony_id: ceremony.id,
            category_id: category.id,
            movie_id: movie.id,
            person_id: nil,
            won: metadata["winner"] || false,
            details: %{
              "nominee_names" => metadata["film_title"],
              "person_imdb_ids" => []
            }
          }

          %Cinegraph.Cultural.OscarNomination{}
          |> Cinegraph.Cultural.OscarNomination.changeset(attrs)
          |> Repo.insert(
            on_conflict: :nothing,
            conflict_target: [:ceremony_id, :category_id, :movie_id]
          )
          |> case do
            {:ok, _} ->
              Logger.info("Created Oscar nomination for #{movie.title} in #{category_name}")
            {:error, changeset} ->
              Logger.error("Failed to create Oscar nomination: #{inspect(changeset.errors)}")
          end
        else
          Logger.error("Ceremony (#{ceremony_year}) or category (#{category_name}) not found")
        end
    end
  end
  
  defp mark_movie_canonical(tmdb_id, source_key, metadata) do
    case Repo.get_by(Movies.Movie, tmdb_id: tmdb_id) do
      nil ->
        Logger.error("Movie with TMDb ID #{tmdb_id} not found for canonical marking")
        
      movie ->
        current_sources = movie.canonical_sources || %{}
        
        updated_sources = Map.put(current_sources, source_key, Map.merge(%{
          "included" => true
        }, metadata))
        
        case movie
             |> Movies.Movie.changeset(%{canonical_sources: updated_sources})
             |> Repo.update() do
          {:ok, _updated_movie} ->
            Logger.info("Successfully marked #{movie.title} as canonical in #{source_key}")
            
          {:error, changeset} ->
            Logger.error("Failed to mark #{movie.title} as canonical: #{inspect(changeset.errors)}")
        end
    end
  end

  defp handle_no_tmdb_match(imdb_id, args) do
    # For Oscar imports without TMDb match, we might want to track this
    if args["source"] == "oscar_import" && args["metadata"] do
      metadata = args["metadata"]
      Logger.warning("Oscar nominee '#{metadata["film_title"]}' (#{imdb_id}) not found in TMDb")
      # Could create a skipped import record here
    end
    
    # For canonical imports without TMDb match, log it  
    if args["source"] == "canonical_import" && args["canonical_source"] do
      canonical_source = args["canonical_source"]
      source_key = canonical_source["source_key"]
      metadata = canonical_source["metadata"]
      scraped_title = metadata["scraped_title"] || "Unknown"
      
      Logger.warning("Canonical movie '#{scraped_title}' (#{imdb_id}) from #{source_key} not found in TMDb")
      # Could create a skipped import record here for canonical movies too
    end
    
    :ok
  end
end