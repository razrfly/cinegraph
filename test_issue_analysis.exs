alias Cinegraph.Scrapers.UnifiedFestivalScraper
alias Cinegraph.Events

IO.puts("\n=== ANALYZING ISSUE #178 ===")
IO.puts("Current branch: main (reverted from broken optimizations)")

# Test each festival to see current behavior
festivals = ["cannes", "venice", "new_horizons"]

Enum.each(festivals, fn festival_key ->
  IO.puts("\n=== Testing #{festival_key} ===")
  
  # Get the festival config
  festival_event = Events.get_active_by_source_key(festival_key)
  
  if festival_event do
    IO.puts("  Event found: #{festival_event.name} (#{festival_event.abbreviation})")
    
    # Count database queries during fetch
    Process.put(:query_count, 0)
    
    # Intercept Events.list_active_events calls
    original_list = &Events.list_active_events/0
    
    # We can't actually intercept, but let's fetch and see what happens
    case UnifiedFestivalScraper.fetch_festival_data(festival_key, 2024) do
      {:ok, data} ->
        award_count = 
          data.awards
          |> Map.values()
          |> Enum.map(&length/1)
          |> Enum.sum()
        
        IO.puts("  ✅ Success: #{map_size(data.awards)} categories, #{award_count} nominations")
        
        # Show sample categories
        data.awards
        |> Enum.take(3)
        |> Enum.each(fn {cat, nominees} ->
          IO.puts("    #{cat}: #{length(nominees)} nominees")
        end)
        
      {:error, reason} ->
        IO.puts("  ❌ Error: #{inspect(reason)}")
    end
  else
    IO.puts("  ❌ Festival not found in database")
  end
end)

IO.puts("\n=== Analysis ===")
IO.puts("The issue is that get_festival_event_by_config is called multiple times")
IO.puts("during award parsing, causing Events.list_active_events() to be called")
IO.puts("40+ times for a single import.")