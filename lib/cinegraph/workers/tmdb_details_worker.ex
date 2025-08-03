defmodule Cinegraph.Workers.TMDbDetailsWorker do
  @moduledoc """
  Simplified details worker that doesn't use import progress tracking.
  """
  
  use Oban.Worker, 
    queue: :tmdb_details,
    max_attempts: 5,
    unique: [fields: [:args], keys: [:tmdb_id], period: 300]
    
  # Custom backoff for network errors - exponential with jitter
  def backoff(%Oban.Job{attempt: attempt}) do
    base_delay = :timer.seconds(5)
    max_delay = :timer.minutes(5)
    
    delay = min(base_delay * :math.pow(2, attempt - 1), max_delay)
    jitter = :rand.uniform_real() * 0.3 * delay
    
    trunc(delay + jitter)
  end
    
  alias Cinegraph.Movies
  alias Cinegraph.Workers.{OMDbEnrichmentWorker, CollaborationWorker}
  alias Cinegraph.Imports.QualityFilter
  alias Cinegraph.Services.TMDb
  require Logger
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tmdb_id" => tmdb_id}}) do
    Logger.info("Processing movie details for TMDb ID #{tmdb_id}")
    
    # Skip if already exists
    if Movies.movie_exists?(tmdb_id) do
      Logger.info("Movie #{tmdb_id} already exists, skipping")
      :ok
    else
      # First, get basic movie info to evaluate quality
      case TMDb.get_movie(tmdb_id) do
        {:ok, movie_data} ->
          # Evaluate movie quality
          case QualityFilter.evaluate_movie(movie_data) do
            {:full_import, met_criteria} ->
              Logger.info("Movie #{movie_data["title"]} meets quality criteria: #{inspect(met_criteria)}")
              perform_full_import(tmdb_id, movie_data)
              
            {:soft_import, failed_criteria} ->
              Logger.info("Movie #{movie_data["title"]} failed quality criteria: #{inspect(failed_criteria)}")
              perform_soft_import(tmdb_id, movie_data)
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
end