#!/usr/bin/env elixir

alias Cinegraph.Services.TMDb
alias Cinegraph.Services.TMDb.FallbackSearch
alias Cinegraph.Metrics.ApiTracker

IO.puts("Testing API tracking system...")

# Test 1: Direct TMDb lookup (should succeed)
IO.puts("\n1. Testing direct TMDb IMDb lookup...")
result1 = TMDb.find_by_imdb_id("tt0111161")
IO.inspect(result1, label: "Direct lookup result")

# Test 2: Search that will trigger fallback
IO.puts("\n2. Testing TMDb fallback search...")
result2 = FallbackSearch.find_movie("tt0111161", "The Shawshank Redemption", 1994)
IO.inspect(result2, label: "Fallback search result")

# Test 3: Search that will fail
IO.puts("\n3. Testing failed search...")
result3 = FallbackSearch.find_movie(nil, "NonExistentMovie123456", 2099)
IO.inspect(result3, label: "Failed search result")

# Test 4: Get current stats
IO.puts("\n4. Getting API statistics...")
stats = ApiTracker.get_all_stats(1)
IO.puts("Stats for last hour:")
Enum.each(stats, fn stat ->
  IO.puts("  #{stat.source}/#{stat.operation}: #{stat.total} calls, #{stat.success_rate}% success, #{stat.avg_response_time}ms avg")
end)

# Test 5: Get TMDb fallback stats
fallback_stats = ApiTracker.get_tmdb_fallback_stats(1)
IO.puts("\nTMDb Fallback Strategy Performance:")
Enum.each(fallback_stats, fn stat ->
  total = stat.total || 0
  successful = stat.successful || 0
  success_rate = if total > 0, do: Float.round(successful / total * 100, 1), else: 0.0
  avg_confidence = stat.avg_confidence || 0
  IO.puts("  Level #{stat.level}: #{total} attempts, #{success_rate}% success, avg confidence: #{avg_confidence}")
end)

IO.puts("\n✅ API tracking test complete!")