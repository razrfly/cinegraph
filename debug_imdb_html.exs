# Debug script to examine IMDb list HTML structure
# Run with: mix run debug_imdb_html.exs

require Logger

# Fetch the HTML
url = "https://www.imdb.com/list/ls024863935/"
Logger.info("Fetching HTML from: #{url}")

headers = [
  {"User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"},
  {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
  {"Accept-Language", "en-US,en;q=0.5"},
  {"Accept-Encoding", "gzip, deflate"},
  {"Connection", "keep-alive"}
]

case HTTPoison.get(url, headers, timeout: 60_000, recv_timeout: 60_000) do
  {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
    Logger.info("Successfully fetched HTML (#{byte_size(body)} bytes)")

    # Save HTML to file for inspection
    case File.write("imdb_list_sample.html", body) do
      :ok -> Logger.info("Saved HTML to imdb_list_sample.html")
      {:error, reason} -> Logger.error("Failed to save HTML: #{inspect(reason)}")
    end

    # Parse with Floki and examine structure
    document = Floki.parse_document!(body)

    # Try to find any elements with movie-related text
    Logger.info("\n=== Searching for movie-related elements ===")

    # Look for title links
    title_links = Floki.find(document, "a[href*='/title/tt']")
    Logger.info("Found #{length(title_links)} title links")

    if length(title_links) > 0 do
      Logger.info("First few title links:")

      title_links
      |> Enum.take(5)
      |> Enum.with_index(1)
      |> Enum.each(fn {link, idx} ->
        href = Floki.attribute(link, "href") |> List.first()
        text = Floki.text(link) |> String.trim()
        Logger.info("  #{idx}. #{text} -> #{href}")
      end)
    end

    # Look for common list item containers
    selectors_to_try = [
      ".lister-item",
      ".titleColumn",
      ".ipc-title-link-wrapper",
      ".cli-item",
      ".list-item",
      ".movie-item",
      "[data-testid*='title']",
      ".ipc-title",
      ".titleColumn",
      "li[class*='item']",
      "div[class*='item']",
      "article",
      ".ipc-metadata-list-summary-item"
    ]

    Logger.info("\n=== Testing selectors ===")

    selectors_to_try
    |> Enum.each(fn selector ->
      items = Floki.find(document, selector)
      count = length(items)
      Logger.info("#{selector}: #{count} items")

      if count > 0 && count < 20 do
        Logger.info("  Sample classes: #{inspect(Floki.attribute(List.first(items), "class"))}")
      end
    end)

    # Look for any elements containing movie years (pattern: (1999))
    Logger.info("\n=== Searching for year patterns ===")

    year_elements =
      Floki.find(document, "*")
      |> Enum.filter(fn element ->
        text = Floki.text(element)
        String.match?(text, ~r/\(\d{4}\)/)
      end)
      |> Enum.take(10)

    Logger.info("Found #{length(year_elements)} elements with year patterns")

    year_elements
    |> Enum.each(fn element ->
      text = Floki.text(element) |> String.trim()

      if String.length(text) < 100 do
        Logger.info("  Year element: #{text}")
      end
    end)

    Logger.info("\n✅ Debug complete! Check imdb_list_sample.html and logs above")

  {:ok, %HTTPoison.Response{status_code: status_code}} ->
    Logger.error("HTTP error #{status_code}")

  {:error, reason} ->
    Logger.error("Network error: #{inspect(reason)}")
end
