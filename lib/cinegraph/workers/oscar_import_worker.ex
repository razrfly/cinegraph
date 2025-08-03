defmodule Cinegraph.Workers.OscarImportWorker do
  @moduledoc """
  Worker to import Oscar ceremony data for a specific year.
  This allows parallel processing of multiple years.
  """
  
  use Oban.Worker,
    queue: :oscar_imports,
    max_attempts: 3,
    priority: 1
  
  alias Cinegraph.Cultural
  require Logger
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"year" => year} = args}) do
    options = Map.get(args, "options", [])
    
    Logger.info("Starting Oscar import for year #{year}")
    
    # The import_oscar_year now queues OscarDiscoveryWorker
    case Cultural.import_oscar_year(year, options) do
      {:ok, %{job_id: job_id}} ->
        Logger.info("Successfully queued Oscar discovery for year #{year}, job_id: #{job_id}")
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to queue Oscar import for year #{year}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end