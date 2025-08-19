defmodule Cinegraph.Predictions.RefreshManager do
  @moduledoc """
  Manages manual refresh of prediction caches.
  Coordinates Oban jobs and provides staleness information.
  """
  
  alias Cinegraph.{Repo, Workers.PredictionCalculator}
  alias Cinegraph.Predictions.StalenessTracker
  import Ecto.Query
  
  @doc """
  Queue a full refresh of all predictions.
  Returns the Oban job that was created.
  """
  def refresh_all_predictions(opts \\ []) do
    job_args = %{
      "type" => "full_refresh",
      "job_id" => Ecto.UUID.generate()
    }
    
    job_args = 
      job_args
      |> maybe_add_option(opts, :profile_ids, "profile_ids")
      |> maybe_add_option(opts, :decades, "decades")
    
    PredictionCalculator.new(job_args)
    |> Oban.insert()
  end
  
  @doc """
  Queue refresh for specific decades only.
  """
  def refresh_decades(decades, _opts \\ []) do
    job_args = %{
      "type" => "selective",
      "decades" => decades
    }
    
    PredictionCalculator.new(job_args)
    |> Oban.insert()
  end
  
  @doc """
  Queue refresh for a specific decade and profile.
  """
  def refresh_decade_profile(decade, profile_id) do
    job_args = %{
      "type" => "decade",
      "decade" => decade,
      "profile_id" => profile_id
    }
    
    PredictionCalculator.new(job_args)
    |> Oban.insert()
  end
  
  @doc """
  Check if any refresh jobs are currently running.
  """
  def refresh_in_progress? do
    Repo.exists?(
      from j in "oban_jobs",
        where: j.worker == "Elixir.Cinegraph.Workers.PredictionCalculator",
        where: j.state in ["available", "executing", "scheduled"]
    )
  end
  
  @doc """
  Get the progress of currently running refresh job.
  """
  def get_refresh_progress do
    case get_active_refresh_job() do
      nil -> 
        nil
        
      job ->
        meta = job.meta || %{}
        %{
          progress: Map.get(meta, "progress", 0),
          message: Map.get(meta, "message", "Starting..."),
          started_at: job.attempted_at || job.scheduled_at,
          job_id: job.id
        }
    end
  end
  
  @doc """
  Get staleness information for predictions.
  """
  def check_staleness do
    staleness_data = StalenessTracker.get_staleness_report()
    last_refresh = get_last_refresh_time()
    
    %{
      last_refresh: last_refresh,
      movies_updated_since: staleness_data.changes_since.movies,
      metrics_updated_since: staleness_data.changes_since.metrics,
      festivals_updated_since: staleness_data.changes_since.festivals,
      stale_decades: staleness_data.affected_decades,
      recommendation: calculate_recommendation(staleness_data),
      days_since_refresh: calculate_days_since(last_refresh)
    }
  end
  
  @doc """
  Cancel any running refresh jobs.
  """
  def cancel_refresh do
    Repo.update_all(
      from(j in "oban_jobs",
        where: j.worker == "Elixir.Cinegraph.Workers.PredictionCalculator",
        where: j.state in ["available", "scheduled"]
      ),
      set: [state: "cancelled"]
    )
  end
  
  @doc """
  Get history of recent refresh jobs.
  """
  def get_refresh_history(limit \\ 10) do
    Repo.all(
      from j in "oban_jobs",
        where: j.worker == "Elixir.Cinegraph.Workers.PredictionCalculator",
        where: j.state in ["completed", "discarded", "cancelled"],
        order_by: [desc: j.completed_at],
        limit: ^limit,
        select: %{
          id: j.id,
          state: j.state,
          started_at: j.attempted_at,
          completed_at: j.completed_at,
          args: j.args,
          errors: j.errors,
          meta: j.meta
        }
    )
  end
  
  @doc """
  Clear all prediction caches.
  WARNING: This will force recalculation on next access.
  """
  def clear_all_caches do
    Repo.delete_all("prediction_cache")
    StalenessTracker.clear_tracking()
  end
  
  defp get_active_refresh_job do
    Repo.one(
      from j in "oban_jobs",
        where: j.worker == "Elixir.Cinegraph.Workers.PredictionCalculator",
        where: j.state == "executing",
        order_by: [desc: j.attempted_at],
        limit: 1
    )
  end
  
  defp get_last_refresh_time do
    case Repo.one(
      from pc in "prediction_cache",
        select: max(pc.calculated_at)
    ) do
      nil -> nil
      %NaiveDateTime{} = naive_dt -> DateTime.from_naive!(naive_dt, "Etc/UTC")
      %DateTime{} = dt -> dt
    end
  end
  
  defp calculate_recommendation(staleness_data) do
    total_changes = 
      staleness_data.changes_since.movies +
      staleness_data.changes_since.metrics +
      staleness_data.changes_since.festivals
    
    days_old = calculate_days_since(get_last_refresh_time())
    
    cond do
      # No cache exists
      is_nil(get_last_refresh_time()) ->
        :refresh_required
        
      # Too many changes
      total_changes > 500 ->
        :refresh_recommended
        
      # Significant changes in important areas
      staleness_data.changes_since.festivals > 10 ->
        :refresh_recommended
        
      # Cache is old
      days_old > 30 ->
        :refresh_recommended
        
      # Moderate changes
      total_changes > 100 ->
        :refresh_suggested
        
      # Cache is very old
      days_old > 7 && total_changes > 50 ->
        :refresh_suggested
        
      # Everything is relatively fresh
      true ->
        :up_to_date
    end
  end
  
  defp calculate_days_since(nil), do: 999
  defp calculate_days_since(datetime) do
    DateTime.diff(DateTime.utc_now(), datetime, :day)
  end
  
  defp maybe_add_option(job_args, opts, key, arg_key) do
    case Keyword.get(opts, key) do
      nil -> job_args
      value -> Map.put(job_args, arg_key, value)
    end
  end
end