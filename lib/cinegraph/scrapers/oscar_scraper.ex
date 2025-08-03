defmodule Cinegraph.Scrapers.OscarScraper do
  @moduledoc """
  Scraper for Academy Awards data from Oscars.org using Zyte API
  Following the patterns from https://github.com/DLu/oscar_data
  
  This module can either:
  1. Parse manually downloaded HTML from Oscars.org
  2. Fetch via Zyte API for better reliability
  """
  
  require Logger
  
  @zyte_api_url "https://api.zyte.com/v1/extract"
  @timeout 60_000
  @max_retries 3
  
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
  Fetch Oscar ceremony data for a specific year using Zyte API.
  """
  def fetch_ceremony(year) do
    url = "https://www.oscars.org/oscars/ceremonies/#{year}"
    fetch_with_zyte(url, year)
  end
  
  @doc """
  Fetch Oscar search results page using Zyte API.
  This can be used to get a broader view of ceremonies.
  """
  def fetch_search_results do
    url = "https://aasearchprod.oscars.org/search/awardsdatabase"
    fetch_with_zyte(url, nil)
  end
  
  defp fetch_with_zyte(url, year, retries \\ 0) do
    api_key = Application.get_env(:cinegraph, :zyte_api_key)
    
    if is_nil(api_key) || api_key == "" do
      Logger.error("No ZYTE_API_KEY configured")
      {:error, "Missing ZYTE_API_KEY"}
    else
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
        timeout: @timeout,
        recv_timeout: @timeout,
        hackney: [pool: :default]
      ]
      
      case HTTPoison.post(@zyte_api_url, body, headers, options) do
        {:ok, %{status_code: 200, body: response}} ->
          case Jason.decode(response) do
            {:ok, %{"browserHtml" => html}} ->
              if year do
                parse_ceremony_html(html, year)
              else
                {:ok, html}
              end
              
            error ->
              Logger.error("Failed to parse Zyte response: #{inspect(error)}")
              retry_or_fail(url, year, retries, "JSON parsing failed")
          end
          
        {:ok, %{status_code: status, body: body}} ->
          Logger.error("Zyte API error (#{status}): #{body}")
          retry_or_fail(url, year, retries, "HTTP #{status}")
          
        {:error, %HTTPoison.Error{reason: reason}} ->
          Logger.error("Failed to fetch from Zyte: #{inspect(reason)}")
          retry_or_fail(url, year, retries, "HTTP error: #{inspect(reason)}")
      end
    end
  end
  
  defp retry_or_fail(_url, _year, retries, error) when retries >= @max_retries do
    Logger.error("Max retries (#{@max_retries}) reached. Last error: #{error}")
    {:error, error}
  end
  
  defp retry_or_fail(url, year, retries, error) do
    new_retries = retries + 1
    Logger.info("Retrying request (attempt #{new_retries}/#{@max_retries}). Previous error: #{error}")
    Process.sleep(1000 * new_retries) # Exponential backoff
    fetch_with_zyte(url, year, new_retries)
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
      "" -> calculate_ceremony_number(year)
      text ->
        case Regex.run(~r/(\d+)(?:st|nd|rd|th)\s+Academy/i, text) do
          [_, number] -> String.to_integer(number)
          _ -> calculate_ceremony_number(year)
        end
    end
  end
  
  defp calculate_ceremony_number(year) do
    # First ceremony was in 1929 for 1927-1928 films
    # This is an approximation
    year - 1927
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