#!/usr/bin/env elixir

alias Cinegraph.Services.TMDb
alias Cinegraph.Services.TMDb.FallbackSearch
alias Cinegraph.Metrics.ApiTracker

IO.puts("🔍 Comprehensive API Resilience System Verification")
IO.puts("=" <> String.duplicate("=", 60))

# Test various scenarios to populate metrics
test_movies = [
  %{imdb_id: "tt0111161", title: "The Shawshank Redemption", year: 1994},
  %{imdb_id: "tt0068646", title: "The Godfather", year: 1972},
  %{imdb_id: "tt0071562", title: "The Godfather: Part II", year: 1974},
  %{imdb_id: "tt0468569", title: "The Dark Knight", year: 2008},
  %{imdb_id: "tt0050083", title: "12 Angry Men", year: 1957}
]

failed_searches = [
  %{imdb_id: nil, title: "NonExistentMovie12345", year: 2099},
  %{imdb_id: "tt9999999", title: "Another Fake Movie", year: 2098}
]

IO.puts("\n🎬 Testing successful movie lookups...")
Enum.with_index(test_movies, 1) |> Enum.each(fn {movie, idx} ->
  IO.puts("  #{idx}. Testing #{movie.title} (#{movie.year})")
  
  # Test direct lookup
  result1 = TMDb.find_by_imdb_id(movie.imdb_id)
  success1 = match?({:ok, _}, result1)
  
  # Test fallback search
  result2 = FallbackSearch.find_movie(movie.imdb_id, movie.title, movie.year)
  success2 = match?({:ok, _}, result2)
  
  IO.puts("     Direct: #{if success1, do: "✅", else: "❌"} | Fallback: #{if success2, do: "✅", else: "❌"}")
  
  # Small delay to spread out requests
  Process.sleep(200)
end)

IO.puts("\n💥 Testing failed searches (to generate error metrics)...")
Enum.with_index(failed_searches, 1) |> Enum.each(fn {movie, idx} ->
  IO.puts("  #{idx}. Testing #{movie.title} (expected to fail)")
  
  result = FallbackSearch.find_movie(movie.imdb_id, movie.title, movie.year)
  success = match?({:ok, _}, result)
  
  IO.puts("     Result: #{if success, do: "Unexpected success", else: "Failed as expected ✅"}")
  
  Process.sleep(200)
end)

# Wait for metrics to be recorded
IO.puts("\n⏳ Waiting for metrics to be recorded...")
Process.sleep(2000)

# Get comprehensive statistics
IO.puts("\n📊 Current API Statistics")
IO.puts("-" <> String.duplicate("-", 50))

stats = ApiTracker.get_all_stats(1)
if length(stats) > 0 do
  Enum.each(stats, fn stat ->
    status_icon = if stat.success_rate >= 80, do: "🟢", else: (if stat.success_rate >= 50, do: "🟡", else: "🔴")
    IO.puts("#{status_icon} #{stat.source}/#{stat.operation}")
    
    avg_time = case stat.avg_response_time do
      %Decimal{} = decimal -> Decimal.to_float(decimal)
      nil -> 0.0
      time -> time
    end
    
    IO.puts("     Calls: #{stat.total} | Success: #{stat.success_rate}% | Avg: #{Float.round(avg_time, 1)}ms")
  end)
else
  IO.puts("ℹ️  No metrics recorded yet")
end

# Get fallback strategy performance
IO.puts("\n🔄 TMDb Fallback Strategy Performance")
IO.puts("-" <> String.duplicate("-", 50))

fallback_stats = ApiTracker.get_tmdb_fallback_stats(1)
if length(fallback_stats) > 0 do
  Enum.each(fallback_stats, fn stat ->
    success_rate = if stat.total > 0, do: Float.round(stat.successful / stat.total * 100, 1), else: 0.0
    confidence = Float.round(stat.avg_confidence || 0, 2)
    
    level_name = case stat.level do
      1 -> "Direct IMDb"
      2 -> "Exact Title+Year"  
      3 -> "Normalized Title"
      4 -> "Year Tolerant"
      5 -> "Fuzzy Title"
      6 -> "Broad Search"
      _ -> "Level #{stat.level}"
    end
    
    status = cond do
      success_rate >= 80 -> "🟢"
      success_rate >= 50 -> "🟡"
      true -> "🔴"
    end
    
    IO.puts("#{status} Level #{stat.level} (#{level_name})")
    IO.puts("     Attempts: #{stat.total} | Success: #{success_rate}% | Avg Confidence: #{confidence}")
  end)
else
  IO.puts("ℹ️  No fallback metrics recorded yet")
end

# Test error tracking
IO.puts("\n❌ Error Distribution Analysis")
IO.puts("-" <> String.duplicate("-", 50))

error_dist = ApiTracker.get_error_distribution("tmdb", 1)
if length(error_dist) > 0 do
  Enum.each(error_dist, fn error ->
    IO.puts("🔴 #{error.error_type}: #{error.count} occurrences")
  end)
else
  IO.puts("✅ No errors recorded in the last hour")
end

IO.puts("\n🎯 System Health Summary")
IO.puts("=" <> String.duplicate("=", 60))

overall_stats = ApiTracker.get_all_stats(1)
total_calls = Enum.sum(Enum.map(overall_stats, & &1.total))
successful_calls = Enum.sum(Enum.map(overall_stats, & &1.successful))
overall_success_rate = if total_calls > 0, do: Float.round(successful_calls / total_calls * 100, 1), else: 0.0

avg_response_time = if length(overall_stats) > 0 do
  times = Enum.map(overall_stats, fn stat ->
    case stat.avg_response_time do
      %Decimal{} = decimal -> Decimal.to_float(decimal)
      nil -> 0.0
      time -> time
    end
  end)
  Float.round(Enum.sum(times) / length(times), 1)
else
  0.0
end

health_status = cond do
  overall_success_rate >= 85 -> "🟢 EXCELLENT"
  overall_success_rate >= 70 -> "🟡 GOOD"  
  overall_success_rate >= 50 -> "🟠 FAIR"
  true -> "🔴 POOR"
end

performance_status = cond do
  avg_response_time <= 500 -> "🚀 FAST"
  avg_response_time <= 1000 -> "✅ GOOD"
  avg_response_time <= 2000 -> "⚠️ SLOW"
  true -> "🐌 VERY SLOW"
end

IO.puts("Overall Success Rate: #{overall_success_rate}% #{health_status}")
IO.puts("Average Response Time: #{avg_response_time}ms #{performance_status}")
IO.puts("Total API Calls: #{total_calls}")
IO.puts("Successful Calls: #{successful_calls}")

target_success = if overall_success_rate >= 85, do: "✅ TARGET MET", else: "❌ BELOW TARGET"
target_performance = if avg_response_time <= 500, do: "✅ TARGET MET", else: "❌ ABOVE TARGET"

IO.puts("\n📈 Target Achievement:")
IO.puts("Success Rate Target (≥85%): #{target_success}")
IO.puts("Performance Target (≤500ms): #{target_performance}")

IO.puts("\n🏁 API Resilience System Verification Complete!")
IO.puts("📍 View dashboard at: http://localhost:4001/imports")