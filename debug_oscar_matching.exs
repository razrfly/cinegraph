# Debug Oscar matching issues
# Run with: mix run debug_oscar_matching.exs

require Logger

# Load environment variables
case Dotenvy.source([".env"]) do
  {:ok, env} -> 
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)
  {:error, reason} -> 
    Logger.error("Failed to load .env: #{inspect(reason)}")
end

# Get the 2023 ceremony
case Cinegraph.Repo.get_by(Cinegraph.Cultural.OscarCeremony, year: 2023) do
  nil ->
    Logger.error("2023 ceremony not found in database")
    System.halt(1)
  ceremony ->

    # Get IMDb data
    case Cinegraph.Scrapers.ImdbOscarScraper.fetch_ceremony_imdb_data(2023) do
      {:ok, imdb_data} ->
        # Let's compare Best Picture nominees
        Logger.info("=== Comparing Best Picture nominees ===")

        # Our Best Picture category
        our_best_picture = 
          ceremony.data["categories"]
          |> Enum.find(fn cat -> cat["category"] == "Best Picture" end)

        # IMDb Best Picture category  
        imdb_best_picture = imdb_data.awards["Best Motion Picture of the Year"]

        if our_best_picture && imdb_best_picture do
          Logger.info("\nOur nominees:")
          our_best_picture["nominees"]
          |> Enum.each(fn nom ->
            winner = if nom["winner"], do: "WINNER", else: "      "
            Logger.info("  #{winner} #{nom["film"]}")
          end)
          
          Logger.info("\nIMDb nominees:")
          imdb_best_picture
          |> Enum.each(fn nom ->
            winner = if nom.winner, do: "WINNER", else: "      "
            film = List.first(nom.films) || %{}
            Logger.info("  #{winner} #{film[:title]} (#{film[:imdb_id]})")
          end)
        end

        # Check film matching logic
        Logger.info("\n=== Testing film matching logic ===")

        defmodule TestMatcher do
          def normalize_title(title) when is_binary(title) do
            title
            |> String.trim()
            |> String.downcase()
            |> String.replace(~r/[^a-z0-9\s]/, "")
          end
          def normalize_title(_), do: ""
          
          def film_matches?(film_title, imdb_films) when is_binary(film_title) and is_list(imdb_films) do
            normalized_title = normalize_title(film_title)
            
            Enum.find(imdb_films, fn imdb_film ->
              imdb_normalized = normalize_title(imdb_film[:title])
              match = normalized_title == imdb_normalized
              
              if !match && String.contains?(normalized_title, "everything") do
                Logger.info("  Comparing: '#{normalized_title}' vs '#{imdb_normalized}'")
              end
              
              match
            end)
          end
          def film_matches?(_, _), do: nil
        end

        # Test specific films
        test_films = [
          "Everything Everywhere All at Once",
          "All Quiet on the Western Front",
          "Avatar: The Way of Water",
          "The Banshees of Inisherin",
          "The Fabelmans"
        ]

        Logger.info("\nTesting film matching:")
        Enum.each(test_films, fn film ->
          all_imdb_films = 
            imdb_data.awards
            |> Map.values()
            |> List.flatten()
            |> Enum.flat_map(& &1.films)
          
          match = TestMatcher.film_matches?(film, all_imdb_films)
          
          if match do
            Logger.info("  ✅ '#{film}' -> #{match[:title]} (#{match[:imdb_id]})")
          else
            Logger.info("  ❌ '#{film}' -> No match found")
          end
        end)

        # Show all unique film titles from IMDb
        Logger.info("\n=== All unique films from IMDb ===")
        all_imdb_films = 
          imdb_data.awards
          |> Map.values()
          |> List.flatten()
          |> Enum.flat_map(& &1.films)
          |> Enum.uniq_by(& &1[:imdb_id])
          |> Enum.sort_by(& &1[:title])

        Logger.info("Total unique films: #{length(all_imdb_films)}")
        all_imdb_films
        |> Enum.take(20)
        |> Enum.each(fn film ->
          Logger.info("  #{film[:title]} (#{film[:imdb_id]})")
        end)
        
      {:error, reason} ->
        Logger.error("Failed to fetch IMDb data: #{inspect(reason)}")
        System.halt(1)
    end
end