defmodule Mix.Tasks.Pqs do
  @moduledoc """
  Mix tasks for Person Quality Score (PQS) system management and testing.
  
  Available commands:
    mix pqs.test               # Run comprehensive PQS automation test
    mix pqs.status             # Show PQS system status and health
    mix pqs.calculate [id]     # Calculate PQS for a specific person ID
    mix pqs.batch [min]        # Calculate PQS for all people with min credits
    mix pqs.monitor            # Show monitoring dashboard
    mix pqs.schedule           # Manually trigger scheduled jobs
  """

  use Mix.Task
  import Ecto.Query
  alias Cinegraph.Metrics.{PersonQualityScore, PQSMonitoring, PQSScheduler}
  require Logger

  @shortdoc "Person Quality Score system management"

  def run([]), do: run(["help"])

  def run(["help"]) do
    Mix.shell().info(@moduledoc)
  end

  def run(["test"]) do
    Mix.shell().info("Running PQS automation system test...")
    start_app()
    
    # Load and run the test module
    test_file = "test/pqs_automation_test.exs"
    if File.exists?(test_file) do
      Code.compile_file(test_file)
      
      # Check if module was successfully compiled and loaded
      module = Cinegraph.PQSAutomationTest
      if Code.ensure_loaded?(module) do
        # Use apply to avoid compile-time warning
        apply(module, :run_comprehensive_test, [])
      else
        Mix.shell().error("❌ Failed to load test module")
      end
    else
      Mix.shell().error("❌ Test file not found: #{test_file}")
      Mix.shell().info("Creating basic test module...")
      create_basic_test_module()
    end
  end

  def run(["status"]) do
    Mix.shell().info("=== PQS System Status ===")
    start_app()
    
    # Get health indicators
    health = PQSMonitoring.get_health_indicators()
    
    status_icon = case health.overall_status do
      :healthy -> "🟢"
      :warning -> "🟡"
      :critical -> "🔴"
    end
    
    Mix.shell().info("#{status_icon} Overall Status: #{health.overall_status}")
    Mix.shell().info("Coverage Healthy: #{health.coverage_healthy}")
    Mix.shell().info("Freshness Healthy: #{health.freshness_healthy}")
    Mix.shell().info("Performance Healthy: #{health.performance_healthy}")
    
    if length(health.system_alerts) > 0 do
      Mix.shell().info("\n⚠️ System Alerts:")
      Enum.each(health.system_alerts, fn alert ->
        Mix.shell().info("  - #{alert}")
      end)
    end
  end

  def run(["calculate", person_id]) do
    Mix.shell().info("Calculating PQS for person #{person_id}...")
    start_app()
    
    case Integer.parse(person_id) do
      {id, _} ->
        case PersonQualityScore.calculate_person_score(id) do
          {:ok, score, components} ->
            Mix.shell().info("✅ PQS calculated: #{score}")
            Mix.shell().info("Components: #{inspect(components)}")
            
            case PersonQualityScore.store_person_score(id, score, components) do
              {:ok, _} -> Mix.shell().info("✅ PQS stored successfully")
              {:error, error} -> Mix.shell().error("❌ Failed to store PQS: #{inspect(error)}")
            end
            
          {:error, error} ->
            Mix.shell().error("❌ Failed to calculate PQS: #{inspect(error)}")
        end
        
      :error ->
        Mix.shell().error("❌ Invalid person ID: #{person_id}")
    end
  end

  def run(["batch"]) do
    run(["batch", "5"])
  end

  def run(["batch", min_credits]) do
    Mix.shell().info("Calculating PQS for all people with min #{min_credits} credits...")
    start_app()
    
    case Integer.parse(min_credits) do
      {min, _} ->
        case PersonQualityScore.calculate_all_person_scores(min) do
          {:ok, %{total: total, successful: successful}} ->
            Mix.shell().info("✅ Batch calculation complete: #{successful}/#{total} people processed")
            
          {:error, error} ->
            Mix.shell().error("❌ Batch calculation failed: #{inspect(error)}")
        end
        
      :error ->
        Mix.shell().error("❌ Invalid min_credits: #{min_credits}")
    end
  end

  def run(["monitor"]) do
    Mix.shell().info("=== PQS Monitoring Dashboard ===")
    start_app()
    
    # Coverage metrics
    coverage = PQSMonitoring.get_coverage_metrics()
    Mix.shell().info("\n📊 Coverage Metrics:")
    Mix.shell().info("  Total People: #{coverage.total_people}")
    Mix.shell().info("  Eligible People: #{coverage.eligible_people}")
    Mix.shell().info("  People with PQS: #{coverage.people_with_pqs}")
    Mix.shell().info("  Coverage: #{coverage.coverage_percent}%")
    
    # Freshness metrics
    freshness = PQSMonitoring.get_freshness_metrics()
    Mix.shell().info("\n⏰ Freshness Metrics:")
    Mix.shell().info("  Total Scores: #{freshness.total_scores}")
    Mix.shell().info("  Fresh Scores (<7 days): #{freshness.fresh_scores} (#{freshness.fresh_percent}%)")
    Mix.shell().info("  Stale Scores: #{freshness.stale_scores} (#{freshness.stale_percent}%)")
    Mix.shell().info("  Average Age: #{freshness.average_age_days} days")
    
    # Performance metrics
    performance = PQSMonitoring.get_performance_metrics()
    Mix.shell().info("\n⚡ Performance Metrics (24h):")
    Mix.shell().info("  Total Jobs: #{performance.total_jobs_24h}")
    Mix.shell().info("  Successful: #{performance.successful_jobs_24h}")
    Mix.shell().info("  Failed: #{performance.failed_jobs_24h}")
    Mix.shell().info("  Failure Rate: #{performance.failure_rate_percent}%")
    Mix.shell().info("  Avg Duration: #{performance.average_duration_seconds}s")
    Mix.shell().info("  Queue Depth: #{performance.queue_depth}")
    
    # Role breakdown
    Mix.shell().info("\n🎭 Role Breakdown:")
    breakdown = PQSMonitoring.get_role_breakdown()
    Enum.each(breakdown, fn role ->
      Mix.shell().info("  #{role.role}: #{role.people_with_pqs}/#{role.total_people} (#{role.coverage_percent}%)")
    end)
  end

  def run(["schedule"]) do
    Mix.shell().info("Manually triggering scheduled PQS jobs...")
    start_app()
    
    # Schedule daily incremental
    case PQSScheduler.schedule_daily_incremental() do
      :ok -> Mix.shell().info("✅ Daily incremental scheduled")
      error -> Mix.shell().error("❌ Daily incremental failed: #{inspect(error)}")
    end
    
    # Schedule weekly full
    case PQSScheduler.schedule_weekly_full() do
      {:ok, _} -> Mix.shell().info("✅ Weekly full scheduled")
      error -> Mix.shell().error("❌ Weekly full failed: #{inspect(error)}")
    end
    
    # Schedule stale cleanup
    case PQSScheduler.schedule_stale_cleanup() do
      :ok -> Mix.shell().info("✅ Stale cleanup scheduled")
      error -> Mix.shell().error("❌ Stale cleanup failed: #{inspect(error)}")
    end
    
    Mix.shell().info("✅ All scheduled jobs triggered")
  end

  def run([unknown]) do
    Mix.shell().error("Unknown command: #{unknown}")
    run(["help"])
  end

  defp start_app do
    Mix.Task.run("app.start")
  end
  
  defp create_basic_test_module do
    alias Cinegraph.Metrics.PQSTriggerStrategy
    
    Mix.shell().info("Testing PQS trigger strategies...")
    
    # Test new person trigger (use a sample person ID)
    case Cinegraph.Repo.one(from p in "people", limit: 1, select: p.id) do
      nil -> Mix.shell().info("⚠️  No people found in database for testing")
      person_id -> 
        case PQSTriggerStrategy.trigger_new_person(person_id) do
          {:ok, _} -> Mix.shell().info("✅ New person trigger test passed")
          error -> Mix.shell().error("❌ New person trigger failed: #{inspect(error)}")
        end
    end
    
    # Test credit changes trigger
    case Cinegraph.Repo.one(from mc in "movie_credits", limit: 1, select: mc.person_id) do
      nil -> Mix.shell().info("⚠️  No movie credits found for testing")
      person_id -> 
        case PQSTriggerStrategy.trigger_credit_changes(person_id) do
          {:ok, _} -> Mix.shell().info("✅ Credit changes trigger test passed")
          :ok -> Mix.shell().info("✅ Credit changes trigger test passed (no jobs needed)")
          error -> Mix.shell().error("❌ Credit changes trigger failed: #{inspect(error)}")
        end
    end
    
    # Test external metrics trigger
    case Cinegraph.Repo.one(from m in "movies", limit: 1, select: m.id) do
      nil -> Mix.shell().info("⚠️  No movies found for testing")
      movie_id -> 
        case PQSTriggerStrategy.trigger_external_metrics_update(movie_id) do
          {:ok, _} -> Mix.shell().info("✅ External metrics trigger test passed")
          :ok -> Mix.shell().info("✅ External metrics trigger test passed (no jobs needed)")
          error -> Mix.shell().error("❌ External metrics trigger failed: #{inspect(error)}")
        end
    end
    
    Mix.shell().info("✅ Basic PQS automation test completed")
  end
end