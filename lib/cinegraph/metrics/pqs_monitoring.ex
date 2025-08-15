defmodule Cinegraph.Metrics.PQSMonitoring do
  @moduledoc """
  Monitoring and metrics for Person Quality Score (PQS) system.
  
  Tracks the success criteria defined in issue #292:
  - Coverage: >95% eligible people have scores
  - Freshness: >90% scores <7 days old  
  - Performance: Batch calculations <30 minutes, <1% failure rate
  - Health: Clear dashboard visibility
  """

  import Ecto.Query
  alias Cinegraph.Repo
  require Logger

  @doc """
  Get comprehensive coverage metrics for PQS system.
  """
  def get_coverage_metrics do
    total_people = count_total_people()
    eligible_people = count_eligible_people() # People with ≥3 credits
    people_with_pqs = count_people_with_pqs()
    directors_with_pqs = count_directors_with_pqs()
    actors_with_pqs = count_actors_with_pqs()
    
    %{
      total_people: total_people,
      eligible_people: eligible_people,
      people_with_pqs: people_with_pqs,
      directors_with_pqs: directors_with_pqs,
      actors_with_pqs: actors_with_pqs,
      coverage_percent: safe_percentage(people_with_pqs, eligible_people),
      director_coverage_percent: safe_percentage(directors_with_pqs.with_scores, directors_with_pqs.total),
      actor_coverage_percent: safe_percentage(actors_with_pqs.with_scores, actors_with_pqs.total),
      people_without_pqs: eligible_people - people_with_pqs,
      people_without_pqs_percent: safe_percentage(eligible_people - people_with_pqs, eligible_people)
    }
  end

  @doc """
  Get score freshness metrics.
  """
  def get_freshness_metrics do
    now = DateTime.utc_now()
    week_ago = DateTime.add(now, -7, :day)
    month_ago = DateTime.add(now, -30, :day)
    
    total_scores = count_total_scores()
    fresh_scores = count_fresh_scores(week_ago)
    stale_scores = count_stale_scores(week_ago)
    very_stale_scores = count_very_stale_scores(month_ago)
    
    avg_age = get_average_score_age()
    
    %{
      total_scores: total_scores,
      fresh_scores: fresh_scores,
      stale_scores: stale_scores,
      very_stale_scores: very_stale_scores,
      fresh_percent: safe_percentage(fresh_scores, total_scores),
      stale_percent: safe_percentage(stale_scores, total_scores),
      very_stale_percent: safe_percentage(very_stale_scores, total_scores),
      average_age_days: avg_age
    }
  end

  @doc """
  Get performance metrics for PQS calculation jobs.
  """
  def get_performance_metrics do
    recent_jobs = get_recent_pqs_jobs(24) # Last 24 hours
    
    %{
      total_jobs_24h: length(recent_jobs),
      successful_jobs_24h: count_successful_jobs(recent_jobs),
      failed_jobs_24h: count_failed_jobs(recent_jobs),
      failure_rate_percent: safe_percentage(count_failed_jobs(recent_jobs), length(recent_jobs)),
      average_duration_seconds: calculate_average_duration(recent_jobs),
      calculations_per_hour: calculate_throughput(recent_jobs),
      queue_depth: get_current_queue_depth(),
      recent_failure_count: count_recent_consecutive_failures()
    }
  end

  @doc """
  Get health indicators for system status dashboard.
  """
  def get_health_indicators do
    coverage = get_coverage_metrics()
    freshness = get_freshness_metrics()
    performance = get_performance_metrics()
    
    # Determine overall health status
    health_status = determine_health_status(coverage, freshness, performance)
    
    %{
      overall_status: health_status,
      coverage_healthy: coverage.coverage_percent >= 95.0,
      freshness_healthy: freshness.fresh_percent >= 90.0,
      performance_healthy: performance.failure_rate_percent <= 1.0,
      last_successful_batch: get_last_successful_batch(),
      system_alerts: generate_system_alerts(coverage, freshness, performance)
    }
  end

  @doc """
  Get detailed breakdown by role (directors, actors, etc.).
  """
  def get_role_breakdown do
    roles = ["Directing", "Acting", "Writing", "Producing", "Cinematography"]
    
    Enum.map(roles, fn role ->
      stats = get_role_stats(role)
      
      %{
        role: role,
        total_people: stats.total,
        people_with_pqs: stats.with_scores,
        coverage_percent: safe_percentage(stats.with_scores, stats.total),
        average_score: stats.avg_score
      }
    end)
  end

  # Private helper functions

  defp count_total_people do
    Repo.one(from p in "people", select: count(p.id)) || 0
  end

  defp count_eligible_people do
    result = Repo.all(
      from mc in "movie_credits",
        group_by: mc.person_id,
        having: count(mc.movie_id) >= 3,
        select: count()
    )
    length(result)
  end

  defp count_people_with_pqs do
    Repo.one(
      from pm in "person_metrics",
        where: pm.metric_type == "quality_score",
        select: count(fragment("DISTINCT ?", pm.person_id))
    ) || 0
  end

  defp count_directors_with_pqs do
    total = Repo.one(
      from mc in "movie_credits",
        where: mc.department == "Directing",
        select: count(fragment("DISTINCT ?", mc.person_id))
    ) || 0
    
    with_scores = Repo.one(
      from mc in "movie_credits",
        where: mc.department == "Directing",
        join: pm in "person_metrics", on: pm.person_id == mc.person_id,
        where: pm.metric_type == "quality_score",
        select: count(fragment("DISTINCT ?", mc.person_id))
    ) || 0
    
    %{total: total, with_scores: with_scores}
  end

  defp count_actors_with_pqs do
    total = Repo.one(
      from mc in "movie_credits",
        where: mc.department == "Acting",
        select: count(fragment("DISTINCT ?", mc.person_id))
    ) || 0
    
    with_scores = Repo.one(
      from mc in "movie_credits",
        where: mc.department == "Acting",
        join: pm in "person_metrics", on: pm.person_id == mc.person_id,
        where: pm.metric_type == "quality_score",
        select: count(fragment("DISTINCT ?", mc.person_id))
    ) || 0
    
    %{total: total, with_scores: with_scores}
  end

  defp count_total_scores do
    Repo.one(
      from pm in "person_metrics",
        where: pm.metric_type == "quality_score",
        select: count(pm.id)
    ) || 0
  end

  defp count_fresh_scores(cutoff_date) do
    Repo.one(
      from pm in "person_metrics", 
        where: pm.metric_type == "quality_score" and pm.calculated_at >= ^cutoff_date,
        select: count(pm.id)
    ) || 0
  end

  defp count_stale_scores(cutoff_date) do
    Repo.one(
      from pm in "person_metrics",
        where: pm.metric_type == "quality_score" and pm.calculated_at < ^cutoff_date,
        select: count(pm.id)
    ) || 0
  end

  defp count_very_stale_scores(cutoff_date) do
    Repo.one(
      from pm in "person_metrics",
        where: pm.metric_type == "quality_score" and pm.calculated_at < ^cutoff_date,
        select: count(pm.id)
    ) || 0
  end

  defp get_average_score_age do
    result = Repo.one(
      from pm in "person_metrics",
        where: pm.metric_type == "quality_score",
        select: avg(fragment("EXTRACT(EPOCH FROM (NOW() - ?))", pm.calculated_at))
    )
    
    case result do
      nil -> 0.0
      %Decimal{} = decimal -> Float.round(Decimal.to_float(decimal) / 86400, 1) # Convert to days
      seconds when is_number(seconds) -> Float.round(seconds / 86400, 1) # Convert to days
      _ -> 0.0
    end
  end

  defp get_recent_pqs_jobs(hours_back) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours_back, :hour)
    
    Repo.all(
      from j in "oban_jobs",
        where: j.worker == "Cinegraph.Workers.PersonQualityScoreWorker" and j.inserted_at >= ^cutoff,
        select: %{
          id: j.id,
          state: j.state,
          inserted_at: j.inserted_at,
          completed_at: j.completed_at,
          cancelled_at: j.cancelled_at,
          discarded_at: j.discarded_at
        }
    )
  end

  defp count_successful_jobs(jobs) do
    Enum.count(jobs, fn job -> job.state == "completed" end)
  end

  defp count_failed_jobs(jobs) do
    Enum.count(jobs, fn job -> job.state in ["cancelled", "discarded"] end)
  end

  defp calculate_average_duration(jobs) do
    completed_jobs = Enum.filter(jobs, fn job -> 
      job.state == "completed" and not is_nil(job.completed_at) and not is_nil(job.inserted_at)
    end)
    
    if length(completed_jobs) > 0 do
      total_seconds = Enum.reduce(completed_jobs, 0, fn job, acc ->
        # Convert NaiveDateTime to DateTime if needed
        completed_at = case job.completed_at do
          %NaiveDateTime{} = naive -> DateTime.from_naive!(naive, "Etc/UTC")
          %DateTime{} = dt -> dt
        end
        
        inserted_at = case job.inserted_at do
          %NaiveDateTime{} = naive -> DateTime.from_naive!(naive, "Etc/UTC")
          %DateTime{} = dt -> dt
        end
        
        duration = DateTime.diff(completed_at, inserted_at, :second)
        acc + duration
      end)
      
      Float.round(total_seconds / length(completed_jobs), 1)
    else
      0.0
    end
  end

  defp calculate_throughput(jobs) do
    if length(jobs) > 0 do
      Float.round(length(jobs) / 24, 1) # Jobs per hour over 24 hours
    else
      0
    end
  end

  defp get_current_queue_depth do
    Repo.one(
      from j in "oban_jobs",
        where: j.worker == "Cinegraph.Workers.PersonQualityScoreWorker" and j.state in ["available", "scheduled"],
        select: count(j.id)
    ) || 0
  end

  defp count_recent_consecutive_failures do
    recent_jobs = Repo.all(
      from j in "oban_jobs",
        where: j.worker == "Cinegraph.Workers.PersonQualityScoreWorker",
        order_by: [desc: j.inserted_at],
        limit: 10,
        select: j.state
    )
    
    # Count consecutive failures from most recent
    Enum.reduce_while(recent_jobs, 0, fn state, acc ->
      if state in ["cancelled", "discarded"] do
        {:cont, acc + 1}
      else
        {:halt, acc}
      end
    end)
  end

  defp get_role_stats(role) do
    result = Repo.one(
      from mc in "movie_credits",
        where: mc.department == ^role,
        left_join: pm in "person_metrics", on: pm.person_id == mc.person_id and pm.metric_type == "quality_score",
        select: %{
          total: count(fragment("DISTINCT ?", mc.person_id)),
          with_scores: count(fragment("DISTINCT ?", pm.person_id)),
          avg_score: avg(pm.score)
        }
    )
    
    result || %{total: 0, with_scores: 0, avg_score: 0}
  end

  defp get_last_successful_batch do
    Repo.one(
      from j in "oban_jobs",
        where: j.worker == "Cinegraph.Workers.PersonQualityScoreWorker" and j.state == "completed",
        order_by: [desc: j.completed_at],
        limit: 1,
        select: j.completed_at
    )
  end

  defp determine_health_status(coverage, freshness, performance) do
    cond do
      coverage.coverage_percent >= 95.0 and freshness.fresh_percent >= 90.0 and performance.failure_rate_percent <= 1.0 ->
        :healthy
      coverage.coverage_percent >= 80.0 and freshness.fresh_percent >= 70.0 and performance.failure_rate_percent <= 5.0 ->
        :warning  
      true ->
        :critical
    end
  end

  defp generate_system_alerts(coverage, freshness, performance) do
    alerts = []
    
    alerts = if coverage.coverage_percent < 95.0 do
      ["Low coverage: #{coverage.coverage_percent}% (target: 95%)" | alerts]
    else
      alerts
    end
    
    alerts = if freshness.fresh_percent < 90.0 do
      ["Stale scores: #{freshness.stale_percent}% scores >7 days old (target: <10%)" | alerts]
    else
      alerts
    end
    
    alerts = if performance.failure_rate_percent > 1.0 do
      ["High failure rate: #{performance.failure_rate_percent}% (target: <1%)" | alerts]
    else
      alerts
    end
    
    alerts = if performance.recent_failure_count >= 5 do
      ["Consecutive failures: #{performance.recent_failure_count} recent failures" | alerts]
    else
      alerts
    end
    
    alerts
  end

  defp safe_percentage(_numerator, 0), do: 0.0
  defp safe_percentage(numerator, denominator) do
    Float.round(numerator * 100.0 / denominator, 1)
  end
end