alias Cinegraph.Scrapers.UnifiedFestivalScraper
alias Cinegraph.Events
alias Cinegraph.Events.FestivalEventCache

# Check if cache is running
IO.puts("\n=== Cache Status ===")
try do
  events = FestivalEventCache.get_active_events()
  IO.puts("✅ Cache is running, has #{length(events)} events")
  events |> Enum.each(fn e -> 
    IO.puts("  #{e.source_key} (#{e.abbreviation})")
  end)
rescue
  e ->
    IO.puts("❌ Cache error: #{inspect(e)}")
end

# Try fetching Cannes with cache
IO.puts("\n=== Testing Cannes with cache ===")
case UnifiedFestivalScraper.fetch_festival_data("cannes", 2024) do
  {:ok, data} ->
    award_count = 
      data.awards
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()
    
    IO.puts("✅ Success: #{map_size(data.awards)} categories, #{award_count} total nominations")
    
    # Show first few categories
    data.awards
    |> Enum.take(3)
    |> Enum.each(fn {cat, nominees} ->
      IO.puts("  #{cat}: #{length(nominees)} nominees")
    end)
    
  {:error, reason} ->
    IO.puts("❌ Error: #{inspect(reason)}")
end

# Try fetching New Horizons with cache
IO.puts("\n=== Testing New Horizons with cache ===")
case UnifiedFestivalScraper.fetch_festival_data("new_horizons", 2024) do
  {:ok, data} ->
    award_count = 
      data.awards
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()
    
    IO.puts("✅ Success: #{map_size(data.awards)} categories, #{award_count} total nominations")
    
    # Show first few categories
    data.awards
    |> Enum.take(3)
    |> Enum.each(fn {cat, nominees} ->
      IO.puts("  #{cat}: #{length(nominees)} nominees")
    end)
    
  {:error, reason} ->
    IO.puts("❌ Error: #{inspect(reason)}")
end