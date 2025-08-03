# Debug what categories we're getting from IMDb
# Run with: mix run debug_imdb_categories.exs

require Logger

# Load environment variables
case Dotenvy.source([".env"]) do
  {:ok, env} -> 
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)
  {:error, reason} -> 
    Logger.error("Failed to load .env: #{inspect(reason)}")
end

# Test with 2023 which should have the real ceremony data
Logger.info("Fetching IMDb data for 2023 Academy Awards...")

case Cinegraph.Scrapers.ImdbOscarScraper.fetch_ceremony_imdb_data(2023) do
  {:ok, imdb_data} ->
    Logger.info("✅ Successfully fetched IMDb data!")
    Logger.info("Categories found: #{map_size(imdb_data.awards)}")
    
    # Show all categories
    Logger.info("\nAll IMDb categories:")
    imdb_data.awards
    |> Map.keys()
    |> Enum.sort()
    |> Enum.each(fn category ->
      nominations = imdb_data.awards[category]
      winners = Enum.count(nominations, & &1.winner)
      Logger.info("- #{category}: #{length(nominations)} nominees (#{winners} winners)")
    end)
    
    # Show example from Best Picture if it exists
    best_picture_keys = 
      imdb_data.awards
      |> Map.keys()
      |> Enum.filter(fn key -> String.contains?(String.downcase(key), "picture") end)
    
    if length(best_picture_keys) > 0 do
      category = hd(best_picture_keys)
      Logger.info("\nExample from '#{category}':")
      
      imdb_data.awards[category]
      |> Enum.take(3)
      |> Enum.each(fn nom ->
        status = if nom.winner, do: "WINNER", else: "Nominee"
        
        film = List.first(nom.films) || %{}
        film_info = if film[:imdb_id], do: "#{film[:title]} (#{film[:imdb_id]})", else: "No film"
        
        people = nom.people |> Enum.map(& &1[:name]) |> Enum.join(", ")
        people_info = if people != "", do: " - #{people}", else: ""
        
        Logger.info("  #{status}: #{film_info}#{people_info}")
      end)
    end
    
  {:error, reason} ->
    Logger.error("❌ Failed: #{inspect(reason)}")
end

# Also check our Oscar data categories
Logger.info("\n" <> String.duplicate("-", 50))
Logger.info("Checking our Oscar ceremony data...")

ceremony = Cinegraph.Repo.get_by!(Cinegraph.Cultural.OscarCeremony, year: 2023)
our_categories = 
  ceremony.data["categories"]
  |> Enum.map(& &1["category"])
  |> Enum.sort()

Logger.info("Our categories (#{length(our_categories)}):")
Enum.each(our_categories, fn cat ->
  Logger.info("- #{cat}")
end)