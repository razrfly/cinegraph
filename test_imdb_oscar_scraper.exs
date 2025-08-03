# Test IMDb Oscar scraper
# Run with: mix run test_imdb_oscar_scraper.exs

require Logger

# Load environment variables
case Dotenvy.source([".env"]) do
  {:ok, env} -> 
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)
  {:error, reason} -> 
    Logger.error("Failed to load .env: #{inspect(reason)}")
end

Logger.info("Testing IMDb Oscar scraper...")
Logger.info("=" <> String.duplicate("=", 50))

# Test with 2024 ceremony (maps to 2025 URL)
Logger.info("\nFetching IMDb Oscar data for 2024...")
case Cinegraph.Scrapers.ImdbOscarScraper.fetch_ceremony_imdb_data(2024) do
  {:ok, imdb_data} ->
    Logger.info("✅ Successfully fetched IMDb data!")
    Logger.info("Year: #{imdb_data.year}")
    Logger.info("Categories found: #{map_size(imdb_data.awards)}")
    
    # Show first category as example
    if map_size(imdb_data.awards) > 0 do
      {category_name, nominations} = Enum.at(imdb_data.awards, 0)
      Logger.info("\nExample category: #{category_name}")
      Logger.info("Nominations: #{length(nominations)}")
      
      # Show first nomination
      if length(nominations) > 0 do
        nom = hd(nominations)
        Logger.info("\nFirst nomination:")
        Logger.info("  Winner: #{nom.winner}")
        
        if length(nom.films) > 0 do
          film = hd(nom.films)
          Logger.info("  Film: #{film.title} (#{film.imdb_id})")
        end
        
        if length(nom.people) > 0 do
          person = hd(nom.people)
          Logger.info("  Person: #{person.name} (#{person.imdb_id})")
        end
      end
    end
    
  {:error, reason} ->
    Logger.error("❌ Failed to fetch IMDb data: #{inspect(reason)}")
end

# Now test enhancing our existing ceremony data
Logger.info("\n" <> String.duplicate("-", 50))
Logger.info("Testing ceremony enhancement with IMDb data...")

# Get our existing 2024 ceremony
case Cinegraph.Repo.get_by(Cinegraph.Cultural.OscarCeremony, year: 2024) do
  nil ->
    Logger.error("❌ 2024 ceremony not found in database")
    Logger.info("Please run the Oscar import first")
    System.halt(1)
  ceremony ->
    case Cinegraph.Scrapers.ImdbOscarScraper.enhance_ceremony_with_imdb(ceremony) do
      {:ok, enhanced_data} ->
        Logger.info("✅ Successfully enhanced ceremony data!")
        
        # Check how many nominees got IMDb IDs
        enhanced_count = 
          enhanced_data["categories"]
          |> Enum.flat_map(fn cat -> cat["nominees"] || [] end)
          |> Enum.count(fn nom -> Map.has_key?(nom, "film_imdb_id") end)
        
        Logger.info("Nominees with IMDb film IDs: #{enhanced_count}")
        
        # Show Best Picture with IMDb IDs
        best_picture = Enum.find(enhanced_data["categories"], fn cat -> 
          cat["category"] == "Best Picture"
        end)
        
        if best_picture do
          Logger.info("\nBest Picture nominees with IMDb IDs:")
          Enum.each(best_picture["nominees"] || [], fn nom ->
            imdb_id = nom["film_imdb_id"] || "not found"
            status = if nom["winner"], do: "🏆", else: "  "
            Logger.info("#{status} #{nom["film"]} - IMDb: #{imdb_id}")
          end)
        end
        
      {:error, reason} ->
        Logger.error("❌ Failed to enhance ceremony: #{inspect(reason)}")
    end
end

Logger.info("\n" <> String.duplicate("=", 50))
Logger.info("Test complete!")