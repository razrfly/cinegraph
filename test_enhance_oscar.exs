# Test enhancing Oscar ceremony with IMDb data
# Run with: mix run test_enhance_oscar.exs

require Logger

# Load environment variables
case Dotenvy.source([".env"]) do
  {:ok, env} -> 
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)
  {:error, reason} -> 
    Logger.error("Failed to load .env: #{inspect(reason)}")
end

# Get the 2023 ceremony
ceremony = case Cinegraph.Repo.get_by(Cinegraph.Cultural.OscarCeremony, year: 2023) do
  nil -> 
    Logger.error("No ceremony found for year 2023")
    System.halt(1)
  ceremony -> ceremony
end

Logger.info("Testing enhance_ceremony_with_imdb for 2023...")
Logger.info("Original categories: #{length(ceremony.data["categories"])}")

# Count current IMDb IDs
current_imdb_count = 
  ceremony.data["categories"]
  |> Enum.flat_map(& &1["nominees"])
  |> Enum.count(fn nom -> 
    Map.has_key?(nom, "film_imdb_id") || Map.has_key?(nom, "person_imdb_ids")
  end)

Logger.info("Current nominees with IMDb IDs: #{current_imdb_count}")

# Enhance with IMDb data
case Cinegraph.Scrapers.ImdbOscarScraper.enhance_ceremony_with_imdb(ceremony) do
  {:ok, enhanced_data} ->
    Logger.info("✅ Successfully enhanced ceremony data!")
    
    # Count new IMDb IDs
    new_imdb_count = 
      enhanced_data["categories"]
      |> Enum.flat_map(& &1["nominees"])
      |> Enum.count(fn nom -> 
        Map.has_key?(nom, "film_imdb_id") || Map.has_key?(nom, "person_imdb_ids")
      end)
    
    Logger.info("Nominees with IMDb IDs after enhancement: #{new_imdb_count}")
    Logger.info("New IMDb IDs added: #{new_imdb_count - current_imdb_count}")
    
    # Show sample enhanced nominees
    Logger.info("\n=== Sample Enhanced Nominees ===")
    
    # Find Best Picture
    best_picture = 
      enhanced_data["categories"]
      |> Enum.find(fn cat -> cat["category"] == "Best Picture" end)
    
    if best_picture do
      Logger.info("\nBest Picture nominees:")
      best_picture["nominees"]
      |> Enum.take(3)
      |> Enum.each(fn nom ->
        winner_status = if nom["winner"], do: "WINNER", else: "Nominee"
        imdb_id = nom["film_imdb_id"] || "No IMDb ID"
        Logger.info("  #{winner_status}: #{nom["film"]} - #{imdb_id}")
      end)
    end
    
    # Find Actor in a Leading Role
    actor_category = 
      enhanced_data["categories"]
      |> Enum.find(fn cat -> cat["category"] == "Actor in a Leading Role" end)
    
    if actor_category do
      Logger.info("\nActor in a Leading Role:")
      actor_category["nominees"]
      |> Enum.take(3)
      |> Enum.each(fn nom ->
        winner_status = if nom["winner"], do: "WINNER", else: "Nominee"
        person_ids = nom["person_imdb_ids"] || []
        film_id = nom["film_imdb_id"] || "No film ID"
        Logger.info("  #{winner_status}: #{nom["name"]} in #{nom["film"]}")
        Logger.info("    Person IDs: #{inspect(person_ids)}, Film ID: #{film_id}")
      end)
    end
    
    # Save the enhanced data back to the ceremony
    Logger.info("\nSaving enhanced data to database...")
    
    changeset = 
      ceremony
      |> Cinegraph.Cultural.OscarCeremony.changeset(%{data: enhanced_data})
    
    case Cinegraph.Repo.update(changeset) do
      {:ok, _updated} ->
        Logger.info("✅ Successfully saved enhanced ceremony data!")
      {:error, changeset} ->
        Logger.error("Failed to save: #{inspect(changeset.errors)}")
    end
    
  {:error, reason} ->
    Logger.error("❌ Failed to enhance ceremony: #{inspect(reason)}")
end