defmodule Cinegraph.Performance.Benchmark do
  @moduledoc """
  Performance benchmarking utilities for measuring page load improvements.
  """

  alias Cinegraph.Cache.PredictionsCache

  @doc """
  Run a complete benchmark of the predictions page load.
  Returns timing data for all components.
  """
  def benchmark_predictions_page do
    IO.puts("\n=== PREDICTIONS PAGE PERFORMANCE BENCHMARK ===")
    
    # Warm up database connections and cache
    PredictionsCache.get_default_profile()
    
    # Measure complete page load simulation
    {total_time, results} = :timer.tc(fn ->
      %{
        profile_load: benchmark_profile_load(),
        predictions: benchmark_predictions(),
        validation: benchmark_validation(),
        confirmed: benchmark_confirmed_additions()
      }
    end)
    
    total_ms = total_time / 1_000
    
    IO.puts("TOTAL PAGE LOAD TIME: #{Float.round(total_ms, 1)}ms")
    IO.puts("\nBreakdown:")
    IO.puts("  Profile Load: #{results.profile_load.time_ms}ms")
    IO.puts("  Predictions: #{results.predictions.time_ms}ms (#{results.predictions.count} movies)")
    IO.puts("  Validation: #{results.validation.time_ms}ms (#{results.validation.decade_count} decades)")
    IO.puts("  Confirmed: #{results.confirmed.time_ms}ms (#{results.confirmed.count} movies)")
    
    %{
      total_time_ms: Float.round(total_ms, 1),
      components: results,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Benchmark just the predictions query (main bottleneck).
  """
  def benchmark_predictions_only(limit \\ 100) do
    profile = PredictionsCache.get_default_profile()
    
    {time_microseconds, result} = :timer.tc(fn ->
      PredictionsCache.get_predictions(limit, profile)
    end)
    
    time_ms = time_microseconds / 1_000
    
    %{
      time_ms: Float.round(time_ms, 1),
      predictions_count: length(result.predictions),
      total_candidates: result.total_candidates,
      algorithm_info: result.algorithm_info
    }
  end

  @doc """
  Benchmark cache performance with before/after comparison.
  """
  def benchmark_cache_performance do
    IO.puts("\n=== CACHE PERFORMANCE ANALYSIS ===")
    
    # Clear cache first to measure cold performance
    PredictionsCache.clear_all()
    
    # Cold performance (cache miss)
    IO.puts("\n--- Cold Performance (Cache Miss) ---")
    cold_times = for i <- 1..3 do
      IO.puts("Cold run #{i}/3...")
      result = benchmark_predictions_only()
      result.time_ms
    end
    
    # Warm performance (cache hit)  
    IO.puts("\n--- Warm Performance (Cache Hit) ---")
    warm_times = for i <- 1..3 do
      IO.puts("Warm run #{i}/3...")
      result = benchmark_predictions_only()
      result.time_ms
    end
    
    # Get cache stats
    cache_stats = PredictionsCache.get_stats()
    
    cold_avg = Enum.sum(cold_times) / length(cold_times)
    warm_avg = Enum.sum(warm_times) / length(warm_times)
    improvement = ((cold_avg - warm_avg) / cold_avg) * 100
    
    IO.puts("\n=== CACHE PERFORMANCE RESULTS ===")
    IO.puts("Cold Average: #{Float.round(cold_avg, 1)}ms")
    IO.puts("Warm Average: #{Float.round(warm_avg, 1)}ms")
    IO.puts("Performance Improvement: #{Float.round(improvement, 1)}%")
    IO.puts("Cache Hit Rate: #{cache_stats.hit_rate}%")
    
    %{
      cold_avg_ms: Float.round(cold_avg, 1),
      warm_avg_ms: Float.round(warm_avg, 1),
      improvement_percentage: Float.round(improvement, 1),
      cache_stats: cache_stats,
      cold_times: cold_times,
      warm_times: warm_times
    }
  end

  @doc """
  Run multiple benchmark iterations and return statistics.
  """
  def benchmark_multiple_runs(iterations \\ 5) do
    IO.puts("\n=== RUNNING #{iterations} BENCHMARK ITERATIONS ===")
    
    results = for i <- 1..iterations do
      IO.puts("Run #{i}/#{iterations}...")
      benchmark_predictions_only()
    end
    
    times = Enum.map(results, & &1.time_ms)
    
    %{
      iterations: iterations,
      min_time_ms: Enum.min(times),
      max_time_ms: Enum.max(times),
      avg_time_ms: Float.round(Enum.sum(times) / length(times), 1),
      median_time_ms: calculate_median(times),
      all_times: times,
      timestamp: DateTime.utc_now()
    }
  end

  # Private functions

  defp benchmark_profile_load do
    {time, profile} = :timer.tc(fn ->
      PredictionsCache.get_default_profile()
    end)
    
    %{
      time_ms: Float.round(time / 1_000, 1),
      profile_name: profile.name
    }
  end

  defp benchmark_predictions do
    {time, result} = :timer.tc(fn ->
      profile = PredictionsCache.get_default_profile()
      PredictionsCache.get_predictions(100, profile)
    end)
    
    %{
      time_ms: Float.round(time / 1_000, 1),
      count: length(result.predictions)
    }
  end

  defp benchmark_validation do
    {time, result} = :timer.tc(fn ->
      profile = PredictionsCache.get_default_profile()
      PredictionsCache.get_validation(profile)
    end)
    
    %{
      time_ms: Float.round(time / 1_000, 1),
      decade_count: length(result.decade_results),
      accuracy: result.overall_accuracy
    }
  end

  defp benchmark_confirmed_additions do
    {time, count} = :timer.tc(fn ->
      profile = PredictionsCache.get_default_profile()
      predictions_result = PredictionsCache.get_predictions(100, profile)
      PredictionsCache.get_confirmed_additions_count(predictions_result)
    end)
    
    %{
      time_ms: Float.round(time / 1_000, 1),
      count: count
    }
  end

  defp calculate_median(times) do
    sorted = Enum.sort(times)
    length = length(sorted)
    
    if rem(length, 2) == 0 do
      mid1 = Enum.at(sorted, div(length, 2) - 1)
      mid2 = Enum.at(sorted, div(length, 2))
      Float.round((mid1 + mid2) / 2, 1)
    else
      Enum.at(sorted, div(length, 2))
    end
  end
end