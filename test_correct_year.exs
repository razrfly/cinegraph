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

# For the 95th Academy Awards (2023), we need to fetch 2022 data
# Since IMDb uses the ceremony year (2023) in the URL
ceremony_year = 2022
url_year = 2023  # 95th Academy Awards held in 2023

Logger.info("Fetching IMDb data for ceremony year #{ceremony_year} (URL year: #{url_year})...")

# Manually fetch with the correct URL
url = "https://www.imdb.com/event/ev0000003/#{url_year}/1"
Logger.info("URL: #{url}")

# Use the scraper with a custom year mapping
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
    ceremony = Cinegraph.Repo.get_by!(Cinegraph.Cultural.OscarCeremony, year: 2023)
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
    
  {:error, reason} ->
    Logger.error("Failed to fetch: #{inspect(reason)}")
end