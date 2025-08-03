# Let's manually test the discovery API call to see what total_pages returns
alias Cinegraph.Services.TMDb.Client

IO.puts("Testing TMDb discovery API...")

case Client.get("/discover/movie", %{"page" => 1}) do
  {:ok, %{"results" => results, "total_pages" => total_pages} = response} ->
    IO.puts("Success\!")
    IO.puts("  Results on page 1: #{length(results)}")
    IO.puts("  Total pages: #{total_pages}")
    IO.puts("  Total results: #{response["total_results"]}")
    
    # Check first movie
    if first = List.first(results) do
      IO.puts("\nFirst movie on page 1:")
      IO.puts("  ID: #{first["id"]}")
      IO.puts("  Title: #{first["title"]}")
      exists = try do
        Cinegraph.Movies.movie_exists?(first["id"])
      rescue
        e -> 
          IO.puts("  Error checking existence: #{inspect(e)}")
          "unknown"
      end
      IO.puts("  Already exists: #{exists}")
    end
    
  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end

# Also check if we're hitting rate limits
IO.puts("\nChecking rate limiter status...")
