defmodule Cinegraph.Workers.TMDbDetailsWorker do
  @moduledoc """
  Simplified details worker that doesn't use import progress tracking.
  """
  
  use Oban.Worker, 
    queue: :tmdb_details,
    max_attempts: 5,
    unique: [fields: [:args], keys: [:tmdb_id], period: 300]
    
  alias Cinegraph.Movies
  alias Cinegraph.Workers.OMDbEnrichmentWorker
  require Logger
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tmdb_id" => tmdb_id}}) do
    Logger.info("Processing movie details for TMDb ID #{tmdb_id}")
    
    # Skip if already exists
    if Movies.movie_exists?(tmdb_id) do
      Logger.info("Movie #{tmdb_id} already exists, skipping")
      :ok
    else
      # Fetch and store comprehensive movie data
      case Movies.fetch_and_store_movie_comprehensive(tmdb_id) do
        {:ok, movie} ->
          Logger.info("Successfully imported movie: #{movie.title} (#{movie.tmdb_id})")
          
          # Queue OMDb enrichment if we have an IMDb ID
          if movie.imdb_id do
            queue_omdb_enrichment(movie)
          else
            Logger.info("No IMDb ID for movie #{movie.title}, skipping OMDb enrichment")
          end
          
          :ok
          
        {:error, reason} ->
          Logger.error("Failed to import movie #{tmdb_id}: #{inspect(reason)}")
          {:error, reason}
      end
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
end