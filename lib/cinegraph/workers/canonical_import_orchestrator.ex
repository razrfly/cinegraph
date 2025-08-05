defmodule Cinegraph.Workers.CanonicalImportOrchestrator do
  @moduledoc """
  Orchestrator worker that determines total pages and queues individual page workers.
  Follows the same pattern as TMDbDiscoveryWorker for consistency.
  """
  
  use Oban.Worker, 
    queue: :imdb_scraping,
    max_attempts: 3,
    unique: [
      keys: [:list_key],
      period: 300,  # 5 minutes
      states: [:available, :scheduled, :executing, :retryable]
    ]
  
  alias Cinegraph.Workers.CanonicalPageWorker
  alias Cinegraph.Scrapers.ImdbCanonicalScraper
  alias Cinegraph.CanonicalLists
  alias Cinegraph.Movies.MovieLists
  require Logger
  
  @doc """
  Returns all available lists from both database and hardcoded sources.
  Database lists take precedence over hardcoded ones.
  """
  def available_lists do
    # Get active lists from database
    db_lists = MovieLists.all_as_config()
    
    # Get hardcoded lists
    hardcoded_lists = CanonicalLists.all()
    
    # Merge with database lists taking precedence
    Map.merge(hardcoded_lists, db_lists)
  end
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "orchestrate_import", "list_key" => list_key}}) do
    with {:ok, list_config} <- get_list_config(list_key),
         {:ok, total_pages} <- get_total_pages(list_config.list_id) do
      
      Logger.info("Starting canonical import orchestration for #{list_config.name}")
      Logger.info("Total pages to process: #{total_pages}")
      
      # Update import stats to mark as started
      update_import_started(list_key)
      
      # Broadcast start of import
      broadcast_progress(list_key, :orchestrating, %{
        list_name: list_config.name,
        total_pages: total_pages,
        status: "Queueing page jobs..."
      })
      
      # Queue individual page jobs
      jobs = Enum.map(1..total_pages, fn page ->
        %{
          "action" => "import_page",
          "list_key" => list_key,
          "list_id" => list_config.list_id,
          "page" => page,
          "total_pages" => total_pages,
          "source_key" => list_config.source_key,
          "list_name" => list_config.name,
          "metadata" => list_config.metadata
        }
        |> CanonicalPageWorker.new()
      end)
      
      # Insert all jobs
      jobs_list = Oban.insert_all(jobs)
      
      if is_list(jobs_list) and length(jobs_list) > 0 do
        Logger.info("Successfully queued #{length(jobs_list)} page jobs for #{list_config.name}")
        
        broadcast_progress(list_key, :queued, %{
          list_name: list_config.name,
          pages_queued: length(jobs_list),
          status: "#{length(jobs_list)} page jobs queued"
        })
        
        :ok
      else
        Logger.error("Failed to queue page jobs - no jobs inserted")
        {:error, "No jobs inserted"}
      end
      
    else
      {:error, :list_not_found} ->
        Logger.error("List configuration not found for key: #{list_key}")
        update_import_failed(list_key, "List configuration not found")
        {:error, "List not found: #{list_key}"}
        
      {:error, reason} ->
        Logger.error("Failed to orchestrate import: #{inspect(reason)}")
        update_import_failed(list_key, inspect(reason))
        {:error, reason}
    end
  end
  
  defp get_list_config(list_key) do
    # Try database first, then fallback to hardcoded
    case MovieLists.get_config(list_key) do
      {:ok, config} -> {:ok, Map.put(config, :list_key, list_key)}
      {:error, _reason} -> {:error, :list_not_found}
    end
  end
  
  defp get_total_pages(list_id) do
    case ImdbCanonicalScraper.get_total_pages(list_id) do
      {:ok, total} when is_integer(total) and total > 0 ->
        {:ok, total}
        
      {:ok, _invalid} ->
        {:error, "Invalid page count returned"}
        
      {:error, reason} ->
        {:error, reason}
    end
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
  
  defp update_import_started(list_key) do
    case MovieLists.get_active_by_source_key(list_key) do
      nil -> 
        Logger.warning("No database record found for list #{list_key}")
        :ok
      list ->
        # Update to show import is in progress
        MovieLists.update_import_stats(list, "in_progress", 0)
        Logger.info("Updated import stats for #{list_key} - marked as in progress")
    end
  end
  
  defp update_import_failed(list_key, reason) do
    case MovieLists.get_active_by_source_key(list_key) do
      nil -> 
        Logger.warning("No database record found for list #{list_key}")
        :ok
      list ->
        # Update to show import failed
        MovieLists.update_import_stats(list, "failed: #{reason}", 0)
        Logger.info("Updated import stats for #{list_key} - marked as failed")
    end
  end
end