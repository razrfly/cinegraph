defmodule Cinegraph.Workers.PredictionsOrchestrator do
  @moduledoc """
  Orchestrates the calculation of predictions by splitting work into smaller jobs.
  This avoids timeout issues and allows partial progress to be saved.
  """
  
  use Oban.Worker, queue: :predictions, max_attempts: 3
  
  require Logger
  
  alias Cinegraph.Repo
  alias Cinegraph.Metrics.{MetricWeightProfile, ScoringService}
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "orchestrate", "profile_id" => profile_id}}) do
    Logger.info("Orchestrating predictions calculation for profile #{profile_id}")
    
    profile = Repo.get!(MetricWeightProfile, profile_id)
    
    # Define all decades we want to process
    decades = [1920, 1930, 1940, 1950, 1960, 1970, 1980, 1990, 2000, 2010, 2020]
    
    # Build job list with predictions AND validations for each decade
    prediction_jobs = Enum.map(decades, fn decade ->
      %{action: "calculate_predictions", profile_id: profile_id, decade: decade}
    end)
    
    validation_jobs = Enum.map(decades, fn decade ->
      %{action: "calculate_validation", profile_id: profile_id, decade: decade}
    end)
    
    # Combine all jobs in order
    jobs = 
      prediction_jobs ++  # First calculate predictions for all decades
      validation_jobs ++  # Then calculate validations for all decades
      [
        # Finally, aggregate and compare
        %{action: "aggregate_validation", profile_id: profile_id},
        %{action: "calculate_comparison", profile_id: profile_id}
      ]
    
    # Insert all jobs with proper scheduling
    jobs
    |> Enum.with_index()
    |> Enum.each(fn {args, index} ->
      # Add a small delay between jobs to avoid overload
      delay = index * 2 # 2 seconds between each job
      
      args
      |> Cinegraph.Workers.PredictionsWorker.new(schedule_in: delay)
      |> Oban.insert()
    end)
    
    Logger.info("Queued #{length(jobs)} prediction calculation jobs for profile #{profile.name}")
    
    :ok
  end
  
  @doc """
  Start orchestration for all active profiles.
  """
  def orchestrate_all_profiles do
    profiles = ScoringService.get_all_profiles()
    
    Enum.each(profiles, fn profile ->
      %{action: "orchestrate", profile_id: profile.id}
      |> new()
      |> Oban.insert()
    end)
    
    Logger.info("Started orchestration for #{length(profiles)} profiles")
  end
  
  @doc """
  Start orchestration for the default profile.
  """
  def orchestrate_default_profile do
    profile = ScoringService.get_default_profile()
    
    result = %{action: "orchestrate", profile_id: profile.id}
    |> new()
    |> Oban.insert()
    
    Logger.info("Started orchestration for default profile: #{profile.name}")
    
    result
  end
end