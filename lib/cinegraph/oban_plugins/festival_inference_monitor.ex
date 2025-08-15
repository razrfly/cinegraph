defmodule Cinegraph.ObanPlugins.FestivalInferenceMonitor do
  @moduledoc """
  Oban plugin that monitors completed FestivalDiscoveryWorker jobs and ensures
  FestivalPersonInferenceWorker is queued for non-Oscar ceremonies.
  
  This is a solution for issue #286 where person inference wasn't being
  automatically queued after festival discovery.
  """
  
  use GenServer
  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Festivals.FestivalCeremony
  alias Cinegraph.Workers.FestivalPersonInferenceWorker
  require Logger
  
  @check_interval :timer.seconds(30)
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{last_check: DateTime.utc_now()}}
  end
  
  @impl true
  def handle_info(:check_completed_jobs, state) do
    window_end = DateTime.utc_now()
    check_and_queue_inference(state.last_check, window_end)
    schedule_check()
    {:noreply, %{state | last_check: window_end}}
  end
  
  defp schedule_check do
    Process.send_after(self(), :check_completed_jobs, @check_interval)
  end
  
  defp check_and_queue_inference(since, until) do
    # Find recently completed discovery jobs
    completed_discovery_jobs = 
      from(j in Oban.Job,
        where: j.worker == "Cinegraph.Workers.FestivalDiscoveryWorker",
        where: j.state == "completed",
        where: j.completed_at > ^since and j.completed_at <= ^until,
        select: %{args: j.args, meta: j.meta}
      )
      |> Repo.all()
    
    Enum.each(completed_discovery_jobs, fn %{args: args, meta: meta} ->
      ceremony_id = args["ceremony_id"]
      
      # Skip if discovery already ran inference inline
      if meta && Map.get(meta, "person_inference_invoked") do
        Logger.debug("Skipping inference enqueue for ceremony #{ceremony_id} — discovery already invoked inference")
      else
        # Check if this is a non-Oscar ceremony
      ceremony = 
        from(fc in FestivalCeremony,
          join: fo in assoc(fc, :organization),
          where: fc.id == ^ceremony_id,
          where: fo.abbreviation != "AMPAS",
          preload: [:organization]
        )
        |> Repo.one()
      
      if ceremony do
        # Check if inference job already exists
        existing_job = 
          from(j in Oban.Job,
            where: j.worker == "Cinegraph.Workers.FestivalPersonInferenceWorker",
            where: fragment("? @> ?", j.args, ^%{"ceremony_id" => ceremony_id}),
            where: j.state in ["available", "scheduled", "executing", "completed"]
          )
          |> Repo.one()
        
        unless existing_job do
          # Queue the inference job
          job_args = %{
            "ceremony_id" => ceremony.id,
            "abbr" => ceremony.organization.abbreviation,
            "year" => ceremony.year
          }
          
          case FestivalPersonInferenceWorker.new(job_args) |> Oban.insert() do
            {:ok, job} ->
              Logger.info(
                "FestivalInferenceMonitor: Queued inference job ##{job.id} " <>
                "for #{ceremony.organization.abbreviation} #{ceremony.year}"
              )
              
            {:error, reason} ->
              Logger.error(
                "FestivalInferenceMonitor: Failed to queue inference " <>
                "for ceremony #{ceremony_id}: #{inspect(reason)}"
              )
          end
        end
      end
      end
    end)
  end
end