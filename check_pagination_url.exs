# Check if pagination works with URL parameters
# Run with: mix run check_pagination_url.exs

require Logger

# Try page 2
url = "https://www.imdb.com/list/ls024863935/?page=2"
api_key = Application.get_env(:cinegraph, :zyte_api_key) || System.get_env("ZYTE_API_KEY")

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

IO.puts("Fetching page 2 from: #{url}")

case HTTPoison.post("https://api.zyte.com/v1/extract", body, headers, options) do
  {:ok, %{status_code: 200, body: response}} ->
    case Jason.decode(response) do
      {:ok, %{"browserHtml" => html}} ->
        IO.puts("Successfully fetched HTML (#{byte_size(html)} bytes)")
        
        # Parse with Floki
        document = Floki.parse_document!(html)
        
        # Look for movie items
        list_items = Floki.find(document, ".lister-item")
        IO.puts("Found #{length(list_items)} .lister-item elements")
        
        if length(list_items) > 0 do
          # Get first movie title
          first_item = List.first(list_items)
          title_link = Floki.find(first_item, "a[href*='/title/tt']") |> List.first()
          if title_link do
            title = Floki.text(title_link) |> String.trim()
            IO.puts("First movie on page 2: #{title}")
          end
          
          # Check if it's a different set of movies
          titles = list_items
          |> Enum.take(5)
          |> Enum.map(fn item ->
            title_link = Floki.find(item, "a[href*='/title/tt']") |> List.first()
            if title_link, do: Floki.text(title_link) |> String.trim(), else: nil
          end)
          |> Enum.reject(&is_nil/1)
          
          IO.puts("\nFirst 5 movies on page 2:")
          Enum.each(titles, fn title ->
            IO.puts("  - #{title}")
          end)
        else
          IO.puts("No .lister-item elements found, trying alternative selectors...")
          
          # Try alternative selectors
          alt_selectors = [
            ".titleColumn",
            ".ipc-title-link-wrapper",
            ".cli-item",
            ".list-item",
            ".movie-item"
          ]
          
          Enum.each(alt_selectors, fn selector ->
            items = Floki.find(document, selector)
            if length(items) > 0 do
              IO.puts("Found #{length(items)} #{selector} elements")
            end
          end)
        end
        
      error ->
        IO.puts("Failed to parse JSON: #{inspect(error)}")
    end
    
  {:ok, %{status_code: status, body: body}} ->
    IO.puts("HTTP error #{status}: #{body}")
    
  {:error, reason} ->
    IO.puts("Network error: #{inspect(reason)}")
end