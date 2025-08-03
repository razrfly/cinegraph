# Debug script to see what HTML we're getting from Oscars.org via Zyte
# Run with: mix run debug_oscar_html.exs

require Logger

# Load environment variables
# Load only the required environment variable
case Dotenvy.source([".env"]) do
  {:ok, env} -> 
    if api_key = Map.get(env, "ZYTE_API_KEY") do
      System.put_env("ZYTE_API_KEY", api_key)
    else
      Logger.error("ZYTE_API_KEY not found in .env file")
    end
  {:error, reason} -> 
    Logger.error("Failed to load .env: #{inspect(reason)}")
end

# Fetch raw HTML to see what we're working with
Logger.info("Fetching raw HTML from Oscars.org for 2024...")

case Cinegraph.Scrapers.OscarScraper.fetch_ceremony(2024) do
  {:ok, data} ->
    # The scraper already parsed it, but let's fetch the raw HTML
    Logger.info("Got parsed data with #{length(data.categories)} categories")
    
  {:error, _} ->
    Logger.info("Let's try getting the raw HTML directly...")
end

# Let's create a function to get just the HTML
defmodule DebugFetch do
  def get_raw_html(year) do
    api_key = System.get_env("ZYTE_API_KEY")
    
    if is_nil(api_key) or api_key == "" do
      {:error, "ZYTE_API_KEY environment variable not set"}
    else
      url = "https://www.oscars.org/oscars/ceremonies/#{year}"
    
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
end

# Fetch and save HTML for inspection
case DebugFetch.get_raw_html(2024) do
  {:ok, html} ->
    # Save to file for inspection
    filename = "oscar_2024_zyte.html"
    case File.write(filename, html) do
      :ok ->
        Logger.info("✅ Saved HTML to #{filename}")
      {:error, reason} ->
        Logger.error("Failed to save HTML: #{inspect(reason)}")
    end
    
    # Let's look for common patterns
    doc = Floki.parse_document!(html)
    
    # Try different selectors
    Logger.info("\nSearching for Oscar data patterns...")
    
    # Look for any award-related classes
    award_classes = [
      ".awards-result-chron",
      ".result-group-header", 
      ".award-category",
      ".category",
      ".nominee",
      ".winner",
      "[class*='award']",
      "[class*='nominee']",
      "[class*='winner']",
      "[class*='category']"
    ]
    
    Enum.each(award_classes, fn selector ->
      count = doc |> Floki.find(selector) |> length()
      if count > 0 do
        Logger.info("Found #{count} elements with selector: #{selector}")
        
        # Show first example
        first = doc |> Floki.find(selector) |> List.first()
        if first do
          text = Floki.text(first) |> String.trim() |> String.slice(0, 100)
          Logger.info("  Example text: #{text}...")
        end
      end
    end)
    
    # Look for any divs or sections that might contain ceremony data
    Logger.info("\nLooking for ceremony content...")
    
    # Check page title
    title = doc |> Floki.find("title") |> Floki.text()
    Logger.info("Page title: #{title}")
    
    # Check main content areas
    main_content = doc |> Floki.find("main, #main, .main-content, #content")
    Logger.info("Found #{length(main_content)} main content areas")
    
    # Look for any text mentioning "Best Picture" or other categories
    all_text = Floki.text(doc)
    if String.contains?(all_text, "Best Picture") do
      Logger.info("✅ Found 'Best Picture' in page text")
    else
      Logger.info("❌ 'Best Picture' not found in page text")
    end
    
    if String.contains?(all_text, "ceremony") || String.contains?(all_text, "Ceremony") do
      Logger.info("✅ Found 'ceremony' in page text")
    else
      Logger.info("❌ 'ceremony' not found in page text")
    end
    
  {:error, reason} ->
    Logger.error("Failed to fetch HTML: #{inspect(reason)}")
end

Logger.info("\nDebug complete! Check oscar_2024_zyte.html to inspect the full HTML.")