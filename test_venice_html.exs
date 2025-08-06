# Test fetching raw HTML from Venice 2025 page
url = "https://www.imdb.com/event/ev0000681/2025/1/"
api_key = Application.get_env(:cinegraph, :zyte_api_key)

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

IO.puts("Fetching Venice 2025 page from IMDb...")

case HTTPoison.post("https://api.zyte.com/v1/extract", body, headers,
       timeout: 30_000,
       recv_timeout: 30_000
     ) do
  {:ok, %{status_code: 200, body: response}} ->
    case Jason.decode(response) do
      {:ok, %{"browserHtml" => html}} ->
        # Save HTML for inspection
        File.write!("venice_2025.html", html)
        IO.puts("✅ HTML saved to venice_2025.html (#{byte_size(html)} bytes)")

        # Check for various possible data structures
        IO.puts("\n=== HTML Structure Analysis ===")
        IO.puts("Has __NEXT_DATA__: #{String.contains?(html, "__NEXT_DATA__")}")
        IO.puts("Has event-awards: #{String.contains?(html, "event-awards")}")
        IO.puts("Has nominee: #{String.contains?(html, "nominee")}")
        IO.puts("Has winner: #{String.contains?(html, "winner")}")

        # Check for specific Venice awards
        awards = [
          {"Golden Lion", "Golden Lion"},
          {"Silver Lion", "Silver Lion"},
          {"Volpi Cup", "Volpi Cup"},
          {"Special Jury Prize", "Special Jury Prize"},
          {"Marcello Mastroianni", "Mastroianni Award"}
        ]

        IO.puts("\n=== Venice Awards Found ===")

        Enum.each(awards, fn {search_term, name} ->
          if String.contains?(html, search_term) do
            IO.puts("✅ Found #{name}")
          else
            IO.puts("❌ Missing #{name}")
          end
        end)

        # Look for the actual data structure
        cond do
          String.contains?(html, "__NEXT_DATA__") ->
            IO.puts("\n📊 Page uses Next.js with __NEXT_DATA__")

          String.contains?(html, "data-testid") ->
            IO.puts("\n📊 Page uses React with data-testid attributes")

          String.contains?(html, "class=\"awards-section\"") ||
              String.contains?(html, "awards-list") ->
            IO.puts("\n📊 Page has traditional HTML structure with awards sections")

          true ->
            IO.puts("\n⚠️  Unknown page structure - may need alternative parsing")
        end

        # Try to extract some sample award data
        if String.contains?(html, "The Room Next Door") do
          IO.puts("\n✅ Found 'The Room Next Door' (2025 Golden Lion winner)")
        end

      {:ok, other} ->
        IO.puts("❌ Unexpected response structure: #{inspect(Map.keys(other))}")
    end

  {:ok, %{status_code: status, body: body}} ->
    IO.puts("❌ HTTP #{status} response: #{String.slice(body, 0, 200)}")

  {:error, reason} ->
    IO.puts("❌ Error: #{inspect(reason)}")
end
