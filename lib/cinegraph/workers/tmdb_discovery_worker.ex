defmodule Cinegraph.Workers.TMDbDiscoveryWorker do
  @moduledoc """
  Oban worker for discovering movies from TMDb API.
  
  This worker fetches lists of movies from TMDb's discover endpoint
  and queues individual movie detail jobs for processing.
  """
  
  use Oban.Worker, 
    queue: :tmdb_discovery,
    max_attempts: 3,
    unique: [period: 60]  # Prevent duplicate discovery jobs within 60 seconds
    
  alias Cinegraph.Workers.TMDbDetailsWorker
  alias Cinegraph.Imports.ImportProgress
  alias Cinegraph.Services.TMDb.Client
  require Logger
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"page" => page, "import_progress_id" => progress_id} = args}) do
    Logger.info("TMDb Discovery Worker processing page #{page}")
    
    # Fetch movies from TMDb
    with {:ok, %{results: movies, total_pages: total_pages}} <- fetch_movies_page(page, args),
         {:ok, _} <- queue_movie_detail_jobs(movies),
         {:ok, _} <- update_progress(progress_id, page, length(movies)) do
      
      # Queue next page if not at the end
      if page < total_pages and page < get_max_pages(args) do
        queue_next_page(page + 1, progress_id, args)
      else
        # Mark import as completed
        mark_import_completed(progress_id)
      end
      
      :ok
    else
      {:error, reason} ->
        Logger.error("TMDb Discovery Worker failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp fetch_movies_page(page, args) do
    endpoint = args["endpoint"] || "discover/movie"
    params = build_query_params(page, args)
    
    case Client.get(endpoint, params) do
      {:ok, %{"results" => results, "total_pages" => total_pages}} ->
        {:ok, %{results: results, total_pages: total_pages}}
      {:error, reason} ->
        Logger.error("Failed to fetch movies page: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp build_query_params(page, args) do
    base_params = %{
      page: page,
      language: "en-US"
    }
    
    # Add optional filters
    base_params
    |> maybe_add_param(:sort_by, args["sort_by"] || "popularity.desc")
    |> maybe_add_param(:primary_release_year, args["year"])
    |> maybe_add_param("primary_release_date.gte", args["release_date_gte"])
    |> maybe_add_param("primary_release_date.lte", args["release_date_lte"])
    |> maybe_add_param(:with_genres, args["genres"])
    |> maybe_add_param(:region, args["region"])
    |> maybe_add_param("vote_count.gte", args["vote_count.gte"])
  end
  
  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: Map.put(params, key, value)
  
  defp queue_movie_detail_jobs(movies) do
    jobs = 
      movies
      |> Enum.map(fn movie ->
        %{
          tmdb_id: movie["id"],
          title: movie["title"],
          release_date: movie["release_date"],
          priority: calculate_priority(movie)
        }
        |> TMDbDetailsWorker.new()
      end)
    
    results = Oban.insert_all(jobs)
    Logger.info("Queued #{length(results)} movie detail jobs")
    {:ok, results}
  end
  
  defp calculate_priority(%{"popularity" => popularity}) when popularity > 100, do: 0
  defp calculate_priority(%{"popularity" => popularity}) when popularity > 50, do: 1
  defp calculate_priority(%{"popularity" => popularity}) when popularity > 20, do: 2
  defp calculate_priority(_), do: 3
  
  defp update_progress(progress_id, page, movies_found) do
    case ImportProgress.get(progress_id) do
      nil ->
        Logger.warning("Import progress record #{progress_id} not found")
        {:ok, nil}
      progress ->
        ImportProgress.update(progress, %{
          current_page: page,
          movies_found: progress.movies_found + movies_found
        })
    end
  end
  
  defp queue_next_page(page, progress_id, original_args) do
    args = Map.merge(original_args, %{
      "page" => page,
      "import_progress_id" => progress_id
    })
    
    %{args: args}
    |> __MODULE__.new(schedule_in: 1) # 1 second delay to respect rate limits
    |> Oban.insert()
  end
  
  defp get_max_pages(%{"max_pages" => max_pages}), do: max_pages
  defp get_max_pages(_), do: 500  # Default TMDb API limit
  
  defp mark_import_completed(progress_id) do
    case ImportProgress.get(progress_id) do
      nil ->
        {:ok, nil}
      progress ->
        ImportProgress.update(progress, %{
          status: "completed",
          completed_at: DateTime.utc_now()
        })
    end
  end
end