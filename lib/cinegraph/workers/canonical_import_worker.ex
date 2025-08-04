defmodule Cinegraph.Workers.CanonicalImportWorker do
  @moduledoc """
  Worker to handle canonical list imports triggered from the UI.
  """
  
  use Oban.Worker, 
    queue: :imdb_scraping,
    max_attempts: 3
  
  alias Cinegraph.Cultural.CanonicalImporter
  require Logger
  
  # Predefined canonical lists
  @lists %{
    "1001_movies" => %{
      list_id: "ls024863935",
      source_key: "1001_movies", 
      name: "1001 Movies You Must See Before You Die",
      metadata: %{"edition" => "2024"}
    }
    # Future lists can be added here:
    # "sight_sound" => %{
    #   list_id: "ls123456789",
    #   source_key: "sight_sound",
    #   name: "Sight & Sound Greatest Films of All Time",
    #   metadata: %{"edition" => "2022"}
    # }
  }
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "import_canonical_list", "list_key" => list_key}}) do
    Logger.info("Starting canonical import for #{list_key}")
    
    case Map.get(@lists, list_key) do
      nil ->
        Logger.error("Unknown canonical list: #{list_key}")
        {:error, "Unknown list: #{list_key}"}
        
      list_config ->
        # Broadcast start of import
        broadcast_progress(list_key, :started, %{
          list_name: list_config.name,
          status: "Starting import..."
        })
        
        # Perform the import
        result = CanonicalImporter.import_canonical_list(
          list_config.list_id,
          list_config.source_key,
          list_config.name,
          [create_movies: true],
          list_config.metadata
        )
        
        # Broadcast completion
        broadcast_progress(list_key, :completed, %{
          list_name: list_config.name,
          movies_created: result.movies_created,
          movies_updated: result.movies_updated,
          movies_queued: result.movies_queued,
          movies_skipped: result.movies_skipped,
          total_movies: result.total_movies
        })
        
        Logger.info("Completed canonical import for #{list_key}: #{result.total_movies} movies processed")
        
        :ok
    end
  end
  
  # Get available lists for UI
  def available_lists do
    @lists
  end
  
  defp broadcast_progress(list_key, status, data) do
    Phoenix.PubSub.broadcast(
      Cinegraph.PubSub,
      "import_progress",
      {:canonical_progress, Map.merge(data, %{
        list_key: list_key,
        status: status,
        timestamp: DateTime.utc_now()
      })}
    )
  end
end