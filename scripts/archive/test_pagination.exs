# Test script for IMDb list pagination
# Run with: mix run test_pagination.exs

alias Cinegraph.Cultural.CanonicalImporter
alias Cinegraph.Movies

IO.puts("🎬 Testing IMDb List Pagination")
IO.puts("=" |> String.duplicate(50))

# First check the current state
IO.puts("\n📊 Current Database State:")
current_count = Movies.count_canonical_movies("1001_movies")
IO.puts("  • 1001 Movies currently in DB: #{current_count}")

# Import with pagination
IO.puts("\n📋 Importing 1001 Movies with Pagination")
IO.puts("-" |> String.duplicate(30))

case CanonicalImporter.import_1001_movies() do
  %{error: reason} ->
    IO.puts("❌ Failed: #{inspect(reason)}")

  result ->
    IO.puts("✅ Import completed!")
    IO.puts("📊 Summary:")
    IO.puts("  • Total movies processed: #{result.total_movies}")
    IO.puts("  • Created: #{result.movies_created}")
    IO.puts("  • Updated: #{result.movies_updated}")
    IO.puts("  • Queued: #{result.movies_queued}")
    IO.puts("  • Skipped: #{result.movies_skipped}")

    # Show some results from different parts of the list
    if result.results && length(result.results) > 0 do
      IO.puts("\n🎥 Sample Results (every 250th movie):")

      [1, 250, 500, 750, 1000, 1250]
      |> Enum.each(fn pos ->
        movie = Enum.at(result.results, pos - 1)

        if movie do
          title = movie[:title] || movie.title || "Unknown"
          imdb_id = movie[:imdb_id] || movie.imdb_id || "No ID"
          action = movie[:action] || movie.action || "unknown"
          IO.puts("  • Position #{pos}: #{title} (#{imdb_id}) - #{action}")
        end
      end)
    end
end

# Final check
IO.puts("\n📈 Final Database State:")
final_count = Movies.count_canonical_movies("1001_movies")
IO.puts("  • 1001 Movies now in DB: #{final_count}")
IO.puts("  • Movies added/updated: #{final_count - current_count}")

IO.puts("\n✅ Pagination test complete!")
