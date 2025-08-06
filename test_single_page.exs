# Test processing just the first page without pagination
# Run with: mix run test_single_page.exs

alias Cinegraph.Scrapers.ImdbCanonicalScraper
alias Cinegraph.Cultural.CanonicalImporter
alias Cinegraph.Movies
alias Cinegraph.Repo

Logger.configure(level: :info)

IO.puts("🔍 Testing Single Page Import")
IO.puts("=" |> String.duplicate(50))

# First, let's just scrape and parse (no processing)
IO.puts("\n1️⃣ Step 1: Scraping and Parsing (no DB operations)")

case ImdbCanonicalScraper.scrape_and_parse_list("ls024863935", "1001 Movies") do
  {:ok, movies} ->
    IO.puts("✅ Successfully scraped #{length(movies)} movies")

    # Show first 5
    IO.puts("\nFirst 5 movies:")

    movies
    |> Enum.take(5)
    |> Enum.each(fn movie ->
      IO.puts("  • #{movie.position}. #{movie.title} - #{movie.imdb_id}")
    end)

    # Now let's test processing just the first 5 movies
    IO.puts("\n2️⃣ Step 2: Processing first 5 movies only")

    initial_count = Movies.count_canonical_movies("1001_movies")
    IO.puts("Initial canonical count: #{initial_count}")

    # Process just first 5
    results =
      movies
      |> Enum.take(5)
      |> Enum.map(fn movie ->
        # Check if movie exists
        existing = Repo.get_by(Movies.Movie, imdb_id: movie.imdb_id)

        if existing do
          # Just update canonical data
          canonical_data = %{
            "included" => true,
            "list_position" => movie.position,
            "scraped_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "edition" => "2024"
          }

          case Movies.update_canonical_sources(existing, "1001_movies", canonical_data) do
            {:ok, _} ->
              IO.puts("  ✅ Updated: #{movie.title}")
              {:updated, movie.imdb_id}

            {:error, reason} ->
              IO.puts("  ❌ Failed to update: #{movie.title} - #{inspect(reason)}")
              {:error, movie.imdb_id}
          end
        else
          IO.puts("  ❓ Not in DB: #{movie.title} (#{movie.imdb_id})")
          {:missing, movie.imdb_id}
        end
      end)

    # Summary
    IO.puts("\n📊 Processing Summary:")
    updated = Enum.count(results, fn {status, _} -> status == :updated end)
    missing = Enum.count(results, fn {status, _} -> status == :missing end)
    errors = Enum.count(results, fn {status, _} -> status == :error end)

    IO.puts("  • Updated: #{updated}")
    IO.puts("  • Missing: #{missing}")
    IO.puts("  • Errors: #{errors}")

    final_count = Movies.count_canonical_movies("1001_movies")
    IO.puts("\nFinal canonical count: #{final_count} (+#{final_count - initial_count})")

  {:error, reason} ->
    IO.puts("❌ Failed to scrape: #{inspect(reason)}")
end
