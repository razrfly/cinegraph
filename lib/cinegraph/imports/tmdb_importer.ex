defmodule Cinegraph.Imports.TMDbImporter do
  @moduledoc """
  Simplified TMDB importer using state tracking instead of complex progress records.
  
  Progress is tracked by: TMDB Total Movies - Our Total Movies
  """
  
  alias Cinegraph.Imports.ImportState
  alias Cinegraph.Workers.{TMDbDiscoveryWorker, TMDbDetailsWorker}
  alias Cinegraph.Services.TMDb
  alias Cinegraph.Movies
  alias Cinegraph.Repo
  require Logger
  
  @doc """
  Starts a systematic import of all TMDB movies.
  Uses pagination to go through every movie in TMDB.
  
  ## Options
    - :pages - Number of pages to import (default: 500)
  """
  def start_full_import(opts \\ []) do
    Logger.info("Starting systematic TMDB import")
    
    # Get total movies from TMDB
    case update_tmdb_total() do
      {:ok, total} ->
        Logger.info("TMDB has #{total} total movies")
        
        # Start from page 1 (or resume from last page)
        start_page = ImportState.last_page_processed() + 1
        pages_to_import = Keyword.get(opts, :pages, 500)
        end_page = start_page + pages_to_import - 1
        
        Logger.info("Queueing pages #{start_page} to #{end_page}")
        
        # Queue all pages at once for better concurrency
        case queue_pages(start_page, end_page) do
          {:ok, queued_count} ->
            {:ok, %{
              tmdb_total: total,
              our_total: count_our_movies(),
              starting_page: start_page,
              pages_queued: queued_count
            }}
          error ->
            error
        end
        
      error ->
        Logger.error("Failed to get TMDB total: #{inspect(error)}")
        error
    end
  end
  
  @doc """
  Queues multiple pages for import at once.
  This is the better approach - queue all jobs upfront and let Oban handle scheduling.
  
  ## Examples
      # Queue 500 pages (approximately 10,000 movies)
      TMDbImporter.queue_pages(1, 500)
      
      # Queue pages 100-200
      TMDbImporter.queue_pages(100, 200)
  """
  def queue_pages(start_page, end_page, import_type \\ "full") when start_page <= end_page do
    Logger.info("Queueing pages #{start_page} to #{end_page}")
    
    jobs = for page <- start_page..end_page do
      delay = calculate_discovery_delay(page - start_page + 1)
      
      %{
        "page" => page,
        "import_type" => import_type
      }
      |> TMDbDiscoveryWorker.new(schedule_in: delay)
    end
    
    case Oban.insert_all(jobs) do
      results when is_list(results) ->
        Logger.info("Successfully queued #{length(results)} discovery jobs")
        {:ok, length(results)}
        
      error ->
        Logger.error("Failed to queue discovery jobs: #{inspect(error)}")
        {:error, error}
    end
  end
  
  @doc """
  Starts import for a specific number of pages.
  
  ## Examples
      # Import approximately 10,000 movies (500 pages)
      TMDbImporter.import_pages(500)
      
      # Import 100 pages (approximately 2,000 movies)
      TMDbImporter.import_pages(100)
  """
  def import_pages(num_pages) do
    # Get or update TMDB total
    update_tmdb_total()
    
    # Start from where we left off
    start_page = ImportState.last_page_processed() + 1
    end_page = start_page + num_pages - 1
    
    Logger.info("Importing #{num_pages} pages (#{start_page} to #{end_page})")
    Logger.info("This will import approximately #{num_pages * 20} movies")
    
    queue_pages(start_page, end_page)
  end
  
  @doc """
  Starts a daily update to fetch new movies.
  """
  def start_daily_update do
    Logger.info("Starting daily TMDB update")
    
    # Get movies from the last 7 days
    end_date = Date.utc_today()
    start_date = Date.add(end_date, -7)
    
    # Update TMDB total count
    update_tmdb_total()
    
    # Queue discovery for recent movies
    args = %{
      "page" => 1,
      "import_type" => "daily_update",
      "primary_release_date.gte" => Date.to_string(start_date),
      "primary_release_date.lte" => Date.to_string(end_date),
      "sort_by" => "release_date.desc"
    }
    
    case args
         |> TMDbDiscoveryWorker.new()
         |> Oban.insert() do
      {:ok, job} ->
        ImportState.set_last_update_check()
        {:ok, job}
      error ->
        error
    end
  end
  
  @doc """
  Gets current import progress.
  """
  def get_progress do
    tmdb_total = ImportState.tmdb_total_movies()
    our_total = count_our_movies()
    last_page = ImportState.last_page_processed()
    
    %{
      tmdb_total_movies: tmdb_total,
      our_total_movies: our_total,
      movies_remaining: max(0, tmdb_total - our_total),
      completion_percentage: if(tmdb_total > 0, do: Float.round(our_total / tmdb_total * 100, 2), else: 0.0),
      last_page_processed: last_page,
      last_full_sync: ImportState.last_full_sync(),
      last_update_check: ImportState.last_update_check()
    }
  end
  
  @doc """
  Updates the total movie count from TMDB.
  """
  def update_tmdb_total do
    case TMDb.get_total_movie_count() do
      {:ok, total} ->
        ImportState.set_tmdb_total_movies(total)
        {:ok, total}
      error ->
        error
    end
  end
  
  @doc """
  Checks if we should import a movie (deduplication).
  """
  def should_import_movie?(tmdb_id) do
    !Movies.movie_exists?(tmdb_id)
  end
  
  @doc """
  Processes a discovery page and queues detail jobs for new movies.
  """
  def process_discovery_page(page, results) do
    Logger.info("Processing discovery page #{page} with #{length(results)} movies")
    
    # Filter out movies we already have
    new_movies = Enum.filter(results, fn movie ->
      should_import_movie?(movie["id"])
    end)
    
    Logger.info("Found #{length(new_movies)} new movies to import")
    
    # Queue detail jobs for new movies
    jobs = Enum.map(new_movies, fn movie ->
      %{
        "tmdb_id" => movie["id"],
        "title" => movie["title"],
        "release_date" => movie["release_date"]
      }
      |> TMDbDetailsWorker.new()
    end)
    
    case Oban.insert_all(jobs) do
      results when is_list(results) ->
        # Update last processed page
        ImportState.set_last_page_processed(page)
        {:ok, length(results)}
      error ->
        Logger.error("Failed to queue detail jobs: #{inspect(error)}")
        {:error, error}
    end
  end
  
  @doc """
  Queues the next discovery job with smart delays.
  DEPRECATED: Use queue_pages/3 instead for better queue management.
  """
  def queue_next_discovery(current_page, total_pages, import_type \\ "full") do
    if current_page < total_pages do
      next_page = current_page + 1
      delay = calculate_discovery_delay(next_page)
      
      args = %{
        "page" => next_page,
        "import_type" => import_type
      }
      
      case args
           |> TMDbDiscoveryWorker.new(schedule_in: delay)
           |> Oban.insert() do
        {:ok, _job} ->
          Logger.info("Queued discovery for page #{next_page} with #{delay}s delay")
          :ok
        error ->
          Logger.error("Failed to queue next discovery: #{inspect(error)}")
          error
      end
    else
      Logger.info("Import complete! Processed all #{total_pages} pages")
      ImportState.set_last_full_sync()
      :ok
    end
  end
  
  # Private functions
  
  defp count_our_movies do
    Repo.aggregate(Movies.Movie, :count)
  end
  
  
  defp calculate_discovery_delay(page_position) do
    # TMDB rate limit: 40 requests per 10 seconds = 4/second
    # We can have multiple discovery jobs running since Oban controls concurrency
    # With queue concurrency of 10, we can handle bursts better
    
    # Group pages into waves - 10 pages per wave
    # This allows 10 discovery jobs to run concurrently
    wave = div(page_position - 1, 10)
    
    # Each wave starts 30 seconds after the previous one
    # This gives time for the previous wave's detail jobs to process
    wave_delay = wave * 30
    
    # Add small jitter within the wave to avoid exact simultaneity
    jitter = :rand.uniform(5)
    
    wave_delay + jitter
  end
end