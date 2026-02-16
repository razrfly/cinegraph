defmodule Cinegraph.Scrapers.OscarScraper do
  @moduledoc """
  Scraper for Academy Awards data from Oscars.org.
  Following the patterns from https://github.com/DLu/oscar_data

  This module can either:
  1. Parse manually downloaded HTML from Oscars.org
  2. Fetch via configured scraping adapter (Crawlbase by default)
  """

  require Logger
  alias Cinegraph.Metrics.ApiTracker
  alias Cinegraph.Scrapers.Http.Client, as: HttpClient

  # CSS selectors - Updated for new Oscar website structure
  # Old selectors from oscar_data for reference:
  # @award_result_selector ".awards-result-chron"
  # @result_group_header_selector ".result-group-header"
  # @result_subgroup_selector ".result-subgroup"
  # @result_details_selector ".result-details"

  # New selectors for current Oscar website
  @category_selector "[data-term-id].paragraph--type--award-category"
  @category_name_selector ".field--name-field-award-category-oscars"
  @honoree_selector ".paragraph--type--award-honoree"
  @honoree_type_selector ".field--name-field-honoree-type"
  @award_entities_selector ".field--name-field-award-entities .field__item"
  @award_film_selector ".field--name-field-award-film"

  @doc """
  Parse Oscar ceremony data from HTML content.
  Can accept either raw HTML string or a file path.
  """
  def parse_ceremony_html(html_content, year) do
    case Floki.parse_document(html_content) do
      {:ok, document} ->
        ceremony_data = extract_ceremony_data(document, year)
        {:ok, ceremony_data}

      {:error, reason} ->
        Logger.error("Failed to parse HTML: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Fetch Oscar ceremony data for a specific year.
  """
  def fetch_ceremony(year) do
    url = "https://www.oscars.org/oscars/ceremonies/#{year}"

    ApiTracker.track_lookup("oscar_scraper", "fetch_ceremony", "#{year}", fn ->
      case HttpClient.fetch(url, :oscars, mode: :javascript) do
        {:ok, html} -> parse_ceremony_html(html, year)
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Fetch Oscar search results page.
  This can be used to get a broader view of ceremonies.
  """
  def fetch_search_results do
    url = "https://aasearchprod.oscars.org/search/awardsdatabase"
    HttpClient.fetch(url, :oscars, mode: :javascript)
  end

  # Private functions

  defp extract_ceremony_data(document, year) do
    %{
      year: year,
      ceremony_number: extract_ceremony_number(document, year),
      categories: extract_categories(document),
      raw_html_parsed: true,
      timestamp: DateTime.utc_now()
    }
  end

  defp extract_ceremony_number(document, year) do
    # Try to extract ceremony number from the page
    # Pattern: "95th Academy Awards" or "2023 | 95th Academy Awards"
    case Floki.find(document, "h1, .ceremony-header") |> Floki.text() do
      "" ->
        calculate_ceremony_number(year)

      text ->
        case Regex.run(~r/(\d+)(?:st|nd|rd|th)\s+Academy/i, text) do
          [_, number] -> String.to_integer(number)
          _ -> calculate_ceremony_number(year)
        end
    end
  end

  defp calculate_ceremony_number(year) do
    # First numbered ceremony (1st) was held in 1929.
    # Therefore ceremony_number = year - 1928
    year - 1928
  end

  defp extract_categories(document) do
    # Find all category containers
    document
    |> Floki.find(@category_selector)
    |> Enum.map(&extract_category_new_format/1)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_category_new_format(category_element) do
    # Extract category name
    category_name =
      category_element
      |> Floki.find(@category_name_selector)
      |> Floki.text()
      |> String.trim()

    # Extract all honorees (winners and nominees)
    nominees =
      category_element
      |> Floki.find(@honoree_selector)
      |> Enum.map(&extract_nominee_new_format/1)
      |> Enum.reject(&is_nil/1)

    if category_name != "" and length(nominees) > 0 do
      %{
        category: category_name,
        nominees: nominees
      }
    else
      nil
    end
  end

  defp extract_nominee_new_format(honoree_element) do
    # Check if winner or nominee
    honoree_type =
      honoree_element
      |> Floki.find(@honoree_type_selector)
      |> Floki.text()
      |> String.trim()
      |> String.downcase()

    is_winner = honoree_type == "winner"

    # Extract person/entity names (can be multiple for producers etc)
    names =
      honoree_element
      |> Floki.find(@award_entities_selector)
      |> Enum.map(&Floki.text/1)
      |> Enum.map(&String.trim/1)
      |> Enum.join(", ")

    # Extract film name
    film =
      honoree_element
      |> Floki.find(@award_film_selector)
      |> Floki.text()
      |> String.trim()

    if names != "" || film != "" do
      %{
        film: film,
        name: names,
        detail: nil,
        winner: is_winner,
        honoree_type: honoree_type
      }
    else
      nil
    end
  end

  @doc """
  Load ceremony HTML from a local file
  """
  def load_html_from_file(file_path) do
    case File.read(file_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Failed to read file: #{reason}"}
    end
  end
end
