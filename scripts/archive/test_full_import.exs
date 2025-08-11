# Test complete canonical import with all pages
# Run with: mix run test_full_import.exs

# Suppress debug logs for cleaner output
Logger.configure(level: :info)

alias Cinegraph.Cultural.CanonicalImporter
alias Cinegraph.Movies

IO.puts("🎬 Full Canonical Import Test")
IO.puts("=" |> String.duplicate(50))

# Check initial state
initial_count = Movies.count_canonical_movies("1001_movies")
IO.puts("\n📊 Initial State:")
IO.puts("  • Movies marked as 1001: #{initial_count}")

# Run the import
IO.puts("\n📋 Starting Full Import...")
IO.puts("  This will fetch all pages from the IMDb list")
IO.puts("  Expected: ~1260 movies total")

start_time = System.monotonic_time(:second)

result = CanonicalImporter.import_1001_movies()

end_time = System.monotonic_time(:second)
duration = end_time - start_time

# Show results
IO.puts("\n✅ Import Complete!")
IO.puts("📊 Results:")
IO.puts("  • Total movies processed: #{result.total_movies}")
IO.puts("  • Updated (already existed): #{result.movies_updated}")
IO.puts("  • Queued for creation: #{result.movies_queued}")
IO.puts("  • Skipped: #{result.movies_skipped}")
IO.puts("  • Duration: #{duration} seconds")

# Check final count
final_count = Movies.count_canonical_movies("1001_movies")
IO.puts("\n📈 Final State:")
IO.puts("  • Movies marked as 1001: #{final_count}")
IO.puts("  • Net change: +#{final_count - initial_count}")

# Show sample movies from different parts of the list
if result.results && length(result.results) > 0 do
  IO.puts("\n🎥 Sample Movies (every 200th):")

  [1, 200, 400, 600, 800, 1000, 1200]
  |> Enum.each(fn pos ->
    movie = Enum.at(result.results, pos - 1)

    if movie do
      title = movie[:title] || movie.title || "Unknown"
      IO.puts("  • ##{pos}: #{title}")
    end
  end)
end

IO.puts("\n🎯 Import Summary:")

if result.total_movies >= 1200 do
  IO.puts("  ✅ Successfully imported full 1001 Movies list!")
else
  IO.puts("  ⚠️  Only imported #{result.total_movies} movies (expected ~1260)")
end
