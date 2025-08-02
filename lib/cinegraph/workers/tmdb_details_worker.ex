defmodule Cinegraph.Workers.TMDbDetailsWorker do
  @moduledoc """
  Oban worker for fetching complete movie details from TMDb API.
  
  This worker fetches movie details, credits, keywords, videos, and other
  supplementary data for a specific movie and saves it to the database.
  """
  
  use Oban.Worker, 
    queue: :tmdb_details,
    max_attempts: 5,
    unique: [fields: [:args], keys: [:tmdb_id], period: 300]  # 5 minute uniqueness
    
  alias Cinegraph.Repo
  alias Cinegraph.Movies
  alias Cinegraph.Movies.Movie
  alias Cinegraph.ApiProcessors.TMDb
  alias Cinegraph.Workers.OMDbEnrichmentWorker
  alias Cinegraph.Imports.ImportProgress
  require Logger
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tmdb_id" => tmdb_id} = args}) do
    Logger.info("TMDb Details Worker processing movie #{tmdb_id}")
    
    # Check if movie already exists and has been processed
    case Movies.get_movie_by_tmdb_id(tmdb_id) do
      %Movie{tmdb_data: tmdb_data} = movie when not is_nil(tmdb_data) ->
        # Already processed, maybe queue OMDB if needed
        maybe_queue_omdb(movie)
        update_import_progress(args, :already_processed)
        :ok
        
      %Movie{} = movie ->
        # Movie exists but needs TMDb data
        process_movie_details(movie, args)
        
      nil ->
        # Create new movie and process
        create_and_process_movie(tmdb_id, args)
    end
  end
  
  defp create_and_process_movie(tmdb_id, args) do
    with {:ok, movie} <- Movies.create_movie(%{
           tmdb_id: tmdb_id,
           title: args["title"] || "TMDb ID: #{tmdb_id}"
         }),
         {:ok, movie} <- TMDb.process_movie(movie.id),
         {:ok, _} <- maybe_queue_omdb(movie),
         {:ok, _} <- update_import_progress(args, :imported) do
      
      # Queue collaboration processing if we have enough movies
      maybe_queue_collaboration_update()
      
      {:ok, movie}
    else
      {:error, reason} ->
        Logger.error("Failed to process TMDb movie #{tmdb_id}: #{inspect(reason)}")
        update_import_progress(args, :failed)
        {:error, reason}
    end
  end
  
  defp process_movie_details(movie, args) do
    with {:ok, movie} <- TMDb.process_movie(movie.id),
         {:ok, _} <- maybe_queue_omdb(movie),
         {:ok, _} <- update_import_progress(args, :imported) do
      
      # Queue collaboration processing if we have enough movies
      maybe_queue_collaboration_update()
      
      {:ok, movie}
    else
      {:error, reason} ->
        Logger.error("Failed to process TMDb movie #{movie.id}: #{inspect(reason)}")
        update_import_progress(args, :failed)
        {:error, reason}
    end
  end
  
  defp maybe_queue_omdb(%Movie{imdb_id: nil}), do: {:ok, nil}
  defp maybe_queue_omdb(%Movie{imdb_id: imdb_id, omdb_data: nil} = movie) do
    %{
      movie_id: movie.id,
      imdb_id: imdb_id,
      title: movie.title
    }
    |> OMDbEnrichmentWorker.new(priority: 2)
    |> Oban.insert()
  end
  defp maybe_queue_omdb(_), do: {:ok, nil}
  
  defp update_import_progress(%{"import_progress_id" => progress_id}, status) do
    case ImportProgress.get(progress_id) do
      nil ->
        {:ok, nil}
      progress ->
        current_stats = progress.metadata || %{}
        
        new_stats = case status do
          :imported ->
            Map.update(current_stats, "movies_imported", 1, &(&1 + 1))
          :failed ->
            Map.update(current_stats, "movies_failed", 1, &(&1 + 1))
          :already_processed ->
            Map.update(current_stats, "movies_skipped", 1, &(&1 + 1))
        end
        
        ImportProgress.update(progress, %{
          movies_imported: new_stats["movies_imported"] || 0,
          movies_failed: new_stats["movies_failed"] || 0,
          metadata: new_stats
        })
    end
  end
  defp update_import_progress(_, _), do: {:ok, nil}
  
  defp maybe_queue_collaboration_update do
    # Check if we should update collaborations
    # This is a simple check - you might want to make it more sophisticated
    movie_count = Repo.aggregate(Movie, :count)
    
    if rem(movie_count, 100) == 0 do
      # Every 100 movies, queue a collaboration update
      Cinegraph.Workers.CollaborationWorker.new(%{})
      |> Oban.insert()
    end
  end
end