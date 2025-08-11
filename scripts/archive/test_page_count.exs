# Quick test to see how many pages the list has
# Run with: mix run test_page_count.exs

Logger.configure(level: :warn)

alias Cinegraph.Scrapers.ImdbCanonicalScraper

# Test fetching pages until no more movies found
defmodule PageTest do
  # IMDb typically shows 250 movies per page, but this can vary
  @movies_per_page 250
  def count_pages(list_id) do
    IO.puts("Checking pages for list #{list_id}...")
    count_pages_recursive(list_id, 1, 0)
  end

  defp count_pages_recursive(list_id, page, total_movies) do
    url =
      if page == 1 do
        "https://www.imdb.com/list/#{list_id}/"
      else
        "https://www.imdb.com/list/#{list_id}/?page=#{page}"
      end

    IO.write("  Page #{page}: ")

    case fetch_and_count(url) do
      {:ok, count} when count > 0 ->
        IO.puts("#{count} movies (total so far: #{total_movies + count})")

        if count >= @movies_per_page do
          # Likely more pages
          count_pages_recursive(list_id, page + 1, total_movies + count)
        else
          # Last page
          IO.puts("\nTotal pages: #{page}")
          IO.puts("Total movies: #{total_movies + count}")
        end

      _ ->
        IO.puts("No movies found")
        IO.puts("\nTotal pages: #{page - 1}")
        IO.puts("Total movies: #{total_movies}")
    end
  end

  defp fetch_and_count(url) do
    api_key = Application.get_env(:cinegraph, :zyte_api_key) || System.get_env("ZYTE_API_KEY")

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

    options = [timeout: 60_000, recv_timeout: 60_000]

    case HTTPoison.post("https://api.zyte.com/v1/extract", body, headers, options) do
      {:ok, %{status_code: 200, body: response}} ->
        case Jason.decode(response) do
          {:ok, %{"browserHtml" => html}} ->
            document = Floki.parse_document!(html)

            # Count movies using both selectors
            lister_count = length(Floki.find(document, ".lister-item"))
            ipc_count = length(Floki.find(document, ".ipc-metadata-list-summary-item"))

            {:ok, max(lister_count, ipc_count)}

          _ ->
            {:error, "Failed to parse JSON"}
        end

      _ ->
        {:error, "Failed to fetch"}
    end
  end
end

PageTest.count_pages("ls024863935")
