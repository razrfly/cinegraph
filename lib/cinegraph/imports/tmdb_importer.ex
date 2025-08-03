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
  """
  def start_full_import do
    Logger.info("Starting systematic TMDB import")
    
    # Get total movies from TMDB
    case update_tmdb_total() do
      {:ok, total} ->
        Logger.info("TMDB has #{total} total movies")
        
        # Start from page 1 (or resume from last page)
        start_page = ImportState.last_page_processed() + 1
        Logger.info("Starting from page #{start_page}")
        
        # Queue first discovery job
        queue_discovery_job(start_page)
        
        {:ok, %{
          tmdb_total: total,
          our_total: count_our_movies(),
          starting_page: start_page
        }}
        
      error ->
        Logger.error("Failed to get TMDB total: #{inspect(error)}")
        error
    end
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
  
  defp queue_discovery_job(page) do
    args = %{
      "page" => page,
      "import_type" => "full"
    }
    
    case args
         |> TMDbDiscoveryWorker.new()
         |> Oban.insert() do
      {:ok, job} ->
        Logger.info("Queued discovery job for page #{page}")
        {:ok, job}
      error ->
        Logger.error("Failed to queue discovery job: #{inspect(error)}")
        error
    end
  end
  
  defp calculate_discovery_delay(page_number) do
    # TMDB rate limit: 40 requests per 10 seconds = 4/second
    # Each discovery spawns ~20 detail jobs
    # So we need to space out discovery jobs
    
    # Base delay increases with page number to spread load
    base_delay = min(page_number * 10, 300)  # Cap at 5 minutes
    
    # Add some jitter to avoid thundering herd
    jitter = :rand.uniform(30)
    
    base_delay + jitter
  end
end