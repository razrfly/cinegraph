defmodule Cinegraph.Metrics.PQSScheduler do
  @moduledoc """
  Handles periodic recalculation scheduling for Person Quality Scores (PQS).
  
  Implements the periodic strategies defined in issue #292:
  - Daily Incremental Update (3 AM daily, recent active people)
  - Weekly Full Recalculation (2 AM Sunday, people with ≥5 credits)  
  - Monthly Deep Recalculation (1 AM first Sunday, entire database)
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Workers.PersonQualityScoreWorker
  alias Cinegraph.Metrics.PQSMonitoring
  require Logger

  @doc """
  Schedule daily incremental PQS update for recently active people.
  Targets people who have had activity in the last 7 days.
  """
  def schedule_daily_incremental do
    Logger.info("Starting daily incremental PQS update")
    
    # Get people with recent activity (new credits, festival nominations, etc.)
    recent_people = get_recently_active_people(7) # Last 7 days
    
    if length(recent_people) > 0 do
      Logger.info("Scheduling daily incremental PQS for #{length(recent_people)} recently active people")
      
      %{
        batch: "daily_incremental",
        person_ids: recent_people,
        trigger: "daily_scheduled",
        min_credits: 1 # Include all active people
      }
      |> PersonQualityScoreWorker.new()
      |> Oban.insert()
    else
      Logger.info("No recently active people found for daily incremental update")
      :ok
    end
  end

  @doc """
  Schedule weekly full recalculation for people with significant credits.
  Targets people with ≥5 credits for comprehensive update.
  """
  def schedule_weekly_full do
    Logger.info("Starting weekly full PQS recalculation")
    
    %{
      batch: "weekly_full",
      trigger: "weekly_scheduled",
      min_credits: 5
    }
    |> PersonQualityScoreWorker.new()
    |> Oban.insert()
  end

  @doc """
  Schedule monthly deep recalculation for entire database.
  Comprehensive recalculation of all people regardless of credit count.
  """
  def schedule_monthly_deep do
    Logger.info("Starting monthly deep PQS recalculation") 
    
    %{
      batch: "monthly_deep",
      trigger: "monthly_scheduled", 
      min_credits: 1 # Include everyone
    }
    |> PersonQualityScoreWorker.new()
    |> Oban.insert()
  end

  @doc """
  Schedule stale score cleanup - recalculate scores older than specified days.
  Used by monitoring to maintain score freshness.
  """
  def schedule_stale_cleanup(max_age_days \\ 7) do
    stale_people = get_people_with_stale_scores(max_age_days)
    
    if length(stale_people) > 0 do
      Logger.info("Scheduling stale score cleanup for #{length(stale_people)} people (scores older than #{max_age_days} days)")
      
      %{
        batch: "stale_cleanup",
        person_ids: stale_people,
        trigger: "stale_cleanup",
        max_age_days: max_age_days
      }
      |> PersonQualityScoreWorker.new()
      |> Oban.insert()
    else
      Logger.debug("No stale scores found for cleanup")
      :ok
    end
  end

  @doc """
  Check system health and trigger emergency recalculation if needed.
  Implements quality assurance triggers from issue requirements.
  """
  def check_system_health do
    coverage = PQSMonitoring.get_coverage_metrics()
    
    # Trigger emergency recalculation if >10% of people lack PQS for 48+ hours
    if coverage.people_without_pqs_percent > 10.0 do
      reason = "Coverage below threshold: #{coverage.people_without_pqs_percent}% people without PQS"
      Logger.warning("PQS system health check failed: #{reason}")
      
      Cinegraph.Metrics.PQSTriggerStrategy.trigger_quality_assurance_recalculation(reason)
    end
    
    # Check for consecutive failures
    performance = PQSMonitoring.get_performance_metrics()
    if performance.recent_failure_count >= 5 do
      reason = "High failure rate: #{performance.recent_failure_count} consecutive failures"
      Logger.warning("PQS system health check failed: #{reason}")
      
      Cinegraph.Metrics.PQSTriggerStrategy.trigger_quality_assurance_recalculation(reason)
    end
    
    :ok
  end

  @doc """
  Get cron configuration for Oban scheduling.
  Call this from application configuration.
  """
  def get_cron_config do
    [
      # Daily incremental at 3 AM
      {"0 3 * * *", __MODULE__, :schedule_daily_incremental, []},
      # Weekly full recalculation at 2 AM Sunday  
      {"0 2 * * SUN", __MODULE__, :schedule_weekly_full, []},
      # Monthly deep recalculation at 1 AM first Sunday of month
      {"0 1 1-7 * SUN", __MODULE__, :schedule_monthly_deep, []},
      # Health check every 6 hours
      {"0 */6 * * *", __MODULE__, :check_system_health, []},
      # Stale cleanup every 12 hours
      {"0 */12 * * *", __MODULE__, :schedule_stale_cleanup, []}
    ]
  end

  # Private helper functions

  defp get_recently_active_people(days_back) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days_back, :day)
    
    # People with recent movie credits
    recent_credits = 
      from(mc in "movie_credits",
        where: mc.inserted_at >= ^cutoff_date,
        distinct: [mc.person_id],
        select: mc.person_id
      )
      |> Repo.all()

    # People with recent festival nominations
    recent_festivals =
      from(nom in "festival_nominations", 
        where: nom.inserted_at >= ^cutoff_date and not is_nil(nom.person_id),
        distinct: [nom.person_id],
        select: nom.person_id
      )
      |> Repo.all()

    # People in movies with recent external metrics updates
    recent_metrics =
      from(em in "external_metrics",
        where: em.updated_at >= ^cutoff_date,
        join: mc in "movie_credits", on: mc.movie_id == em.movie_id,
        distinct: [mc.person_id],
        select: mc.person_id
      )
      |> Repo.all()

    (recent_credits ++ recent_festivals ++ recent_metrics)
    |> Enum.uniq()
  end

  defp get_people_with_stale_scores(max_age_days) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-max_age_days, :day)
    
    from(pm in "person_metrics",
      where: pm.metric_type == "quality_score" and pm.calculated_at < ^cutoff_date,
      select: pm.person_id
    )
    |> Repo.all()
  end
end