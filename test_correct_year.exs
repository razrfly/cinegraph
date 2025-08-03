# Test with the correct year
# Run with: mix run test_correct_year.exs

require Logger

# Load environment variables
case Dotenvy.source([".env"]) do
  {:ok, env} -> 
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)
  {:error, reason} -> 
    Logger.error("Failed to load .env: #{inspect(reason)}")
end

# Test the scraper's year mapping for 2022 ceremony (held in 2023)
ceremony_year = 2022
Logger.info("Testing scraper's year mapping for ceremony year #{ceremony_year}...")
case Cinegraph.Scrapers.ImdbOscarScraper.fetch_ceremony_imdb_data(ceremony_year) do
  {:ok, imdb_data} ->
    Logger.info("✅ Successfully fetched IMDb data!")
    Logger.info("Categories found: #{map_size(imdb_data.awards)}")
    
    # Show Best Picture
    best_picture = imdb_data.awards["Best Motion Picture of the Year"]
    if best_picture do
      Logger.info("\nBest Motion Picture of the Year:")
      best_picture
      |> Enum.each(fn nom ->
        winner = if nom.winner, do: "WINNER", else: "      "
        film = List.first(nom.films) || %{}
        Logger.info("  #{winner} #{film[:title]} (#{film[:imdb_id]})")
      end)
    end
    
    # Now compare with our 2023 ceremony data
    case Cinegraph.Repo.get_by(Cinegraph.Cultural.OscarCeremony, year: 2023) do
      nil ->
        Logger.warn("No local ceremony data found for 2023")
      ceremony ->
        our_best_picture = 
          ceremony.data["categories"]
          |> Enum.find(fn cat -> cat["category"] == "Best Picture" end)
        
        if our_best_picture do
          Logger.info("\nOur Best Picture nominees (from 2023 ceremony):")
          our_best_picture["nominees"]
          |> Enum.each(fn nom ->
            winner = if nom["winner"], do: "WINNER", else: "      "
            Logger.info("  #{winner} #{nom["film"]}")
          end)
        end
    end
    
  {:error, reason} ->
    Logger.error("Failed to fetch: #{inspect(reason)}")
end