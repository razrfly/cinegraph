defmodule Cinegraph.Workers.CanonicalImportOrchestrator do
  @moduledoc """
  Orchestrator worker that determines total pages and queues individual page workers.
  Follows the same pattern as TMDbDiscoveryWorker for consistency.
  """
  
  use Oban.Worker, 
    queue: :imdb_scraping,
    max_attempts: 3
  
  alias Cinegraph.Workers.CanonicalPageWorker
  alias Cinegraph.Scrapers.ImdbCanonicalScraper
  alias Cinegraph.CanonicalLists
  require Logger
  
  def available_lists, do: CanonicalLists.all()
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "orchestrate_import", "list_key" => list_key}}) do
    with {:ok, list_config} <- get_list_config(list_key),
         {:ok, total_pages} <- get_total_pages(list_config.list_id) do
      
      Logger.info("Starting canonical import orchestration for #{list_config.name}")
      Logger.info("Total pages to process: #{total_pages}")
      
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
      
      # Insert all jobs - Oban.insert_all returns a list of jobs, not a tuple
      case Oban.insert_all(jobs) do
        jobs_list when is_list(jobs_list) ->
          Logger.info("Successfully queued #{length(jobs_list)} page jobs for #{list_config.name}")
          
          broadcast_progress(list_key, :queued, %{
            list_name: list_config.name,
            pages_queued: length(jobs_list),
            status: "#{length(jobs_list)} page jobs queued"
          })
          
          :ok
          
        error ->
          Logger.error("Failed to queue page jobs: #{inspect(error)}")
          {:error, error}
      end
      
    else
      {:error, :list_not_found} ->
        Logger.error("List configuration not found for key: #{list_key}")
        {:error, "List not found: #{list_key}"}
        
      {:error, reason} ->
        Logger.error("Failed to orchestrate import: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp get_list_config(list_key) do
    case CanonicalLists.get(list_key) do
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
end