# Test script for the generic IMDb canonical scraper
# Run with: mix run test_canonical_scraper.exs

alias Cinegraph.Scrapers.ImdbCanonicalScraper

IO.puts("🎬 Testing Generic IMDb Canonical Movie Scraper")
IO.puts("=" |> String.duplicate(50))

# Test 1: Scrape 1001 Movies list
IO.puts("\n📋 Test 1: Scraping 1001 Movies List")
IO.puts("-" |> String.duplicate(30))

case ImdbCanonicalScraper.scrape_1001_movies() do
  {:ok, result} ->
    IO.puts("✅ Success!")
    IO.puts("📊 Summary:")
    IO.puts("  • Total movies: #{result.summary.total}")
    IO.puts("  • Created: #{result.summary.created}")
    IO.puts("  • Updated: #{result.summary.updated}") 
    IO.puts("  • Queued: #{result.summary.queued}")
    IO.puts("  • Skipped: #{result.summary.skipped}")
    IO.puts("  • Errors: #{result.summary.errors}")
    
    # Show first few results
    IO.puts("\n🎥 Sample Results:")
    result.results
    |> Enum.take(5)
    |> Enum.each(fn movie_result ->
      IO.puts("  • #{movie_result.title} (#{movie_result.imdb_id}) - #{movie_result.action}")
    end)
    
  {:error, reason} ->
    IO.puts("❌ Failed: #{inspect(reason)}")
end

# Test 2: Check database stats
IO.puts("\n📈 Test 2: Database Statistics")
IO.puts("-" |> String.duplicate(30))

stats = ImdbCanonicalScraper.canonical_stats()
IO.puts("📊 Canonical Movie Statistics:")
IO.puts("  • Total canonical movies: #{stats.any_canonical}")

Enum.each(stats.by_source, fn {source, count} ->
  IO.puts("  • #{source}: #{count} movies")
end)

# Test 3: Generic scraping demo (just show the API)
IO.puts("\n🔧 Test 3: Generic Scraping API Demo")
IO.puts("-" |> String.duplicate(30))

IO.puts("✨ The scraper now supports any IMDb list:")
IO.puts("")
IO.puts("# Single list scraping:")
IO.puts("ImdbCanonicalScraper.scrape_imdb_list(")
IO.puts("  \"ls024863935\",")  
IO.puts("  \"1001_movies\",")
IO.puts("  \"1001 Movies You Must See Before You Die\",")
IO.puts("  %{\"edition\" => \"2024\"}")
IO.puts(")")
IO.puts("")
IO.puts("# Batch scraping multiple lists:")
IO.puts("lists = [")
IO.puts("  %{list_id: \"ls024863935\", source_key: \"1001_movies\", name: \"1001 Movies\"},")
IO.puts("  %{list_id: \"ls123456789\", source_key: \"sight_sound\", name: \"Sight & Sound\"},")
IO.puts("  %{list_id: \"ls987654321\", source_key: \"criterion\", name: \"Criterion Collection\"}")
IO.puts("]")
IO.puts("ImdbCanonicalScraper.scrape_multiple_lists(lists)")

IO.puts("\n🎯 Generic scraper ready! Just need to find the list IDs for:")
IO.puts("  • Sight & Sound Greatest Films")
IO.puts("  • Criterion Collection")
IO.puts("  • AFI's Greatest Movies") 
IO.puts("  • BFI's Greatest Films")
IO.puts("  • Any other canonical movie list on IMDb")

IO.puts("\n✅ Test complete!")