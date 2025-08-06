defmodule Cinegraph.Workers.OscarImportWorker do
  @moduledoc """
  Worker to handle Oscar ceremony imports triggered from the UI.
  """
  
  use Oban.Worker, 
    queue: :oscar_imports,
    max_attempts: 3
  
  alias Cinegraph.Cultural
  require Logger
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"year" => year, "options" => options}} = job) do
    year = ensure_integer(year)
    Logger.info("Starting Oscar import for year #{year} (from Cultural module)")
    
    # Convert options map back to keyword list
    import_options = Enum.map(options, fn {key, value} -> {String.to_atom(key), value} end)
    
    # Broadcast start
    broadcast_progress(:single, :started, %{
      year: year,
      status: "Importing Oscar data for #{year}..."
    })
    
    # Perform import
    case Cultural.import_oscar_year(year, import_options) do
      {:ok, result} ->
        case result do
          %{status: :queued} ->
            # Check if ceremony already existed
            existing_ceremonies = Cultural.list_oscar_ceremonies()
            existing_years = Enum.map(existing_ceremonies, & &1.year)
            ceremony_existed = year in existing_years
            
            job_meta = %{
              years_processed: 1,
              ceremonies_found: 1,
              ceremonies_created: if(ceremony_existed, do: 0, else: 1),
              ceremonies_updated: if(ceremony_existed, do: 1, else: 0),
              discovery_jobs_queued: 1,
              failed_years: []
            }
            
            update_job_meta(job, job_meta)
            
            # Job was queued, not processed directly
            broadcast_progress(:single, :queued, %{
              year: year,
              job_id: result.job_id,
              ceremony_id: result.ceremony_id,
              jobs_queued: 1,
              status: "Queued Oscar discovery job for #{year}"
            })
            
            Logger.info("Queued Oscar discovery job for #{year}: job_id=#{result.job_id}")
            :ok
            
          %{movies_created: _} ->
            # Direct processing results (has statistics)
            broadcast_progress(:single, :completed, %{
              year: year,
              movies_created: result.movies_created,
              movies_updated: result.movies_updated,
              movies_queued: result.movies_queued,
              movies_skipped: result.movies_skipped,
              total_nominees: result.total_nominees
            })
            
            Logger.info("Completed Oscar import for #{year}: #{result.total_nominees} nominees processed")
            :ok
            
          _ ->
            # Unknown result format
            Logger.warning("Unexpected result format from Cultural.import_oscar_year: #{inspect(result)}")
            broadcast_progress(:single, :completed, %{
              year: year,
              status: "Oscar import completed with unknown result format"
            })
            :ok
        end
        
      {:error, reason} ->
        Logger.error("Failed to import Oscar year #{year}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{"action" => "import_single", "year" => year}} = job) do
    Logger.info("Starting Oscar import for year #{year}")
    
    # Broadcast start
    broadcast_progress(:single, :started, %{
      year: year,
      status: "Importing Oscar data for #{year}..."
    })
    
    # Perform import
    case Cultural.import_oscar_year(year, [create_movies: true]) do
      {:ok, result} ->
        case result do
          %{status: :queued} ->
            # Check if ceremony already existed
            existing_ceremonies = Cultural.list_oscar_ceremonies()
            existing_years = Enum.map(existing_ceremonies, & &1.year)
            ceremony_existed = year in existing_years
            
            job_meta = %{
              years_processed: 1,
              ceremonies_found: 1,
              ceremonies_created: if(ceremony_existed, do: 0, else: 1),
              ceremonies_updated: if(ceremony_existed, do: 1, else: 0),
              discovery_jobs_queued: 1,
              failed_years: []
            }
            
            update_job_meta(job, job_meta)
            
            # Job was queued, not processed directly
            broadcast_progress(:single, :queued, %{
              year: year,
              job_id: result.job_id,
              ceremony_id: result.ceremony_id,
              jobs_queued: 1,
              status: "Queued Oscar discovery job for #{year}"
            })
            
            Logger.info("Queued Oscar discovery job for #{year}: job_id=#{result.job_id}")
            :ok
            
          %{movies_created: _} ->
            # Direct processing results (has statistics)
            broadcast_progress(:single, :completed, %{
              year: year,
              movies_created: result.movies_created,
              movies_updated: result.movies_updated,
              movies_queued: result.movies_queued,
              movies_skipped: result.movies_skipped,
              total_nominees: result.total_nominees
            })
            
            Logger.info("Completed Oscar import for #{year}: #{result.total_nominees} nominees processed")
            :ok
            
          _ ->
            # Unknown result format
            Logger.warning("Unexpected result format from Cultural.import_oscar_year: #{inspect(result)}")
            broadcast_progress(:single, :completed, %{
              year: year,
              status: "Oscar import completed with unknown result format"
            })
            :ok
        end
        
      {:error, reason} ->
        Logger.error("Failed to import Oscar year #{year}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  def perform(%Oban.Job{args: %{"action" => "import_range", "start_year" => start_year, "end_year" => end_year}} = job) do
    start_year = ensure_integer(start_year)
    end_year = ensure_integer(end_year)
    
    Logger.info("Starting Oscar import for years #{start_year}-#{end_year}")
    
    # Broadcast start
    broadcast_progress(:range, :started, %{
      start_year: start_year,
      end_year: end_year,
      status: "Importing Oscar data for #{start_year}-#{end_year}..."
    })
    
    # Queue individual year jobs
    case Cultural.import_oscar_years(start_year..end_year, [create_movies: true]) do
      {:ok, %{job_count: count, status: :queued}} ->
        # Calculate metadata for this range import
        years_processed = end_year - start_year + 1
        
        # Check how many ceremonies already exist vs will be created
        existing_ceremonies = Cultural.list_oscar_ceremonies()
        existing_years = Enum.map(existing_ceremonies, & &1.year)
        target_years = Enum.to_list(start_year..end_year)
        
        ceremonies_found = length(target_years)
        ceremonies_existing = length(Enum.filter(target_years, & &1 in existing_years))
        ceremonies_created = ceremonies_found - ceremonies_existing
        
        job_meta = %{
          years_processed: years_processed,
          ceremonies_found: ceremonies_found,
          ceremonies_created: ceremonies_created,
          ceremonies_updated: ceremonies_existing,
          discovery_jobs_queued: count,
          failed_years: []
        }
        
        update_job_meta(job, job_meta)
        
        broadcast_progress(:range, :queued, %{
          start_year: start_year,
          end_year: end_year,
          jobs_queued: count
        })
        
        Logger.info("Queued #{count} Oscar import jobs for years #{start_year}-#{end_year}")
        :ok
        
      results when is_map(results) ->
        # Sequential processing results
        total_created = Enum.reduce(results, 0, fn {_year, result}, acc ->
          case result do
            {:ok, data} -> acc + data.movies_created
            _ -> acc
          end
        end)
        
        broadcast_progress(:range, :completed, %{
          start_year: start_year,
          end_year: end_year,
          total_movies_created: total_created,
          years_processed: map_size(results)
        })
        
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to import Oscar years #{start_year}-#{end_year}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  def perform(%Oban.Job{args: %{"action" => "import_all_years"}}) do
    Logger.info("Starting Oscar import for all years (2016-2024)")
    
    # Broadcast start
    broadcast_progress(:all, :started, %{
      status: "Importing all Oscar ceremonies (2016-2024)..."
    })
    
    # Import all years
    case Cultural.import_all_oscar_years([create_movies: true]) do
      {:ok, %{job_count: count, status: :queued}} ->
        broadcast_progress(:all, :queued, %{
          jobs_queued: count
        })
        
        Logger.info("Queued #{count} Oscar import jobs for all years")
        :ok
        
      results when is_map(results) ->
        # Sequential processing results
        total_created = Enum.reduce(results, 0, fn {_year, result}, acc ->
          case result do
            {:ok, data} -> acc + data.movies_created
            _ -> acc
          end
        end)
        
        broadcast_progress(:all, :completed, %{
          total_movies_created: total_created,
          years_processed: map_size(results)
        })
        
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to import all Oscar years: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp ensure_integer(value) when is_integer(value), do: value
  defp ensure_integer(value) when is_binary(value), do: String.to_integer(value)
  
  defp broadcast_progress(type, status, data) do
    Phoenix.PubSub.broadcast(
      Cinegraph.PubSub,
      "import_progress",
      {:oscar_progress, Map.merge(data, %{
        type: type,
        status: status,
        timestamp: DateTime.utc_now()
      })}
    )
  end
  
  defp update_job_meta(job, meta) do
    import Ecto.Query
    alias Cinegraph.Repo
    
    from(j in "oban_jobs",
      where: j.id == ^job.id,
      update: [set: [meta: ^meta]]
    )
    |> Repo.update_all([])
  rescue
    error ->
      Logger.warning("Failed to update job meta: #{inspect(error)}")
  end
end