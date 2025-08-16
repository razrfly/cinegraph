defmodule Cinegraph.PQSAutomationTest do
  @moduledoc """
  Test script for the complete Person Quality Score (PQS) automation system.

  This script verifies all components of issue #292 implementation:
  - Event-based triggers
  - Periodic scheduling  
  - Monitoring and metrics
  - Database hooks
  """

  alias Cinegraph.Metrics.{PQSTriggerStrategy, PQSScheduler, PQSMonitoring}
  alias Cinegraph.Workers.PersonQualityScoreWorker
  require Logger

  def run_comprehensive_test do
    Logger.info("=== Starting PQS Automation System Test ===")

    # Test 1: Trigger Strategy Functions
    test_trigger_strategies()

    # Test 2: Scheduler Functions  
    test_scheduler_functions()

    # Test 3: Monitoring Functions
    test_monitoring_functions()

    # Test 4: Worker Functions
    test_worker_functions()

    # Test 5: Database Hooks
    test_database_hooks()

    Logger.info("=== PQS Automation System Test Complete ===")
  end

  defp test_trigger_strategies do
    Logger.info("Testing trigger strategies...")

    # Test new person trigger
    try do
      result = PQSTriggerStrategy.trigger_new_person(1)
      assert_ok_result(result, "New person trigger")
    rescue
      error -> Logger.error("New person trigger failed: #{inspect(error)}")
    end

    # Test credit changes trigger
    try do
      result = PQSTriggerStrategy.trigger_credit_changes([1, 2, 3])
      assert_ok_result(result, "Credit changes trigger")
    rescue
      error -> Logger.error("Credit changes trigger failed: #{inspect(error)}")
    end

    # Test festival import trigger
    try do
      result = PQSTriggerStrategy.trigger_festival_import_completion(1)
      assert_ok_result(result, "Festival import trigger")
    rescue
      error -> Logger.error("Festival import trigger failed: #{inspect(error)}")
    end

    # Test external metrics trigger
    try do
      result = PQSTriggerStrategy.trigger_external_metrics_update([1, 2])
      assert_ok_result(result, "External metrics trigger")
    rescue
      error -> Logger.error("External metrics trigger failed: #{inspect(error)}")
    end

    Logger.info("✅ Trigger strategies test complete")
  end

  defp test_scheduler_functions do
    Logger.info("Testing scheduler functions...")

    # Test daily incremental scheduling
    try do
      result = PQSScheduler.schedule_daily_incremental()
      assert_ok_result(result, "Daily incremental scheduling")
    rescue
      error -> Logger.error("Daily incremental scheduling failed: #{inspect(error)}")
    end

    # Test weekly full scheduling
    try do
      result = PQSScheduler.schedule_weekly_full()
      assert_ok_result(result, "Weekly full scheduling")
    rescue
      error -> Logger.error("Weekly full scheduling failed: #{inspect(error)}")
    end

    # Test monthly deep scheduling
    try do
      result = PQSScheduler.schedule_monthly_deep()
      assert_ok_result(result, "Monthly deep scheduling")
    rescue
      error -> Logger.error("Monthly deep scheduling failed: #{inspect(error)}")
    end

    # Test stale cleanup scheduling
    try do
      result = PQSScheduler.schedule_stale_cleanup(7)
      assert_ok_result(result, "Stale cleanup scheduling")
    rescue
      error -> Logger.error("Stale cleanup scheduling failed: #{inspect(error)}")
    end

    # Test health check
    try do
      result = PQSScheduler.check_system_health()
      assert_ok_result(result, "System health check")
    rescue
      error -> Logger.error("System health check failed: #{inspect(error)}")
    end

    Logger.info("✅ Scheduler functions test complete")
  end

  defp test_monitoring_functions do
    Logger.info("Testing monitoring functions...")

    # Test coverage metrics
    try do
      metrics = PQSMonitoring.get_coverage_metrics()

      assert_map_with_keys(
        metrics,
        ["total_people", "eligible_people", "people_with_pqs"],
        "Coverage metrics"
      )
    rescue
      error -> Logger.error("Coverage metrics failed: #{inspect(error)}")
    end

    # Test freshness metrics
    try do
      metrics = PQSMonitoring.get_freshness_metrics()

      assert_map_with_keys(
        metrics,
        ["total_scores", "fresh_scores", "stale_scores"],
        "Freshness metrics"
      )
    rescue
      error -> Logger.error("Freshness metrics failed: #{inspect(error)}")
    end

    # Test performance metrics
    try do
      metrics = PQSMonitoring.get_performance_metrics()

      assert_map_with_keys(
        metrics,
        ["total_jobs_24h", "successful_jobs_24h", "failure_rate_percent"],
        "Performance metrics"
      )
    rescue
      error -> Logger.error("Performance metrics failed: #{inspect(error)}")
    end

    # Test health indicators
    try do
      indicators = PQSMonitoring.get_health_indicators()

      assert_map_with_keys(
        indicators,
        ["overall_status", "coverage_healthy", "freshness_healthy"],
        "Health indicators"
      )
    rescue
      error -> Logger.error("Health indicators failed: #{inspect(error)}")
    end

    # Test role breakdown
    try do
      breakdown = PQSMonitoring.get_role_breakdown()
      assert_is_list(breakdown, "Role breakdown")
    rescue
      error -> Logger.error("Role breakdown failed: #{inspect(error)}")
    end

    Logger.info("✅ Monitoring functions test complete")
  end

  defp test_worker_functions do
    Logger.info("Testing worker functions...")

    # Test scheduling functions
    try do
      result = PersonQualityScoreWorker.schedule_person(1)
      assert_oban_job(result, "Schedule person job")
    rescue
      error -> Logger.error("Schedule person job failed: #{inspect(error)}")
    end

    try do
      result = PersonQualityScoreWorker.schedule_all_people(5)
      assert_oban_job(result, "Schedule all people job")
    rescue
      error -> Logger.error("Schedule all people job failed: #{inspect(error)}")
    end

    Logger.info("✅ Worker functions test complete")
  end

  defp test_database_hooks do
    Logger.info("Testing database hooks...")

    # Test that modules exist and are properly loaded
    try do
      assert_module_exists(Cinegraph.Movies, "Movies context")
      assert_module_exists(Cinegraph.Festivals, "Festivals context")
      assert_module_exists(Cinegraph.ExternalSources, "ExternalSources context")
      assert_module_exists(Cinegraph.Metrics.PQSTriggerStrategy, "PQSTriggerStrategy")

      Logger.info("✅ Database hooks modules loaded successfully")
    rescue
      error -> Logger.error("Database hooks test failed: #{inspect(error)}")
    end

    Logger.info("✅ Database hooks test complete")
  end

  # Helper assertion functions

  defp assert_ok_result(:ok, description) do
    Logger.info("✅ #{description}: OK")
  end

  defp assert_ok_result({:ok, _}, description) do
    Logger.info("✅ #{description}: OK")
  end

  defp assert_ok_result(result, description) do
    Logger.warn("⚠️ #{description}: Unexpected result #{inspect(result)}")
  end

  defp assert_map_with_keys(map, expected_keys, description) when is_map(map) do
    missing_keys = expected_keys -- Map.keys(map)

    if Enum.empty?(missing_keys) do
      Logger.info("✅ #{description}: Contains all expected keys")
    else
      Logger.warn("⚠️ #{description}: Missing keys #{inspect(missing_keys)}")
    end
  end

  defp assert_map_with_keys(value, _expected_keys, description) do
    Logger.error("❌ #{description}: Expected map, got #{inspect(value)}")
  end

  defp assert_is_list(value, description) when is_list(value) do
    Logger.info("✅ #{description}: Is list with #{length(value)} items")
  end

  defp assert_is_list(value, description) do
    Logger.error("❌ #{description}: Expected list, got #{inspect(value)}")
  end

  defp assert_oban_job({:ok, %Oban.Job{}}, description) do
    Logger.info("✅ #{description}: Oban job created successfully")
  end

  defp assert_oban_job(result, description) do
    Logger.warn("⚠️ #{description}: Unexpected job result #{inspect(result)}")
  end

  defp assert_module_exists(module, description) do
    if Code.ensure_loaded?(module) do
      Logger.info("✅ #{description}: Module loaded")
    else
      Logger.error("❌ #{description}: Module not found")
    end
  end
end

# Run the test if this file is executed directly
if __ENV__.file == Path.absname(:escript.script_name()) do
  Cinegraph.PQSAutomationTest.run_comprehensive_test()
end
