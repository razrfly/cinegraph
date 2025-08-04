defmodule Cinegraph.Scrapers.ImdbCanonicalScraper do
  @moduledoc """
  Generic scraper for IMDb user lists that contain canonical movie collections.
  Can scrape any IMDb list (ls*) format and mark movies as canonical sources.
  
  Examples of canonical lists:
  - 1001 Movies You Must See Before You Die: ls024863935
  - Sight & Sound Greatest Films: (would be another ls* ID)
  - Criterion Collection: (would be another ls* ID)
  
  This scraper is designed to be data-driven - just add new list configurations
  and it will handle the scraping automatically.
  """
  
  require Logger
  alias Cinegraph.{Repo, Movies}
  alias Cinegraph.Workers.TMDbDetailsWorker
  
  @timeout 60_000
  
  @doc """
  Scrape any IMDb user list and mark movies as canonical.
  
  ## Parameters
  - `list_id`: The IMDb list ID (e.g., "ls024863935")
  - `source_key`: Internal key for this canonical source (e.g., "1001_movies", "sight_sound")
  - `list_name`: Human-readable name for the list
  - `metadata`: Optional additional metadata to store with each movie
  
  ## Examples
      # 1001 Movies list
      scrape_imdb_list("ls024863935", "1001_movies", "1001 Movies You Must See Before You Die")
      
      # Sight & Sound list (example)
      scrape_imdb_list("ls123456789", "sight_sound", "Sight & Sound Greatest Films of All Time")
      
      # Criterion Collection list (example)
      scrape_imdb_list("ls987654321", "criterion", "The Criterion Collection")
  """
  def scrape_imdb_list(list_id, source_key, list_name, metadata \\ %{}) do
    list_config = %{
      list_id: list_id,
      source_key: source_key,
      name: list_name,
      metadata: metadata
    }
    
    Logger.info("Scraping IMDb list: #{list_name} (#{list_id})")
    
    # Scrape all pages
    all_movies = scrape_all_pages(list_id, list_config)
    
    Logger.info("Total movies found: #{length(all_movies)}")
    
    if length(all_movies) > 0 do
      {:ok, processed_results} = process_canonical_movies(all_movies, list_config)
      Logger.info("Successfully scraped #{list_name}: #{length(all_movies)} movies total")
      {:ok, processed_results}
    else
      Logger.error("No movies found for #{list_name}")
      {:error, "No movies found"}
    end
  end
  
  @doc """
  Scrape multiple IMDb lists from a configuration.
  
  ## Example
      lists = [
        %{list_id: "ls024863935", source_key: "1001_movies", name: "1001 Movies You Must See Before You Die"},
        %{list_id: "ls123456789", source_key: "sight_sound", name: "Sight & Sound Greatest Films"},
        %{list_id: "ls987654321", source_key: "criterion", name: "The Criterion Collection"}
      ]
      
      scrape_multiple_lists(lists)
  """
  def scrape_multiple_lists(list_configs) when is_list(list_configs) do
    results = 
      list_configs
      |> Enum.map(fn config ->
        list_id = config[:list_id] || config["list_id"]
        source_key = config[:source_key] || config["source_key"] 
        name = config[:name] || config["name"]
        metadata = config[:metadata] || config["metadata"] || %{}
        
        case scrape_imdb_list(list_id, source_key, name, metadata) do
          {:ok, result} ->
            %{
              list_id: list_id,
              source_key: source_key,
              name: name,
              status: :success,
              movies: result.summary.total,
              result: result
            }
            
          {:error, reason} ->
            %{
              list_id: list_id,
              source_key: source_key,
              name: name,
              status: :error,
              reason: reason,
              movies: 0
            }
        end
      end)
    
    total_movies = results |> Enum.map(& &1[:movies] || 0) |> Enum.sum()
    successful = results |> Enum.count(& &1[:status] == :success)
    
    Logger.info("Batch scraping complete: #{successful}/#{length(results)} lists, #{total_movies} total movies")
    
    {:ok, %{
      results: results,
      total_lists: length(results),
      successful_lists: successful,
      total_movies: total_movies
    }}
  end
  
  @doc """
  Scrape a canonical list by its key using the centralized configuration.
  
  ## Examples
      scrape_list_by_key("1001_movies")
      scrape_list_by_key("criterion")
  """
  def scrape_list_by_key(list_key) when is_binary(list_key) do
    case Cinegraph.CanonicalLists.get(list_key) do
      {:ok, config} ->
        scrape_imdb_list(
          config.list_id,
          config.source_key,
          config.name,
          config.metadata || %{}
        )
        
      {:error, reason} ->
        Logger.error("Failed to scrape list #{list_key}: #{reason}")
        {:error, reason}
    end
  end
  
  @doc """
  Fetch a single page of an IMDb list.
  Returns just the movie data without processing.
  """
  def fetch_single_page(list_id, page \\ 1) do
    url = build_imdb_list_url(list_id, page)
    
    Logger.info("Fetching page #{page} from IMDb list #{list_id}")
    
    with {:ok, html} <- fetch_html(url),
         {:ok, movies} <- parse_single_page(html, page) do
      {:ok, movies}
    else
      {:error, reason} ->
        Logger.error("Failed to fetch page #{page}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  @doc """
  Get total number of pages for a list.
  Fetches first page and checks for pagination info.
  """
  def get_total_pages(list_id) do
    url = build_imdb_list_url(list_id, 1)
    
    case fetch_html(url) do
      {:ok, html} ->
        document = Floki.parse_document!(html)
        
        # Try to find total count or pagination info
        # Look for patterns like "1-250 of 1,260" or pagination links
        total_pages = detect_total_pages(document)
        
        Logger.info("Detected #{total_pages} pages for list #{list_id}")
        {:ok, total_pages}
        
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  defp detect_total_pages(document) do
    # Try to find total count from various possible locations
    count_text = find_total_count_text(document)
    
    if count_text do
      # Parse patterns like "1-250 of 1,260" or "1,260 titles"
      case Regex.run(~r/of\s+([\d,]+)|(\d+,?\d*)\s+titles?/i, count_text) do
        [_, total] ->
          parse_total_count(total)
        [_, _, total] ->
          parse_total_count(total)
        _ ->
          estimate_pages_from_first_page(document)
      end
    else
      estimate_pages_from_first_page(document)
    end
  end
  
  defp find_total_count_text(document) do
    # Various selectors where IMDb might show total count
    count_selectors = [
      ".desc",
      ".list-description",
      ".lister-current-last-item",
      ".lister-total-num-results",
      "span.lister-current-last-item",
      ".header-list-count",
      ".list-meta"
    ]
    
    count_selectors
    |> Enum.find_value(fn selector ->
      case Floki.find(document, selector) do
        [] -> nil
        elements -> 
          text = Floki.text(elements) |> String.trim()
          if String.match?(text, ~r/\d+/), do: text, else: nil
      end
    end)
  end
  
  defp parse_total_count(total_str) do
    # Remove commas and parse
    total = total_str
    |> String.replace(",", "")
    |> String.trim()
    |> String.to_integer()
    
    # Calculate pages (250 items per page)
    div(total - 1, 250) + 1
  end
  
  defp estimate_pages_from_first_page(document) do
    # Count movies on first page
    movie_count = count_movies_on_page(document)
    
    if movie_count >= 250 do
      # For known lists, use hardcoded values
      # This is a fallback - in production, we'd want better detection
      6  # Default for 1001 Movies list
    else
      1
    end
  end
  
  @doc """
  Get metadata about a list (name, total count, etc).
  """
  def get_list_info(list_id) do
    url = build_imdb_list_url(list_id, 1)
    
    case fetch_html(url) do
      {:ok, html} ->
        document = Floki.parse_document!(html)
        
        # Try to extract list title and description
        title = extract_list_title(document)
        description = extract_list_description(document)
        
        {:ok, %{
          list_id: list_id,
          title: title,
          description: description,
          url: url
        }}
        
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  # Helper function for fetch_single_page
  defp parse_single_page(html, page) do
    # Reuse existing parsing logic
    list_config = %{name: "Single page"}
    parse_imdb_list_html(html, list_config, page)
  end
  
  # Helper function to extract list title
  defp extract_list_title(document) do
    # Try various selectors for list title
    title_selectors = [
      "h1",
      ".header h1",
      ".list-title",
      "title"
    ]
    
    title_selectors
    |> Enum.find_value(fn selector ->
      case Floki.find(document, selector) do
        [] -> nil
        elements -> 
          text = Floki.text(elements) |> String.trim()
          if text != "", do: text, else: nil
      end
    end) || "Unknown List"
  end
  
  # Helper function to extract list description
  defp extract_list_description(document) do
    # Try various selectors for list description
    description_selectors = [
      ".list-description",
      ".list-intro",
      "meta[name='description']",
      ".header-list-description"
    ]
    
    description_selectors
    |> Enum.find_value(fn selector ->
      case Floki.find(document, selector) do
        [] -> nil
        elements -> 
          if String.contains?(selector, "meta") do
            Floki.attribute(elements, "content") |> List.first()
          else
            text = Floki.text(elements) |> String.trim()
            if text != "", do: text, else: nil
          end
      end
    end) || ""
  end
  
  @doc """
  DEPRECATED: Scrape and parse a list returning all pages.
  Use fetch_single_page for better control.
  """
  def scrape_and_parse_list(list_id, list_name) do
    Logger.warning("scrape_and_parse_list is deprecated. Use fetch_single_page for better control.")
    
    # For backward compatibility, fetch just the first page
    case fetch_single_page(list_id, 1) do
      {:ok, movies} ->
        Logger.info("Successfully parsed #{list_name}: #{length(movies)} movies found (first page only)")
        {:ok, movies}
        
      {:error, reason} ->
        Logger.error("Failed to scrape and parse #{list_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  # Private functions
  
  defp scrape_all_pages(list_id, list_config, page \\ 1, accumulated_movies \\ []) do
    url = build_imdb_list_url(list_id, page)
    
    Logger.info("Scraping page #{page} from: #{url}")
    
    case fetch_html(url) do
      {:ok, html} ->
        case parse_imdb_list_html(html, list_config, page) do
          {:ok, movies} when movies != [] ->
            # Adjust movie positions based on accumulated movies
            adjusted_movies = 
              movies
              |> Enum.map(fn movie ->
                %{movie | position: length(accumulated_movies) + movie.position}
              end)
            
            new_accumulated = accumulated_movies ++ adjusted_movies
            
            # Check if there are more pages by looking for pagination links
            if has_next_page?(html) do
              Logger.info("Found #{length(movies)} movies on page #{page}, continuing to page #{page + 1}...")
              # Add a small delay to be respectful
              Process.sleep(1000)
              scrape_all_pages(list_id, list_config, page + 1, new_accumulated)
            else
              Logger.info("Found #{length(movies)} movies on page #{page} (last page)")
              new_accumulated
            end
            
          _ ->
            Logger.info("No movies found on page #{page}, stopping pagination")
            accumulated_movies
        end
        
      {:error, reason} ->
        Logger.error("Failed to fetch page #{page}: #{inspect(reason)}")
        accumulated_movies
    end
  end
  
  defp has_next_page?(html) do
    # For IMDb lists, check if we have the expected number of items
    # The 1001 Movies list has 1260 movies total, with 250 per page
    # So there should be 6 pages total (250 * 5 + 10)
    
    # Check if there's a "Next" button or if we haven't reached the end
    document = Floki.parse_document!(html)
    
    # Look for any next/load more buttons
    next_indicators = [
      "button",  # Check text content separately
      "a.next-page",
      "a[aria-label='Next']",
      ".pagination a",
      ".list-pagination a",
      "a.lister-page-next",
      ".ipc-see-more"
    ]
    
    has_next = Enum.any?(next_indicators, fn selector ->
      elements = Floki.find(document, selector)
      if selector == "button" || String.contains?(selector, ".pagination") || String.contains?(selector, ".list-pagination") do
        # Check if any element contains "Next" in its text
        Enum.any?(elements, fn element ->
          text = Floki.text(element) |> String.downcase()
          String.contains?(text, "next")
        end)
      else
        length(elements) > 0
      end
    end)
    
    if has_next do
      true
    else
      # If no explicit next button, check if we got a full page of results
      # which might indicate there are more pages
      movie_count = count_movies_on_page(document)
      movie_count >= 250
    end
  end
  
  defp count_movies_on_page(document) do
    # Count movies using both old and new selectors
    lister_items = Floki.find(document, ".lister-item")
    ipc_items = Floki.find(document, ".ipc-title-link-wrapper")
    
    max(length(lister_items), length(ipc_items))
  end
  
  defp build_imdb_list_url(list_id, page) do
    if page == 1 do
      "https://www.imdb.com/list/#{list_id}/"
    else
      "https://www.imdb.com/list/#{list_id}/?page=#{page}"
    end
  end
  
  defp fetch_html(url) do
    Logger.info("Fetching HTML from: #{url}")
    
    # Use Zyte API like the Oscar scraper
    api_key = Application.get_env(:cinegraph, :zyte_api_key) || System.get_env("ZYTE_API_KEY")
    
    if is_nil(api_key) || api_key == "" do
      Logger.error("No ZYTE_API_KEY configured, falling back to direct HTTP")
      fetch_html_direct(url)
    else
      fetch_html_with_zyte(url, api_key)
    end
  end
  
  defp fetch_html_with_zyte(url, api_key) do
    zyte_api_url = "https://api.zyte.com/v1/extract"
    
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
    
    case HTTPoison.post(zyte_api_url, body, headers, options) do
      {:ok, %{status_code: 200, body: response}} ->
        case Jason.decode(response) do
          {:ok, %{"browserHtml" => html}} ->
            Logger.info("Successfully fetched HTML via Zyte (#{byte_size(html)} bytes)")
            {:ok, html}
            
          error ->
            Logger.error("Failed to parse Zyte response: #{inspect(error)}")
            {:error, "Zyte JSON parsing failed"}
        end
        
      {:ok, %{status_code: status, body: body}} ->
        Logger.error("Zyte API error (#{status}): #{body}")
        {:error, "Zyte HTTP #{status}"}
        
      {:error, reason} ->
        Logger.error("Zyte network error: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp fetch_html_direct(url) do
    # Fallback to direct HTTP if Zyte not configured
    headers = [
      {"User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"},
      {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
      {"Accept-Language", "en-US,en;q=0.5"},
      {"Accept-Encoding", "gzip, deflate"},
      {"Connection", "keep-alive"}
    ]
    
    case HTTPoison.get(url, headers, timeout: @timeout, recv_timeout: @timeout) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        Logger.info("Successfully fetched HTML directly (#{byte_size(body)} bytes)")
        {:ok, body}
        
      {:ok, %HTTPoison.Response{status_code: status_code}} ->
        Logger.error("HTTP error #{status_code} when fetching #{url}")
        {:error, "HTTP #{status_code}"}
        
      {:error, reason} ->
        Logger.error("Network error when fetching #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    exception ->
      Logger.error("Exception when fetching #{url}: #{inspect(exception)}")
      {:error, exception}
  end
  
  defp parse_imdb_list_html(html, list_config, page) do
    Logger.info("Parsing IMDb list HTML for #{list_config.name} (page #{page})")
    
    try do
      # Parse with Floki
      document = Floki.parse_document!(html)
      
      # Find all list items with movie data
      # IMDb lists can have different layouts - try multiple selectors
      list_items = find_movie_items(document)
      
      Logger.info("Found #{length(list_items)} potential movie items")
      
      # Calculate base position based on page number
      # Page 1: positions 1-250, Page 2: positions 251-500, etc.
      base_position = (page - 1) * 250
      
      movies = 
        list_items
        |> Enum.with_index(1)
        |> Enum.map(fn {item, index} -> 
          position = base_position + index
          parse_movie_from_list_item(item, position) 
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.imdb_id)  # Remove duplicates
      
      Logger.info("Parsed #{length(movies)} unique movies from #{list_config.name}")
      
      if length(movies) > 0 do
        # Log first few for verification
        movies
        |> Enum.take(3)
        |> Enum.each(fn movie ->
          Logger.info("Sample movie: #{movie.title} (#{movie.year}) - #{movie.imdb_id}")
        end)
        
        {:ok, movies}
      else
        Logger.warning("No movies found with primary parsing, trying alternative methods...")
        alternative_parse(document, list_config)
      end
      
    rescue
      exception ->
        Logger.error("Failed to parse HTML for #{list_config.name}: #{inspect(exception)}")
        {:error, "HTML parsing failed: #{inspect(exception)}"}
    end
  end
  
  defp find_movie_items(document) do
    # Page 1 uses .lister-item, page 2+ uses different structure
    # Try .lister-item first (page 1)
    lister_items = Floki.find(document, ".lister-item")
    
    if length(lister_items) > 0 do
      lister_items
    else
      # For page 2+, we need to find the movie containers differently
      # The structure is different - movies are in cells
      ipc_cells = Floki.find(document, ".ipc-metadata-list-summary-item")
      
      if length(ipc_cells) > 0 do
        ipc_cells
      else
        # Fallback to other selectors
        selectors = [
          ".titleColumn",
          ".cli-item",
          ".list-item",
          ".movie-item"
        ]
        
        selectors
        |> Enum.find_value(fn selector ->
          items = Floki.find(document, selector)
          if length(items) > 0, do: items, else: nil
        end) || []
      end
    end
  end
  
  defp alternative_parse(document, list_config) do
    Logger.info("Trying alternative parsing methods for #{list_config.name}")
    
    # Try alternative selectors for different IMDb list layouts
    selectors = [
      "a[href*='/title/tt']",           # Any link to a title
      ".titleColumn a",                  # Title column links
      ".ipc-title a",                   # New IMDb design
      ".cli-title a",                   # Another common pattern
      ".title a",                       # Generic title link
      "[data-testid*='title'] a"        # Modern React-based IMDb
    ]
    
    movies = 
      selectors
      |> Enum.flat_map(fn selector ->
        Floki.find(document, selector)
        |> Enum.with_index(1)
        |> Enum.map(fn {link, position} -> 
          extract_movie_from_title_link(link, position) 
        end)
        |> Enum.reject(&is_nil/1)
      end)
      |> Enum.uniq_by(& &1.imdb_id)
    
    if length(movies) > 0 do
      Logger.info("Alternative parsing found #{length(movies)} movies for #{list_config.name}")
      {:ok, movies}
    else
      Logger.error("No movies found with any parsing method for #{list_config.name}")
      {:error, "No movies found with any parsing method"}
    end
  end
  
  defp parse_movie_from_list_item(item, position) do
    # Check if it's a .lister-item (page 1 format)
    if Floki.attribute(item, "class") |> Enum.any?(&String.contains?(&1, "lister-item")) do
      parse_lister_item(item, position)
    else
      # Otherwise, it's probably the newer format (page 2+)
      parse_ipc_item(item, position)
    end
  end
  
  defp parse_lister_item(item, position) do
    # Extract title link
    title_link = Floki.find(item, "a[href*='/title/tt']") |> List.first()
    
    if title_link do
      # Extract IMDb ID from href
      href = Floki.attribute(title_link, "href") |> List.first()
      imdb_id = extract_imdb_id(href)
      
      # Extract title text - clean up any numbering
      title = Floki.text(title_link) |> String.trim() |> clean_title()
      
      # Try to extract year from various possible locations
      year = extract_year_from_item(item)
      
      if imdb_id && title != "" do
        %{
          imdb_id: imdb_id,
          title: title,
          year: year,
          position: position
        }
      else
        nil
      end
    else
      nil
    end
  end
  
  defp parse_ipc_item(item, position) do
    # For the newer format, find the title link within the item
    title_link = Floki.find(item, ".ipc-title-link-wrapper a[href*='/title/tt']") |> List.first() ||
                 Floki.find(item, "a[href*='/title/tt']") |> List.first()
    
    if title_link do
      # Extract IMDb ID from href
      href = Floki.attribute(title_link, "href") |> List.first()
      imdb_id = extract_imdb_id(href)
      
      # Extract title text - the newer format might have additional text
      title_text = Floki.find(item, "h3") |> Floki.text() |> String.trim()
      title = if title_text != "", do: clean_title(title_text), else: Floki.text(title_link) |> String.trim() |> clean_title()
      
      # Extract year - in newer format it might be in a span
      year = extract_year_from_ipc_item(item)
      
      if imdb_id && title != "" do
        %{
          imdb_id: imdb_id,
          title: title,
          year: year,
          position: position
        }
      else
        nil
      end
    else
      nil
    end
  end
  
  defp clean_title(title) do
    # Remove leading numbers and dots (e.g., "251. Movie Title" -> "Movie Title")
    title
    |> String.replace(~r/^\d+\.\s*/, "")
    |> String.trim()
  end
  
  defp extract_movie_from_title_link(link, position) do
    href = Floki.attribute(link, "href") |> List.first()
    imdb_id = extract_imdb_id(href)
    title = Floki.text(link) |> String.trim()
    
    if imdb_id && title != "" do
      %{
        imdb_id: imdb_id,
        title: title,
        year: nil,  # Year extraction would need parent context
        position: position
      }
    else
      nil
    end
  end
  
  defp extract_imdb_id(href) when is_binary(href) do
    case Regex.run(~r/tt\d+/, href) do
      [imdb_id] -> imdb_id
      _ -> nil
    end
  end
  defp extract_imdb_id(_), do: nil
  
  defp extract_year_from_item(item) do
    # Try various selectors for year information
    year_selectors = [
      ".secondaryInfo",
      ".lister-item-year",
      ".titleColumn .secondaryInfo",
      "span.year"
    ]
    
    year_text = 
      year_selectors
      |> Enum.find_value(fn selector ->
        case Floki.find(item, selector) do
          [] -> nil
          elements -> Floki.text(elements) |> String.trim()
        end
      end)
    
    if year_text && year_text != "" do
      parse_year(year_text)
    else
      nil
    end
  end
  
  defp extract_year_from_ipc_item(item) do
    # For the newer format, year might be in different places
    year_selectors = [
      ".cli-title-metadata span",
      ".ipc-inline-list__item span",
      "span.sc-479faa3c-8",
      "span"  # Check all spans for year pattern
    ]
    
    year_text = 
      year_selectors
      |> Enum.find_value(fn selector ->
        case Floki.find(item, selector) do
          [] -> nil
          elements -> 
            # Find the element that contains a year pattern
            Enum.find_value(elements, fn element ->
              text = Floki.text(element) |> String.trim()
              if String.match?(text, ~r/\d{4}/), do: text, else: nil
            end)
        end
      end)
    
    if year_text && year_text != "" do
      parse_year(year_text)
    else
      nil
    end
  end
  
  defp parse_year(text) do
    case Regex.run(~r/\((\d{4})\)/, text) do
      [_, year_str] -> 
        case Integer.parse(year_str) do
          {year, _} -> year
          :error -> nil
        end
      _ -> 
        # Try without parentheses
        case Regex.run(~r/\b(\d{4})\b/, text) do
          [_, year_str] ->
            case Integer.parse(year_str) do
              {year, _} -> year
              :error -> nil
            end
          _ -> nil
        end
    end
  end
  
  defp process_canonical_movies(movie_data, list_config) do
    source_key = list_config.source_key
    Logger.info("Processing #{length(movie_data)} canonical movies for #{source_key}")
    
    # Build base metadata from list config
    metadata_base = %{
      "scraped_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source_url" => "https://www.imdb.com/list/#{list_config.list_id}/",
      "source_name" => list_config.name,
      "list_id" => list_config.list_id
    }
    |> Map.merge(list_config.metadata || %{})  # Add any custom metadata
    
    results = 
      movie_data
      |> Enum.map(fn movie ->
        process_canonical_movie(movie, source_key, metadata_base)
      end)
    
    # Summarize results
    created = Enum.count(results, & &1.action == :created)
    updated = Enum.count(results, & &1.action == :updated)  
    queued = Enum.count(results, & &1.action == :queued)
    skipped = Enum.count(results, & &1.action == :skipped)
    errors = Enum.count(results, & &1.action == :error)
    
    Logger.info("Processing complete for #{list_config.name}: #{created} created, #{updated} updated, #{queued} queued, #{skipped} skipped, #{errors} errors")
    
    {:ok, %{
      list_config: list_config,
      results: results,
      summary: %{
        created: created,
        updated: updated,
        queued: queued,
        skipped: skipped,
        errors: errors,
        total: length(results)
      }
    }}
  end
  
  defp process_canonical_movie(movie_data, source_key, metadata_base) do
    # Add movie-specific metadata
    metadata = Map.merge(metadata_base, %{
      "list_position" => movie_data.position,
      "scraped_title" => movie_data.title,
      "scraped_year" => movie_data.year
    })
    
    case Repo.get_by(Movies.Movie, imdb_id: movie_data.imdb_id) do
      nil ->
        # Movie doesn't exist, queue for import
        queue_canonical_movie_import(movie_data, source_key, metadata)
        
      existing_movie ->
        # Movie exists, update canonical sources
        update_canonical_sources(existing_movie, source_key, metadata)
    end
  end
  
  defp queue_canonical_movie_import(movie_data, source_key, metadata) do
    Logger.info("Queuing import for #{movie_data.title} (#{movie_data.imdb_id})")
    
    job_args = %{
      "imdb_id" => movie_data.imdb_id,
      "source" => "canonical_import",
      "canonical_source" => %{
        "source_key" => source_key,
        "metadata" => metadata
      }
    }
    
    case TMDbDetailsWorker.new(job_args) |> Oban.insert() do
      {:ok, _job} ->
        Logger.info("Successfully queued import for #{movie_data.title}")
        %{
          action: :queued,
          imdb_id: movie_data.imdb_id,
          title: movie_data.title,
          source_key: source_key
        }
        
      {:error, reason} ->
        Logger.error("Failed to queue import for #{movie_data.title}: #{inspect(reason)}")
        %{
          action: :error,
          imdb_id: movie_data.imdb_id,
          title: movie_data.title,
          reason: reason
        }
    end
  end
  
  defp update_canonical_sources(movie, source_key, metadata) do
    Logger.info("Marking #{movie.title} as canonical in #{source_key}")
    
    current_sources = movie.canonical_sources || %{}
    
    updated_sources = Map.put(current_sources, source_key, Map.merge(%{
      "included" => true
    }, metadata))
    
    case movie
         |> Movies.Movie.changeset(%{canonical_sources: updated_sources})
         |> Repo.update() do
      {:ok, _updated_movie} ->
        Logger.info("Successfully marked #{movie.title} as canonical")
        %{
          action: :updated,
          movie_id: movie.id,
          title: movie.title,
          source_key: source_key
        }
        
      {:error, changeset} ->
        Logger.error("Failed to update canonical sources for #{movie.title}: #{inspect(changeset.errors)}")
        %{
          action: :error,
          movie_id: movie.id,
          title: movie.title,
          reason: changeset.errors
        }
    end
  end
  
  @doc """
  Get statistics about canonical movies in the database.
  You can provide a list of source keys to check, or it will check common ones.
  
  ## Examples
      # Check specific sources
      canonical_stats(["1001_movies", "sight_sound", "criterion"])
      
      # Check all sources (queries database for all existing source keys)
      canonical_stats()
  """
  def canonical_stats(source_keys \\ nil) do
    # If no source keys provided, discover them from the database
    sources_to_check = source_keys || discover_canonical_sources()
    
    # Count movies by canonical source
    source_counts = 
      sources_to_check
      |> Enum.map(fn source_key ->
        count = Movies.count_canonical_movies(source_key)
        {source_key, count}
      end)
      |> Enum.into(%{})
    
    # Count movies with any canonical source
    any_canonical = Movies.count_any_canonical_movies()
    
    %{
      by_source: source_counts,
      any_canonical: any_canonical,
      checked_sources: sources_to_check,
      total_sources_found: length(sources_to_check)
    }
  end
  
  @doc """
  Discover all canonical source keys currently in the database.
  """
  def discover_canonical_sources do
    query = """
    SELECT DISTINCT jsonb_object_keys(canonical_sources) as source_key
    FROM movies
    WHERE canonical_sources IS NOT NULL
      AND jsonb_typeof(canonical_sources) = 'object'
    """
    
    case Repo.query(query) do
      {:ok, %{rows: rows}} -> 
        # Extract the first (and only) element from each row
        discovered_keys = Enum.map(rows, &List.first/1)
        
        # If no keys found, return default list
        if length(discovered_keys) > 0 do
          discovered_keys
        else
          # Fallback to common expected sources
          ["1001_movies", "sight_sound", "criterion", "afi", "bfi"]
        end
        
      {:error, reason} ->
        Logger.warning("Failed to discover canonical sources: #{inspect(reason)}")
        # Fallback to common expected sources
        ["1001_movies", "sight_sound", "criterion", "afi", "bfi"]
    end
  end
  
  @doc """
  Helper to create a list configuration for batch scraping.
  
  ## Example
      config = create_list_config("ls024863935", "1001_movies", "1001 Movies You Must See Before You Die", %{"edition" => "2024"})
  """
  def create_list_config(list_id, source_key, name, metadata \\ %{}) do
    %{
      list_id: list_id,
      source_key: source_key,
      name: name,
      metadata: metadata
    }
  end
end