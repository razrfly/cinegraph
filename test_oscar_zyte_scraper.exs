# Test script for Oscar scraper with Zyte API
# Run with: mix run test_oscar_zyte_scraper.exs

require Logger

# Load environment variables from .env file
case Dotenvy.source([".env"]) do
  {:ok, env} -> 
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)
    Logger.info("✅ Loaded environment variables from .env")
  {:error, reason} -> 
    Logger.error("Failed to load .env: #{inspect(reason)}")
end

Logger.info("Testing Oscar scraper with Zyte API...")
Logger.info("=" <> String.duplicate("=", 50))

# Check if API key is available
api_key = System.get_env("ZYTE_API_KEY")
if api_key do
  Logger.info("✅ ZYTE_API_KEY found")
else
  Logger.error("❌ ZYTE_API_KEY not found in environment")
end

# Test 1: Try fetching from Oscars.org via Zyte
Logger.info("\nTest 1: Fetching Oscar ceremony data for 2024 via Zyte API...")
case Cinegraph.Cultural.import_oscar_ceremony(2024) do
  {:ok, ceremony} ->
    Logger.info("✅ Successfully imported ceremony!")
    Logger.info("Ceremony ID: #{ceremony.id}")
    Logger.info("Year: #{ceremony.year}")
    Logger.info("Ceremony Number: #{ceremony.ceremony_number}")
    
    # Show a sample of the data
    if ceremony.data["categories"] && length(ceremony.data["categories"]) > 0 do
      Logger.info("\nFound #{length(ceremony.data["categories"])} categories")
      
      # Show first category as example
      first_category = hd(ceremony.data["categories"])
      Logger.info("\nExample category: #{first_category["category"]}")
      Logger.info("Nominees: #{length(first_category["nominees"] || [])}")
      
      if first_category["nominees"] && length(first_category["nominees"]) > 0 do
        first_nominee = hd(first_category["nominees"])
        Logger.info("Example nominee:")
        Logger.info("  Film: #{first_nominee["film"]}")
        Logger.info("  Name: #{first_nominee["name"]}")
        Logger.info("  Winner: #{first_nominee["winner"]}")
      end
    end
    
  {:error, reason} ->
    Logger.error("❌ Failed to fetch via Zyte: #{inspect(reason)}")
end

# Test 2: Try fetching 2023 ceremony
Logger.info("\nTest 2: Fetching Oscar ceremony data for 2023 via Zyte API...")
case Cinegraph.Cultural.import_oscar_ceremony(2023) do
  {:ok, ceremony} ->
    Logger.info("✅ Successfully imported 2023 ceremony!")
    Logger.info("Categories found: #{length(ceremony.data["categories"] || [])}")
    
  {:error, reason} ->
    Logger.error("❌ Failed to fetch 2023 data: #{inspect(reason)}")
end

# Test 3: List all ceremonies in database
Logger.info("\nTest 3: Listing all ceremonies in database...")
ceremonies = Cinegraph.Cultural.list_oscar_ceremonies()
Logger.info("Total ceremonies stored: #{length(ceremonies)}")

Enum.each(ceremonies, fn ceremony ->
  category_count = length(ceremony.data["categories"] || [])
  nominee_count = 
    ceremony.data["categories"]
    |> Enum.map(fn cat -> length(cat["nominees"] || []) end)
    |> Enum.sum()
  
  Logger.info("- Year #{ceremony.year} (#{ceremony.ceremony_number}th): #{category_count} categories, #{nominee_count} total nominees")
end)

Logger.info("\n" <> String.duplicate("=", 50))
Logger.info("Test complete!")

# Clean up test data if needed
if length(ceremonies) > 0 do
  Logger.info("\nTo clean up test data, run:")
  Logger.info("Cinegraph.Repo.delete_all(Cinegraph.Cultural.OscarCeremony)")
end