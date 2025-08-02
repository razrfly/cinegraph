defmodule Cinegraph.MovieImporter do
  @moduledoc """
  Orchestration layer for movie imports using the modular API processor system.
  
  This module provides high-level functions for importing movies from various APIs,
  either all at once or selectively. It integrates with Oban for job processing
  or can be used directly for immediate processing.
  """
  
  alias Cinegraph.Repo
  alias Cinegraph.Movies
  alias Cinegraph.Movies.Movie
  alias Cinegraph.ApiProcessors.{TMDb, OMDb}
  import Ecto.Query
  require Logger
  
  @default_apis ["tmdb", "omdb"]
  @processors %{"tmdb" => TMDb, "omdb" => OMDb}
  
  @doc """
  Import a movie by TMDb ID, processing all configured APIs.
  
  ## Options
    - :apis - List of API names to process (default: ["tmdb", "omdb"])
    - :queue - Whether to queue the job or process immediately (default: true)
    - :opts - Additional options to pass to processors
  """
  def import_movie_from_tmdb(tmdb_id, options \\ []) do
    apis = Keyword.get(options, :apis, @default_apis)
    queue = Keyword.get(options, :queue, true)
    opts = Keyword.get(options, :opts, [])
    
    if queue do
      queue_import_job(tmdb_id, apis, opts)
    else
      process_import_immediately(tmdb_id, apis, opts)
    end
  end
  
  @doc """
  Process a specific API for an existing movie.
  
  ## Options
    - :queue - Whether to queue the job or process immediately (default: true)
    - :force_refresh - Force refresh even if data exists (default: false)
  """
  def process_movie_api(movie_id, api, options \\ []) do
    queue = Keyword.get(options, :queue, true)
    
    if queue do
      queue_api_job(movie_id, api, options)
    else
      process_api_immediately(movie_id, api, options)
    end
  end
  
  @doc """
  Reprocess all movies that are missing data from a specific API.
  
  ## Options
    - :queue - Whether to queue jobs or process immediately (default: true)
    - :limit - Maximum number of movies to process (default: nil - all movies)
  """
  def reprocess_missing_api_data(api, options \\ []) do
    queue = Keyword.get(options, :queue, true)
    limit = Keyword.get(options, :limit)
    
    movies = find_movies_missing_api_data(api, limit)
    count = length(movies)
    
    Logger.info("Found #{count} movies missing #{api} data")
    
    if queue do
      Enum.each(movies, &queue_api_job(&1.id, api, []))
      {:ok, count, count}  # All queued successfully
    else
      results = Enum.map(movies, fn movie ->
        case process_api_immediately(movie.id, api, []) do
          {:ok, _} -> :ok
          error -> error
        end
      end)
      
      success_count = Enum.count(results, &(&1 == :ok))
      {:ok, success_count, count}
    end
  end
  
  @doc """
  Get a summary of API data coverage across all movies.
  """
  def get_api_coverage_summary do
    total_movies = Repo.aggregate(Movie, :count)
    
    coverage = Enum.map(@default_apis, fn api ->
      case get_processor(api) do
        nil -> 
          {api, %{count: 0, percentage: 0.0}}
        processor ->
          data_field = processor.data_field()
          
          query = from m in Movie,
            where: not is_nil(field(m, ^data_field)),
            select: count(m.id)
      
          count = Repo.one(query)
          percentage = if total_movies > 0, do: Float.round(count / total_movies * 100, 1), else: 0.0
          
          {api, %{count: count, percentage: percentage}}
      end
    end)
    
    %{
      total_movies: total_movies,
      coverage: Map.new(coverage)
    }
  end
  
  # Private functions
  
  defp queue_import_job(tmdb_id, _apis, opts) do
    # Queue a TMDb details job
    %{
      tmdb_id: tmdb_id,
      title: opts[:title],
      import_progress_id: opts[:import_progress_id]
    }
    |> Cinegraph.Workers.TMDbDetailsWorker.new()
    |> Oban.insert()
  end
  
  defp queue_api_job(movie_id, "omdb", _options) do
    try do
      movie = Movies.get_movie!(movie_id)
      %{
        movie_id: movie.id,
        imdb_id: movie.imdb_id,
        title: movie.title
      }
      |> Cinegraph.Workers.OMDbEnrichmentWorker.new()
      |> Oban.insert()
    rescue
      Ecto.NoResultsError ->
        {:error, :movie_not_found}
    end
  end
  defp queue_api_job(_movie_id, api, _options) do
    {:error, {:unsupported_api, api}}
  end
  
  defp process_import_immediately(tmdb_id, apis, opts) do
    # First, ensure we have the movie from TMDb
    with {:ok, movie} <- ensure_movie_exists(tmdb_id),
         {:ok, movie} <- process_apis_for_movie(movie, apis, opts) do
      {:ok, movie}
    end
  end
  
  defp process_api_immediately(movie_id, api, options) do
    case get_processor(api) do
      nil ->
        {:error, :unknown_api}
      processor ->
        processor.process_movie(movie_id, options)
    end
  end
  
  defp ensure_movie_exists(tmdb_id) do
    case Movies.get_movie_by_tmdb_id(tmdb_id) do
      nil ->
        # Create a basic movie record first
        case Movies.create_movie(%{
          tmdb_id: tmdb_id, 
          title: "Pending Import - TMDb ID: #{tmdb_id}"
        }) do
          {:ok, movie} -> {:ok, movie}
          error -> error
        end
      movie ->
        {:ok, movie}
    end
  end
  
  defp process_apis_for_movie(movie, apis, opts) do
    results = Enum.map(apis, fn api ->
      case get_processor(api) do
        nil ->
          {:skipped, api, :unknown_api}
        processor ->
          if processor.can_process?(movie) do
            Logger.info("Processing #{api} for movie ID #{movie.id}")
            
            # Apply rate limiting
            Process.sleep(processor.rate_limit_ms())
            
            case processor.process_movie(movie.id, opts) do
              {:ok, updated_movie} -> {:ok, api, updated_movie}
              error -> {:error, api, error}
            end
          else
            {:skipped, api, :cannot_process}
          end
      end
    end)
    
    # Return the most recent version of the movie
    successful_results = Enum.filter(results, fn
      {:ok, _, _} -> true
      _ -> false
    end)
    
    if length(successful_results) > 0 do
      {_, _, final_movie} = List.last(successful_results)
      {:ok, final_movie}
    else
      # Reload the movie to get any partial updates
      {:ok, Repo.get!(Movie, movie.id)}
    end
  end
  
  defp find_movies_missing_api_data(api, limit) do
    case get_processor(api) do
      nil ->
        []
      processor ->
        data_field = processor.data_field()
        required_field = processor.required_identifier()
        
        query = from m in Movie,
          where: is_nil(field(m, ^data_field)) and not is_nil(field(m, ^required_field)),
          order_by: [desc: m.popularity],
          preload: []
        
        query = if limit, do: limit(query, ^limit), else: query
        
        Repo.all(query)
    end
  end
  
  defp get_processor(api) do
    Map.get(@processors, api)
  end
end