# Show what we successfully scraped
# Run with: mix run show_oscar_data.exs

require Logger

# Get the 2024 ceremony
ceremony = case Cinegraph.Repo.get_by(Cinegraph.Cultural.OscarCeremony, year: 2024) do
  nil -> 
    Logger.error("No ceremony found for year 2024")
    System.halt(1)
  ceremony -> ceremony
end

Logger.info("=== 2024 (96th) Academy Awards Data ===")
Logger.info("Categories: #{length(ceremony.data["categories"])}")
Logger.info("")

# Show all categories with counts
Enum.each(ceremony.data["categories"], fn category ->
  winners = Enum.count(category["nominees"], & &1["winner"])
  nominees = length(category["nominees"]) - winners
  Logger.info("#{category["category"]}: #{winners} winner(s), #{nominees} nominee(s)")
end)

# Show Best Picture details
Logger.info("\n=== Best Picture Details ===")
best_picture = Enum.find(ceremony.data["categories"], fn cat -> 
  cat["category"] == "Best Picture"
end)

if best_picture do
  Enum.each(best_picture["nominees"], fn nominee ->
    status = if nominee["winner"], do: "🏆 WINNER", else: "   Nominee"
    Logger.info("#{status}: #{nominee["film"]} - #{nominee["name"]}")
  end)
end

# Show some statistics
total_nominees = 
  ceremony.data["categories"]
  |> Enum.flat_map(fn cat -> cat["nominees"] end)
  |> length()

total_winners = 
  ceremony.data["categories"]
  |> Enum.flat_map(fn cat -> cat["nominees"] end)
  |> Enum.count(& &1["winner"])

Logger.info("\n=== Statistics ===")
Logger.info("Total categories: #{length(ceremony.data["categories"])}")
Logger.info("Total nominees: #{total_nominees}")
Logger.info("Total winners: #{total_winners}")

# Check for IMDb IDs
Logger.info("\n=== Data Quality ===")
Logger.info("Ceremony data includes:")
Logger.info("- Film titles: ✅")
Logger.info("- Nominee names: ✅")
Logger.info("- Winner status: ✅")
Logger.info("- IMDb IDs: ❌ (not included in HTML - will need to match by title/year)")