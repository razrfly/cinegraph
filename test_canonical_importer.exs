# Test script for the canonical movie importer (Oscar importer pattern)
# Run with: mix run test_canonical_importer.exs

alias Cinegraph.Cultural.CanonicalImporter

IO.puts("🎬 Testing Canonical Movie Importer (Oscar Pattern)")
IO.puts("=" |> String.duplicate(50))

# Test 1: Import 1001 Movies list using the modular pattern
IO.puts("\n📋 Test 1: Importing 1001 Movies List")
IO.puts("-" |> String.duplicate(30))

case CanonicalImporter.import_1001_movies() do
  %{error: reason} ->
    IO.puts("❌ Failed: #{inspect(reason)}")
    
  result ->
    IO.puts("✅ Import completed!")
    IO.puts("📊 Summary:")
    IO.puts("  • Total movies: #{result.total_movies}")
    IO.puts("  • Created: #{result.movies_created}")
    IO.puts("  • Updated: #{result.movies_updated}") 
    IO.puts("  • Queued: #{result.movies_queued}")
    IO.puts("  • Skipped: #{result.movies_skipped}")
    
    # Show first few results
    if result.results && length(result.results) > 0 do
      IO.puts("\n🎥 Sample Results:")
      result.results
      |> Enum.take(5)
      |> Enum.each(fn movie_result ->
        title = movie_result[:title] || movie_result["title"] || "Unknown"
        imdb_id = movie_result[:imdb_id] || movie_result["imdb_id"] || "No ID"
        action = movie_result[:action] || movie_result["action"] || "unknown"
        IO.puts("  • #{title} (#{imdb_id}) - #{action}")
      end)
    end
end

# Test 2: Check database stats
IO.puts("\n📈 Test 2: Database Statistics")
IO.puts("-" |> String.duplicate(30))

stats = CanonicalImporter.import_stats()
IO.puts("📊 Canonical Movie Statistics:")
IO.puts("  • Total canonical movies: #{stats.any_canonical}")

Enum.each(stats.by_source, fn {source, count} ->
  IO.puts("  • #{source}: #{count} movies")
end)

# Test 3: Show the modular pattern
IO.puts("\n🔧 Test 3: Modular Import Pattern")
IO.puts("-" |> String.duplicate(30))

IO.puts("✨ The importer now follows the Oscar pattern:")
IO.puts("")
IO.puts("1. 📋 **Scraper**: Finds movies on IMDb list")
IO.puts("   - Extracts IMDb IDs, titles, years")
IO.puts("   - Pure parsing, no database operations")
IO.puts("")
IO.puts("2. 🎯 **Importer**: Processes each movie")
IO.puts("   - If exists: Update with canonical data")
IO.puts("   - If missing: Queue for creation via TMDbDetailsWorker")
IO.puts("")
IO.puts("3. ⚙️  **Worker**: Creates movies modularly")
IO.puts("   - Fetches from TMDb")
IO.puts("   - Creates movie record")
IO.puts("   - Marks as canonical in post-processing")
IO.puts("")
IO.puts("4. 🔄 **Same pattern for any canonical source:**")
IO.puts("   - 1001 Movies")
IO.puts("   - Sight & Sound")
IO.puts("   - Criterion Collection")
IO.puts("   - AFI Greatest Films")
IO.puts("   - Any other IMDb list")

IO.puts("\n✅ Modular canonical import system ready!")
IO.puts("📝 Usage:")
IO.puts("  CanonicalImporter.import_canonical_list(\"ls024863935\", \"1001_movies\", \"1001 Movies\")")
IO.puts("  CanonicalImporter.import_canonical_list(\"ls123456789\", \"sight_sound\", \"Sight & Sound\")")
IO.puts("  CanonicalImporter.import_1001_movies()")

IO.puts("\n🎯 Next: Find IMDb list IDs for other canonical sources!")