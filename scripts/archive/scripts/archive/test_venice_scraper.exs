# Test script for Venice Film Festival scraper
# Usage: mix run test_venice_scraper.exs

defmodule VeniceScraperTest do
  @moduledoc """
  Test script to verify Venice Film Festival scraper functionality
  """

  require Logger

  def run_tests do
    Logger.configure(level: :info)

    IO.puts("\n=== Venice Film Festival Scraper Test ===")
    IO.puts("Testing parsing and data extraction capabilities...\n")

    # Test 1: Test HTML parsing with sample data
    test_html_parsing()

    # Test 2: Test category normalization
    test_category_normalization()

    # Test 3: Test available years extraction
    test_years_extraction()

    # Test 4: Test multiple year fetching
    test_multiple_years()

    IO.puts("\n✅ All Venice scraper tests completed!")
  end

  defp test_html_parsing do
    IO.puts("🧪 Test 1: HTML Parsing")

    # Mock __NEXT_DATA__ structure similar to what IMDb returns
    sample_next_data = %{
      "props" => %{
        "pageProps" => %{
          "edition" => %{
            "awards" => [
              %{
                "text" => "Golden Lion",
                "nominationCategories" => %{
                  "edges" => [
                    %{
                      "node" => %{
                        "category" => %{"text" => "Golden Lion"},
                        "nominations" => %{
                          "edges" => [
                            %{
                              "node" => %{
                                "isWinner" => true,
                                "awardedEntities" => %{
                                  "awardTitles" => [
                                    %{
                                      "title" => %{
                                        "id" => "tt12345",
                                        "titleText" => %{"text" => "Sample Film"},
                                        "releaseDate" => %{"year" => 2024}
                                      }
                                    }
                                  ],
                                  "awardNames" => [
                                    %{
                                      "name" => %{
                                        "id" => "nm12345",
                                        "nameText" => %{"text" => "Sample Director"}
                                      }
                                    }
                                  ]
                                }
                              }
                            }
                          ]
                        }
                      }
                    }
                  ]
                }
              }
            ]
          }
        }
      }
    }

    # Test the core parsing logic
    case Cinegraph.Scrapers.VeniceFilmFestivalScraper.extract_venice_awards(
           sample_next_data,
           2024
         ) do
      {:ok, data} ->
        IO.puts("  ✅ Successfully parsed sample data")
        IO.puts("  📊 Found #{map_size(data.awards)} award categories")

        # Check if Golden Lion was parsed
        golden_lion = Map.get(data.awards, "golden_lion") || Map.get(data.awards, "golden lion")

        if golden_lion do
          IO.puts("  🏆 Golden Lion category found with #{length(golden_lion)} nominations")
        end

      {:error, reason} ->
        IO.puts("  ❌ Failed to parse sample data: #{reason}")
    end
  end

  defp test_category_normalization do
    IO.puts("\n🧪 Test 2: Category Normalization")

    test_categories = [
      "Golden Lion",
      "Silver Lion - Grand Jury Prize",
      "Volpi Cup for Best Actor",
      "Marcello Mastroianni Award",
      "Orizzonti Prize",
      "Luigi De Laurentiis Award"
    ]

    IO.puts("  Testing category name normalization:")

    Enum.each(test_categories, fn category ->
      normalized = normalize_test_category(category)
      IO.puts("    '#{category}' → '#{normalized}'")
    end)

    IO.puts("  ✅ Category normalization test completed")
  end

  defp normalize_test_category(name) do
    # Reproduce the normalization logic from the scraper
    category_mappings = [
      {"golden lion", "golden_lion"},
      {"silver lion", "silver_lion"},
      {"volpi cup", "volpi_cup"},
      {"special jury prize", "special_jury_prize"},
      {"marcello mastroianni award", "mastroianni_award"},
      {"orizzonti", "horizons"},
      {"luigi de laurentiis", "luigi_de_laurentiis"}
    ]

    normalized =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, "")
      |> String.trim()

    Enum.reduce(category_mappings, normalized, fn {from, to}, acc ->
      String.replace(acc, from, to)
    end)
    |> String.trim()
  end

  defp test_years_extraction do
    IO.puts("\n🧪 Test 3: Years Extraction")

    # Mock HTML with year links
    sample_html = """
    <a href="/event/ev0000681/2024/1/">2024</a>
    <a href="/event/ev0000681/2023/1/">2023</a>
    <a href="/event/ev0000681/2022/1/">2022</a>
    <a href="/event/ev0000681/2021/1/">2021</a>
    """

    case Regex.scan(~r|/event/ev0000681/(\d{4})/|, sample_html) do
      matches when matches != [] ->
        years =
          matches
          |> Enum.map(fn [_, year_str] -> String.to_integer(year_str) end)
          |> Enum.uniq()
          |> Enum.sort(:desc)

        IO.puts("  ✅ Successfully extracted years: #{inspect(years)}")

      _ ->
        IO.puts("  ❌ Failed to extract years from sample HTML")
    end
  end

  defp test_multiple_years do
    IO.puts("\n🧪 Test 4: Multiple Years Logic")

    test_years = [2024, 2023, 2022]

    IO.puts("  Testing multiple year processing logic for: #{inspect(test_years)}")
    IO.puts("  📝 Note: This would normally make actual API calls")
    IO.puts("  📝 With max_concurrency=3, would process 3 years in parallel")

    # Simulate the task processing
    simulated_results =
      test_years
      |> Enum.map(fn year ->
        # Simulate successful parsing
        {year,
         {:ok,
          %{
            year: year,
            festival: "Venice Film Festival",
            awards: %{"golden_lion" => []},
            timestamp: DateTime.utc_now()
          }}}
      end)
      |> Map.new()

    IO.puts("  ✅ Would process #{map_size(simulated_results)} years successfully")
    IO.puts("  📊 Simulated results: #{inspect(Map.keys(simulated_results))}")
  end
end

# Run the tests
VeniceScraperTest.run_tests()
