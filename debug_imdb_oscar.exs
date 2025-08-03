# Debug IMDb Oscar scraper
# Run with: mix run debug_imdb_oscar.exs

require Logger

# Load environment variables
case Dotenvy.source([".env"]) do
  {:ok, env} -> 
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)
  {:error, reason} -> 
    Logger.error("Failed to load .env: #{inspect(reason)}")
end

# Let's try 2023 which should have IMDb data
Logger.info("Fetching IMDb Oscar data for 2023 (95th ceremony)...")

# First, let's get the raw HTML to see what we're working with
defmodule DebugIMDb do
  def get_raw_html(year) do
    api_key = System.get_env("ZYTE_API_KEY")
    
    # For 2023, the URL should be 2024
    url_year = year + 1
    url = "https://www.imdb.com/event/ev0000003/#{url_year}/1"
    
    Logger.info("Fetching from URL: #{url}")
    
    headers = [
      {"Authorization", "Basic #{Base.encode64(api_key <> ":")}"},
      {"Content-Type", "application/json"}
    ]
    
    body = Jason.encode!(%{
      url: url,
      browserHtml: true,
      javascript: true,
      viewport: %{
        width: 1920,
        height: 1080
      }
    })
    
    options = [
      timeout: 60_000,
      recv_timeout: 60_000,
      hackney: [pool: :default]
    ]
    
    case HTTPoison.post("https://api.zyte.com/v1/extract", body, headers, options) do
      {:ok, %{status_code: 200, body: response}} ->
        case Jason.decode(response) do
          {:ok, %{"browserHtml" => html}} ->
            {:ok, html}
          error ->
            {:error, error}
        end
      {:ok, %{status_code: status, body: body}} ->
        {:error, "HTTP #{status}: #{body}"}
      {:error, reason} ->
        {:error, reason}
    end
  end
end

case DebugIMDb.get_raw_html(2023) do
  {:ok, html} ->
    # Save HTML for inspection
    filename = "imdb_oscar_2023.html"
    File.write!(filename, html)
    Logger.info("✅ Saved HTML to #{filename}")
    
    # Look for __NEXT_DATA__
    if String.contains?(html, "__NEXT_DATA__") do
      Logger.info("✅ Found __NEXT_DATA__ in page")
      
      # Try to extract it
      case Regex.run(~r/<script id="__NEXT_DATA__" type="application\/json">(.*?)<\/script>/s, html) do
        [_, json_content] ->
          Logger.info("✅ Extracted JSON content (#{String.length(json_content)} chars)")
          
          # Save JSON for inspection
          File.write!("imdb_oscar_2023.json", json_content)
          Logger.info("✅ Saved JSON to imdb_oscar_2023.json")
          
          # Try to parse it
          case Jason.decode(json_content) do
            {:ok, data} ->
              Logger.info("✅ Successfully parsed JSON")
              
              # Navigate to awards
              awards = get_in(data, ["props", "pageProps", "eventEdition", "awards"])
              if awards do
                Logger.info("✅ Found awards data!")
                Logger.info("Number of categories: #{length(awards)}")
                
                # Show first category
                if length(awards) > 0 do
                  first = hd(awards)
                  Logger.info("\nFirst category: #{first["categoryName"]}")
                  Logger.info("Nominations: #{length(first["nominations"] || [])}")
                end
              else
                Logger.info("❌ No awards found in expected location")
                Logger.info("\nChecking alternative paths...")
                
                # Try to find where the data might be
                page_props = get_in(data, ["props", "pageProps"])
                if page_props do
                  Logger.info("pageProps keys: #{inspect(Map.keys(page_props))}")
                end
              end
              
            {:error, reason} ->
              Logger.error("Failed to parse JSON: #{inspect(reason)}")
          end
          
        nil ->
          Logger.error("Could not extract __NEXT_DATA__ content")
      end
    else
      Logger.error("❌ No __NEXT_DATA__ found in page")
      
      # Look for other patterns
      if String.contains?(html, "Academy Awards") do
        Logger.info("✅ Page contains 'Academy Awards'")
      end
      
      if String.contains?(html, "Best Picture") do
        Logger.info("✅ Page contains 'Best Picture'")
      end
    end
    
  {:error, reason} ->
    Logger.error("Failed to fetch HTML: #{inspect(reason)}")
end

Logger.info("\nCheck the saved files for manual inspection.")