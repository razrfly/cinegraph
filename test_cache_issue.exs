alias Cinegraph.Scrapers.UnifiedFestivalScraper
alias Cinegraph.Events

# First check what the database actually has
IO.puts("\n=== Database Check ===")
events = Events.list_active_events()
IO.puts("Active events in database: #{length(events)}")
events |> Enum.each(fn e -> 
  IO.puts("  #{e.source_key} (#{e.abbreviation})")
end)

# Now try to fetch data without cache
IO.puts("\n=== Testing Cannes without cache ===")
case UnifiedFestivalScraper.fetch_festival_data("cannes", 2024) do
  {:ok, data} ->
    award_count = 
      data.awards
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()
    
    IO.puts("✅ Success: #{map_size(data.awards)} categories, #{award_count} total nominations")
    
  {:error, reason} ->
    IO.puts("❌ Error: #{inspect(reason)}")
end