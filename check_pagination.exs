# Script to check the pagination on IMDb list
# Run with: mix run check_pagination.exs

require Logger

url = "https://www.imdb.com/list/ls024863935/"
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

case HTTPoison.post("https://api.zyte.com/v1/extract", body, headers, options) do
  {:ok, %{status_code: 200, body: response}} ->
    case Jason.decode(response) do
      {:ok, %{"browserHtml" => html}} ->
        IO.puts("Successfully fetched HTML (#{byte_size(html)} bytes)")
        
        # Save for inspection
        File.write!("pagination_sample.html", html)
        
        # Parse with Floki
        document = Floki.parse_document!(html)
        
        # Look for pagination elements
        IO.puts("\n=== Checking for pagination elements ===")
        
        # Common pagination selectors
        pagination_selectors = [
          ".list-pagination",
          ".pagination",
          ".pager",
          ".lister-page-next",
          "a.next-page",
          "a[aria-label='Next']",
          ".load-more",
          "button.load-more",
          "[data-testid='pagination']",
          ".ipc-see-more"
        ]
        
        Enum.each(pagination_selectors, fn selector ->
          elements = Floki.find(document, selector)
          IO.puts("#{selector}: #{length(elements)} found")
          
          if length(elements) > 0 do
            IO.puts("  Sample HTML: #{elements |> List.first() |> Floki.raw_html() |> String.slice(0..200)}")
          end
        end)
        
        # Look for "Load More" or similar buttons
        IO.puts("\n=== Checking for load more buttons ===")
        
        buttons = Floki.find(document, "button")
        load_more_buttons = Enum.filter(buttons, fn button ->
          text = Floki.text(button) |> String.downcase()
          String.contains?(text, "more") || String.contains?(text, "load") || String.contains?(text, "next")
        end)
        
        IO.puts("Found #{length(load_more_buttons)} potential load more buttons")
        Enum.each(load_more_buttons, fn button ->
          IO.puts("  Button text: #{Floki.text(button) |> String.trim()}")
        end)
        
        # Look for any elements with "250" text (indicating pagination info)
        IO.puts("\n=== Checking for count indicators ===")
        
        count_indicators = Floki.find(document, "*")
        |> Enum.filter(fn element ->
          text = Floki.text(element)
          String.contains?(text, "250") || String.contains?(text, "1,260") || String.contains?(text, "1260")
        end)
        |> Enum.take(5)
        
        IO.puts("Found #{length(count_indicators)} elements mentioning counts")
        Enum.each(count_indicators, fn element ->
          text = Floki.text(element) |> String.trim()
          if String.length(text) < 200 do
            IO.puts("  Text: #{text}")
          end
        end)
        
        # Check for specific IMDb list pagination
        IO.puts("\n=== Checking IMDb-specific pagination ===")
        
        # Look for the list description that shows total count
        desc_elements = Floki.find(document, ".list-description, .lister-description, .ipc-html-content")
        IO.puts("Description elements: #{length(desc_elements)}")
        
        Enum.each(desc_elements, fn element ->
          text = Floki.text(element) |> String.trim()
          if String.length(text) < 500 do
            IO.puts("  Description: #{text}")
          end
        end)
        
      error ->
        IO.puts("Failed to parse JSON: #{inspect(error)}")
    end
    
  {:ok, %{status_code: status, body: body}} ->
    IO.puts("HTTP error #{status}: #{body}")
    
  {:error, reason} ->
    IO.puts("Network error: #{inspect(reason)}")
end