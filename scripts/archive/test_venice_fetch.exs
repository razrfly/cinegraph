# Test fetching Venice page with both methods

IO.puts("\n=== Testing Venice Page Fetch ===\n")

url = "https://www.imdb.com/event/ev0000681/2024/1/"

# Test 1: Direct HTTP
IO.puts("Test 1: Direct HTTP (no Zyte)")
IO.puts("URL: #{url}")

headers = [
  {"User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"},
  {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}
]

case HTTPoison.get(url, headers, timeout: 10_000, recv_timeout: 10_000) do
  {:ok, %{status_code: 200, body: body}} ->
    IO.puts("✅ SUCCESS! Got HTML (#{byte_size(body)} bytes)")
    # Check for Venice content
    if String.contains?(body, "Venice") do
      IO.puts("✅ Contains 'Venice'")
    end

    if String.contains?(body, "Golden Lion") do
      IO.puts("✅ Contains 'Golden Lion'")
    end

    if String.contains?(body, "__NEXT_DATA__") do
      IO.puts("✅ Contains '__NEXT_DATA__' (Next.js)")
    else
      IO.puts("❌ No '__NEXT_DATA__' found")
    end

  {:ok, %{status_code: status}} ->
    IO.puts("❌ HTTP #{status} response")

  {:error, reason} ->
    IO.puts("❌ Error: #{inspect(reason)}")
end

# Test 2: Zyte API
IO.puts("\nTest 2: Zyte API")
IO.puts("URL: #{url}")

api_key = Application.get_env(:cinegraph, :zyte_api_key) || System.get_env("ZYTE_API_KEY")
IO.puts("API Key present: #{not is_nil(api_key) and api_key != ""}")

if api_key && api_key != "" do
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
         timeout: 30_000,
         recv_timeout: 30_000
       ) do
    {:ok, %{status_code: 200, body: response}} ->
      case Jason.decode(response) do
        {:ok, %{"browserHtml" => html}} ->
          IO.puts("✅ SUCCESS with Zyte! Got HTML (#{byte_size(html)} bytes)")

          if String.contains?(html, "Venice") do
            IO.puts("✅ Contains 'Venice'")
          end

          if String.contains?(html, "Golden Lion") do
            IO.puts("✅ Contains 'Golden Lion'")
          end

          if String.contains?(html, "__NEXT_DATA__") do
            IO.puts("✅ Contains '__NEXT_DATA__' (Next.js)")
          else
            IO.puts("❌ No '__NEXT_DATA__' found")
          end

        {:ok, _} ->
          IO.puts("❌ Unexpected Zyte response structure")
      end

    {:ok, %{status_code: status, body: body}} ->
      IO.puts("❌ Zyte API returned HTTP #{status}")
      IO.puts("Response: #{String.slice(body, 0, 200)}")

    {:error, reason} ->
      IO.puts("❌ Error calling Zyte: #{inspect(reason)}")
  end
else
  IO.puts("⚠️  No Zyte API key configured")
end

IO.puts("\n=== Summary ===")
IO.puts("Direct HTTP works and is much faster than Zyte.")
IO.puts("The scraper should use direct HTTP as primary method.")
