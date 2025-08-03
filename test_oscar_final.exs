# Final test of Oscar scraper with updated parsing logic
# Run with: mix run test_oscar_final.exs

require Logger

# Load environment variables
case Dotenvy.source([".env"]) do
  {:ok, env} -> 
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)
  {:error, reason} -> 
    Logger.error("Failed to load .env: #{inspect(reason)}")
end

Logger.info("Testing Oscar scraper with updated parsing...")
Logger.info("=" <> String.duplicate("=", 50))

# Test with 2024 ceremony
Logger.info("\nFetching 2024 Oscar ceremony data...")
case Cinegraph.Cultural.import_oscar_ceremony(2024) do
  {:ok, ceremony} ->
    Logger.info("✅ Successfully imported 2024 ceremony!")
    Logger.info("Ceremony Number: #{ceremony.ceremony_number}")
    Logger.info("Categories found: #{length(ceremony.data["categories"] || [])}")
    
    # Show detailed breakdown
    if ceremony.data["categories"] && length(ceremony.data["categories"]) > 0 do
      Logger.info("\nCategory breakdown:")
      
      Enum.each(ceremony.data["categories"], fn category ->
        winner_count = Enum.count(category["nominees"] || [], & &1["winner"])
        nominee_count = length(category["nominees"] || []) - winner_count
        
        Logger.info("- #{category["category"]}: #{winner_count} winner(s), #{nominee_count} nominee(s)")
      end)
      
      # Show some example data
      Logger.info("\n=== Sample Data ===")
      
      # Find Best Picture
      best_picture = Enum.find(ceremony.data["categories"], fn cat -> 
        cat["category"] == "Best Picture"
      end)
      
      if best_picture do
        Logger.info("\nBest Picture:")
        Enum.each(best_picture["nominees"] || [], fn nominee ->
          status = if nominee["winner"], do: "🏆 WINNER", else: "   Nominee"
          Logger.info("#{status}: #{nominee["film"]} - #{nominee["name"]}")
        end)
      end
      
      # Find Best Director
      best_director = Enum.find(ceremony.data["categories"], fn cat -> 
        cat["category"] == "Directing"
      end)
      
      if best_director do
        Logger.info("\nBest Director:")
        Enum.each(best_director["nominees"] || [], fn nominee ->
          status = if nominee["winner"], do: "🏆 WINNER", else: "   Nominee"
          Logger.info("#{status}: #{nominee["name"]} - #{nominee["film"]}")
        end)
      end
    else
      Logger.warn("No categories found in parsed data")
    end
    
  {:error, reason} ->
    Logger.error("❌ Failed to fetch 2024 data: #{inspect(reason)}")
end

# Try 2023 as well
Logger.info("\n" <> String.duplicate("-", 50))
Logger.info("Fetching 2023 Oscar ceremony data...")

case Cinegraph.Cultural.import_oscar_ceremony(2023) do
  {:ok, ceremony} ->
    Logger.info("✅ Successfully imported 2023 ceremony!")
    Logger.info("Categories found: #{length(ceremony.data["categories"] || [])}")
    
    # Count total nominees and winners
    if ceremony.data["categories"] do
      total_nominees = 
        ceremony.data["categories"]
        |> Enum.map(fn cat -> length(cat["nominees"] || []) end)
        |> Enum.sum()
      
      total_winners = 
        ceremony.data["categories"]
        |> Enum.flat_map(fn cat -> cat["nominees"] || [] end)
        |> Enum.count(& &1["winner"])
      
      Logger.info("Total nominees: #{total_nominees}")
      Logger.info("Total winners: #{total_winners}")
    end
    
  {:error, reason} ->
    Logger.error("❌ Failed to fetch 2023 data: #{inspect(reason)}")
end

Logger.info("\n" <> String.duplicate("=", 50))
Logger.info("Test complete!")