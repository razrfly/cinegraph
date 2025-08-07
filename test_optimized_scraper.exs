alias Cinegraph.Scrapers.UnifiedFestivalScraper

# Test the optimized scraper
IO.puts("\n=== Testing Optimized UnifiedFestivalScraper ===")

# Test Cannes
IO.puts("\n1. Testing Cannes 2024...")
{cannes_time, cannes_result} = :timer.tc(fn ->
  UnifiedFestivalScraper.fetch_festival_data("cannes", 2024)
end)

case cannes_result do
  {:ok, data} ->
    award_count = 
      data.awards
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()
    
    IO.puts("✅ Success: #{map_size(data.awards)} categories, #{award_count} total nominations")
    IO.puts("   Time: #{cannes_time / 1000}ms")
    
  {:error, reason} ->
    IO.puts("❌ Error: #{inspect(reason)}")
end

# Test New Horizons
IO.puts("\n2. Testing New Horizons 2024...")
{nh_time, nh_result} = :timer.tc(fn ->
  UnifiedFestivalScraper.fetch_festival_data("new_horizons", 2024)
end)

case nh_result do
  {:ok, data} ->
    award_count = 
      data.awards
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()
    
    IO.puts("✅ Success: #{map_size(data.awards)} categories, #{award_count} total nominations")
    IO.puts("   Time: #{nh_time / 1000}ms")
    
  {:error, reason} ->
    IO.puts("❌ Error: #{inspect(reason)}")
end

# Test Venice for comparison
IO.puts("\n3. Testing Venice 2024...")
{venice_time, venice_result} = :timer.tc(fn ->
  UnifiedFestivalScraper.fetch_festival_data("venice", 2024)
end)

case venice_result do
  {:ok, data} ->
    award_count = 
      data.awards
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()
    
    IO.puts("✅ Success: #{map_size(data.awards)} categories, #{award_count} total nominations")
    IO.puts("   Time: #{venice_time / 1000}ms")
    
  {:error, reason} ->
    IO.puts("❌ Error: #{inspect(reason)}")
end

IO.puts("\n=== Summary ===")
IO.puts("All festivals should return data correctly without 40+ database queries")