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
  def perform(%Oban.Job{args: %{"year" => year, "options" => options}}) do
    year = ensure_integer(year)
    Logger.info("Starting Oscar import for year #{year} (unified festival structure)")
    
    # Convert options map back to keyword list
    import_options = Enum.map(options, fn {key, value} -> {String.to_atom(key), value} end)
    
    # Broadcast start
    broadcast_progress(:single, :started, %{
      year: year,
      status: "Importing Oscar data for #{year}..."
    })
    
    # Perform import - now uses UnifiedOscarImporter through Cultural module
    case Cultural.import_oscar_year(year, import_options) do
      {:ok, result} ->
        # The new unified importer returns a different result structure
        broadcast_progress(:single, :completed, %{
          year: year,
          movies_created: Map.get(result, :movies_created, 0),
          movies_updated: Map.get(result, :movies_updated, 0),
          movies_skipped: Map.get(result, :movies_skipped, 0),
          total_nominees: Map.get(result, :total_nominees, 0),
          ceremony_year: Map.get(result, :ceremony_year, year)
        })
        
        Logger.info("Completed Oscar import for #{year}: #{Map.get(result, :total_nominees, 0)} nominees processed")
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to import Oscar year #{year}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: %{"action" => "import_single", "year" => year}}) do
    year = ensure_integer(year)
    Logger.info("Starting Oscar import for year #{year}")
    
    # Broadcast start
    broadcast_progress(:single, :started, %{
      year: year,
      status: "Importing Oscar data for #{year}..."
    })
    
    # Perform import using unified structure
    case Cultural.import_oscar_year(year, [create_movies: true]) do
      {:ok, result} ->
        # The new unified importer returns a different result structure
        broadcast_progress(:single, :completed, %{
          year: year,
          movies_created: Map.get(result, :movies_created, 0),
          movies_updated: Map.get(result, :movies_updated, 0),
          movies_skipped: Map.get(result, :movies_skipped, 0),
          total_nominees: Map.get(result, :total_nominees, 0),
          ceremony_year: Map.get(result, :ceremony_year, year)
        })
        
        Logger.info("Completed Oscar import for #{year}: #{Map.get(result, :total_nominees, 0)} nominees processed")
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to import Oscar year #{year}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  def perform(%Oban.Job{args: %{"action" => "import_range", "start_year" => start_year, "end_year" => end_year}}) do
    start_year = ensure_integer(start_year)
    end_year = ensure_integer(end_year)
    
    Logger.info("Starting Oscar import for years #{start_year}-#{end_year}")
    
    # Broadcast start
    broadcast_progress(:range, :started, %{
      start_year: start_year,
      end_year: end_year,
      status: "Importing Oscar data for #{start_year}-#{end_year}..."
    })
    
    # Process synchronously with unified structure
    # Cultural.import_oscar_years now returns a map of results per year
    results = Cultural.import_oscar_years(start_year..end_year, [create_movies: true, async: false])
    
    # Calculate totals from the results map
    {total_created, total_updated, years_processed} = 
      Enum.reduce(results, {0, 0, 0}, fn {_year, year_result}, {created, updated, processed} ->
        case year_result do
          {:ok, data} -> 
            {created + Map.get(data, :movies_created, 0), 
             updated + Map.get(data, :movies_updated, 0),
             processed + 1}
          _ -> 
            {created, updated, processed}
        end
      end)
    
    broadcast_progress(:range, :completed, %{
      start_year: start_year,
      end_year: end_year,
      total_movies_created: total_created,
      total_movies_updated: total_updated,
      years_processed: years_processed
    })
    
    Logger.info("Completed Oscar import for #{start_year}-#{end_year}: #{years_processed} years processed")
    :ok
  end
  
  def perform(%Oban.Job{args: %{"action" => "import_all_years"}}) do
    Logger.info("Starting Oscar import for all years (2016-2024)")
    
    # Broadcast start
    broadcast_progress(:all, :started, %{
      status: "Importing all Oscar ceremonies (2016-2024)..."
    })
    
    # Import all years synchronously with unified structure
    results = Cultural.import_all_oscar_years([create_movies: true, async: false])
    
    # Calculate totals from the results map
    {total_created, total_updated, years_processed} = 
      Enum.reduce(results, {0, 0, 0}, fn {_year, year_result}, {created, updated, processed} ->
        case year_result do
          {:ok, data} -> 
            {created + Map.get(data, :movies_created, 0), 
             updated + Map.get(data, :movies_updated, 0),
             processed + 1}
          _ -> 
            {created, updated, processed}
        end
      end)
    
    broadcast_progress(:all, :completed, %{
      total_movies_created: total_created,
      total_movies_updated: total_updated,
      years_processed: years_processed
    })
    
    Logger.info("Completed Oscar import for all years: #{years_processed} years processed")
    :ok
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
end