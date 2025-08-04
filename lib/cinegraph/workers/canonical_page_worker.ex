defmodule Cinegraph.Workers.CanonicalPageWorker do
  @moduledoc """
  Worker to process a single page of a canonical list.
  Each page is processed independently for better reliability and parallelization.
  """
  
  use Oban.Worker, 
    queue: :imdb_scraping,
    max_attempts: 3
  
  alias Cinegraph.Scrapers.ImdbCanonicalScraper
  alias Cinegraph.Movies
  alias Cinegraph.Repo
  alias Cinegraph.Workers.TMDbDetailsWorker
  require Logger
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "list_id" => list_id,
      "page" => page,
      "total_pages" => total_pages,
      "source_key" => source_key,
      "list_name" => list_name,
      "metadata" => metadata,
      "list_key" => list_key
    } = args
    
    Logger.info("Processing page #{page}/#{total_pages} for #{list_name}")
    
    # Broadcast page start
    broadcast_page_progress(list_key, page, total_pages, :processing)
    
    # Fetch and process the page
    case ImdbCanonicalScraper.fetch_single_page(list_id, page) do
      {:ok, movies} ->
        Logger.info("Found #{length(movies)} movies on page #{page}")
        
        # Debug: Log first movie structure
        if length(movies) > 0 do
          first_movie = List.first(movies)
          Logger.info("First movie data structure: #{inspect(first_movie)}")
          Logger.info("Data type check - is_map: #{is_map(first_movie)}, is_list: #{is_list(movies)}")
        else
          Logger.warning("No movies returned from scraper for page #{page}")
        end
        
        # Process each movie on this page
        results = Enum.map(movies, fn movie ->
          Logger.debug("Processing movie: #{inspect(movie)}")
          process_canonical_movie(movie, source_key, list_name, metadata)
        end)
        
        # Count results
        Logger.info("Processing results: #{inspect(results)}")
        created = Enum.count(results, fn {status, _} -> status == :created end)
        updated = Enum.count(results, fn {status, _} -> status == :updated end)
        queued = Enum.count(results, fn {status, _} -> status == :queued end)
        skipped = Enum.count(results, fn {status, _} -> status == :skipped end)
        
        Logger.info("Page #{page} complete - Created: #{created}, Updated: #{updated}, Queued: #{queued}, Skipped: #{skipped}")
        
        # Broadcast page completion
        broadcast_page_progress(list_key, page, total_pages, :completed, %{
          movies_processed: length(movies),
          created: created,
          updated: updated,
          queued: queued,
          skipped: skipped
        })
        
        # Check if this was the last page
        check_completion(list_key, list_name, page, total_pages)
        
        # Return with metadata about movies processed
        {:ok, %{
          page: page,
          movies_found: length(movies),
          movies_queued: queued,
          movies_updated: updated,
          movies_skipped: skipped
        }}
        
      {:error, reason} ->
        Logger.error("Failed to process page #{page} for #{list_name}: #{inspect(reason)}")
        broadcast_page_progress(list_key, page, total_pages, :failed)
        {:error, reason}
    end
  end
  
  defp process_canonical_movie(movie_data, source_key, list_name, metadata) do
    # Handle both atom and string keys for compatibility
    imdb_id = movie_data[:imdb_id] || movie_data["imdb_id"]
    title = movie_data[:title] || movie_data["title"]
    year = movie_data[:year] || movie_data["year"]
    position = movie_data[:position] || movie_data["position"]
    
    # Skip if no IMDb ID
    if is_nil(imdb_id) or imdb_id == "" do
      Logger.warning("Skipping movie without IMDb ID: #{title} at position #{position}")
      {:skipped, nil}
    else
      # Build canonical data
      canonical_data = %{
        "included" => true,
        "source_name" => list_name,
        "scraped_title" => title,
        "scraped_year" => year,
        "list_position" => position,
        "scraped_at" => DateTime.utc_now()
      }
      |> Map.merge(metadata || %{})
      
      # Check if movie exists by IMDb ID
      Logger.info("Checking if movie exists with IMDb ID: #{imdb_id}")
      case Movies.get_movie_by_imdb_id(imdb_id) do
      nil ->
        # Movie doesn't exist - queue for creation
        Logger.info("Movie not found for IMDb ID #{imdb_id}, queueing for creation")
        
        job_args = %{
          "imdb_id" => imdb_id,
          "canonical_sources" => %{source_key => canonical_data},
          "source" => "canonical_import"
        }
        
        case TMDbDetailsWorker.new(job_args) |> Oban.insert() do
          {:ok, _job} -> {:queued, imdb_id}
          {:error, reason} -> 
            Logger.error("Failed to queue movie creation: #{inspect(reason)}")
            {:skipped, imdb_id}
        end
        
      movie ->
        # Movie exists - update canonical sources
        Logger.info("Updating movie #{movie.id} with canonical source")
        
        updated_sources = Map.put(movie.canonical_sources || %{}, source_key, canonical_data)
        
        case Movies.update_movie(movie, %{canonical_sources: updated_sources}) do
          {:ok, _updated} -> {:updated, movie.id}
          {:error, changeset} ->
            Logger.error("Failed to update movie: #{inspect(changeset)}")
            {:skipped, movie.id}
        end
      end
    end
  end
  
  defp broadcast_page_progress(list_key, page, total_pages, status, extra_data \\ %{}) do
    progress_percent = round(page / total_pages * 100)
    
    base_data = %{
      list_key: list_key,
      page: page,
      total_pages: total_pages,
      progress_percent: progress_percent,
      status: "Page #{page}/#{total_pages} #{status}"
    }
    
    Phoenix.PubSub.broadcast(
      Cinegraph.PubSub,
      "import_progress",
      {:canonical_progress, Map.merge(Map.merge(base_data, extra_data), %{
        timestamp: DateTime.utc_now()
      })}
    )
  end
  
  defp check_completion(list_key, list_name, current_page, total_pages) do
    if current_page == total_pages do
      # This was the last page - calculate totals
      Task.start(fn ->
        # No need to wait - database queries will reflect current state
        
        # Count total canonical movies for this source
        import Ecto.Query
        
        # Extract just the source key from the list key (e.g., "1001_movies")
        source_key = list_key
        
        count = Repo.one(
          from m in Cinegraph.Movies.Movie,
          where: fragment("? \\? ?", m.canonical_sources, ^source_key),
          select: count(m.id)
        )
        
        Logger.info("Import complete for #{list_name}: #{count} total movies")
        
        Phoenix.PubSub.broadcast(
          Cinegraph.PubSub,
          "import_progress",
          {:canonical_progress, %{
            list_key: list_key,
            status: :completed,
            list_name: list_name,
            total_movies: count,
            timestamp: DateTime.utc_now()
          }}
        )
      end)
    end
  end
end