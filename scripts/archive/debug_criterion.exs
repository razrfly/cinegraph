# Debug script to compare HTML structure between lists
# Run with: mix run debug_criterion.exs

require Logger
alias Cinegraph.Scrapers.ImdbCanonicalScraper

# Test both lists
lists = [
  {"ls024863935", "1001 Movies"},
  {"ls020763765", "Criterion Collection"}
]

Enum.each(lists, fn {list_id, name} ->
  IO.puts("\n=== Testing #{name} (#{list_id}) ===")

  url = "https://www.imdb.com/list/#{list_id}/"
  IO.puts("URL: #{url}")

  # First, try the scraper's fetch_single_page method
  case ImdbCanonicalScraper.fetch_single_page(list_id, 1) do
    {:ok, movies} ->
      IO.puts("✅ Scraper found #{length(movies)} movies")

      if length(movies) > 0 do
        first = List.first(movies)
        IO.puts("First movie: #{inspect(first)}")
      end

    {:error, reason} ->
      IO.puts("❌ Scraper error: #{inspect(reason)}")
  end

  # Now let's fetch the HTML directly and save it
  api_key = Application.get_env(:cinegraph, :zyte_api_key) || System.get_env("ZYTE_API_KEY")

  if api_key do
    headers = [
      {"Authorization", "Basic #{Base.encode64(api_key <> ":")}"},
      {"Content-Type", "application/json"}
    ]

    body =
      Jason.encode!(%{
        url: url,
        browserHtml: true,
        javascript: true,
        viewport: %{width: 1920, height: 1080}
      })

    case HTTPoison.post("https://api.zyte.com/v1/extract", body, headers,
           timeout: 60_000,
           recv_timeout: 60_000
         ) do
      {:ok, %{status_code: 200, body: response}} ->
        case Jason.decode(response) do
          {:ok, %{"browserHtml" => html}} ->
            filename = "#{String.replace(name, " ", "_")}_sample.html"
            File.write!(filename, html)
            IO.puts("Saved HTML to #{filename} (#{byte_size(html)} bytes)")

            # Parse and check structure
            document = Floki.parse_document!(html)

            # Check for various selectors
            IO.puts("\nChecking selectors:")

            selectors = [
              ".lister-item",
              ".ipc-metadata-list-summary-item",
              ".titleColumn",
              "a[href*='/title/tt']"
            ]

            Enum.each(selectors, fn selector ->
              count = length(Floki.find(document, selector))
              IO.puts("  #{selector}: #{count} items")
            end)

          _ ->
            IO.puts("Failed to parse Zyte response")
        end

      error ->
        IO.puts("Failed to fetch HTML: #{inspect(error)}")
    end
  else
    IO.puts("No Zyte API key configured")
  end
end)
