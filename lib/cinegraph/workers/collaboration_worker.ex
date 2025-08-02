defmodule Cinegraph.Workers.CollaborationWorker do
  @moduledoc """
  Oban worker for processing movie collaborations.
  
  This worker updates the collaboration data after new movies are imported.
  """
  
  use Oban.Worker, 
    queue: :collaboration,
    max_attempts: 3,
    unique: [period: 300]  # Only one collaboration job every 5 minutes
    
  alias Cinegraph.Collaborations
  require Logger
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: _args}) do
    Logger.info("Collaboration Worker starting")
    
    case Collaborations.populate_collaborations() do
      {:ok, count} ->
        Logger.info("Successfully processed #{count} collaborations")
        
        # Refresh materialized view
        case Collaborations.refresh_collaboration_trends() do
          :ok ->
            Logger.info("Refreshed collaboration trends materialized view")
          error ->
            Logger.warning("Failed to refresh materialized view: #{inspect(error)}")
        end
        
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to process collaborations: #{inspect(reason)}")
        {:error, reason}
    end
  end
end