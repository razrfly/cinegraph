defmodule Cinegraph.Import.ImportCoordinator do
  @moduledoc """
  Coordinates concurrent movie imports from TMDb.
  Processes multiple pages simultaneously while respecting API rate limits.
  """
  use Oban.Worker, queue: :imports, max_attempts: 3
  
  alias Cinegraph.Import.ImportStats
  alias Cinegraph.MovieImporter
  alias Cinegraph.Services.TMDb
  
  require Logger
  
  # TMDb allows 40 requests per 10 seconds
  # We'll use 35 to leave some headroom
  @concurrent_requests 10
  @rate_limit_requests 35
  @batch_delay_ms 3_000 # Delay between batches to respect rate limits
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    import_id = args["import_id"]
    import_type = args["import_type"] || "popular"
    total_pages = args["total_pages"] || 500
    
    Logger.info("Starting concurrent import #{import_id} for #{import_type} movies (#{total_pages} pages)")
    
    # Initialize stats
    ImportStats.start_import(import_id, total_pages)
    
    # Process pages in batches
    result = process_pages_concurrently(import_id, import_type, total_pages)
    
    # Mark import as complete
    ImportStats.complete_import(import_id)
    
    result
  end
  
  defp process_pages_concurrently(import_id, import_type, total_pages) do
    # Calculate batches based on rate limits
    pages_per_batch = div(@rate_limit_requests, 2) # 2 requests per page (list + details)
    
    1..total_pages
    |> Enum.chunk_every(pages_per_batch)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, 0}, fn {page_batch, batch_num}, {:ok, total_imported} ->
      Logger.info("Processing batch #{batch_num} (pages #{List.first(page_batch)}-#{List.last(page_batch)})")
      
      # Process batch concurrently
      case process_batch(import_id, import_type, page_batch) do
        {:ok, batch_imported} ->
          new_total = total_imported + batch_imported
          
          # Add delay between batches to respect rate limits
          if batch_num * pages_per_batch < total_pages do
            Process.sleep(@batch_delay_ms)
          end
          
          {:cont, {:ok, new_total}}
          
        {:error, reason} ->
          Logger.error("Batch #{batch_num} failed: #{inspect(reason)}")
          {:halt, {:error, reason}}
      end
    end)
  end
  
  defp process_batch(import_id, import_type, pages) do
    # Use Task.async_stream for concurrent processing with proper supervision
    results = pages
    |> Task.async_stream(
      fn page -> process_single_page(import_id, import_type, page) end,
      max_concurrency: @concurrent_requests,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce({0, []}, fn
      {:ok, {:ok, count}}, {total, errors} -> 
        {total + count, errors}
      {:ok, {:error, error}}, {total, errors} -> 
        {total, [error | errors]}
      {:exit, reason}, {total, errors} -> 
        {total, [{:exit, reason} | errors]}
    end)
    
    case results do
      {total_imported, []} ->
        {:ok, total_imported}
      {total_imported, errors} ->
        Logger.warning("Batch completed with #{length(errors)} errors: #{inspect(errors)}")
        {:ok, total_imported}
    end
  end
  
  defp process_single_page(import_id, import_type, page) do
    try do
      # Fetch page from TMDb
      case fetch_page(import_type, page) do
        {:ok, %{"results" => movies}} ->
          # Import each movie
          imported_count = Enum.reduce(movies, 0, fn movie_data, count ->
            case MovieImporter.import_movie_from_tmdb(movie_data["id"], queue: false, apis: ["tmdb"]) do
              {:ok, _movie} ->
                ImportStats.record_movie_imported(import_id)
                count + 1
              {:error, reason} ->
                Logger.warning("Failed to import movie #{movie_data["id"]}: #{inspect(reason)}")
                count
            end
          end)
          
          # Record page completion
          ImportStats.record_page_complete(import_id, imported_count)
          
          {:ok, imported_count}
          
        {:error, reason} ->
          Logger.error("Failed to fetch page #{page}: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("Error processing page #{page}: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end
  
  defp fetch_page("popular", page), do: TMDb.get_popular_movies(page)
  defp fetch_page("top_rated", page), do: TMDb.get_top_rated_movies(page)
  defp fetch_page("now_playing", page), do: TMDb.get_now_playing_movies(page)
  defp fetch_page("upcoming", page), do: TMDb.get_upcoming_movies(page)
  defp fetch_page(type, _page) do
    {:error, "Unknown import type: #{type}"}
  end
  
  @doc """
  Starts a new concurrent import job.
  """
  def start_import(import_type \\ "popular", total_pages \\ 500) do
    import_id = generate_import_id()
    
    %{
      import_id: import_id,
      import_type: import_type,
      total_pages: total_pages
    }
    |> __MODULE__.new()
    |> Oban.insert()
    
    {:ok, import_id}
  end
  
  defp generate_import_id do
    "import_#{DateTime.utc_now() |> DateTime.to_unix()}_#{:rand.uniform(9999)}"
  end
end