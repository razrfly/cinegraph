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
    
    # First, get the expected count from the first page
    expected_count = get_expected_movie_count(list_id)
    Logger.info("Expected movie count: #{expected_count || "unknown"}")
    
    # Scrape all pages
    all_movies = scrape_all_pages(list_id, list_config)
    
    Logger.info("Total movies found: #{length(all_movies)}")
    
    if length(all_movies) > 0 do
      {:ok, processed_results} = process_canonical_movies(all_movies, list_config)
      
      # Add expected count to the results
      results_with_expected = Map.put(processed_results, :expected_count, expected_count)
      
      Logger.info("Successfully scraped #{list_name}: #{length(all_movies)} movies total")
      {:ok, results_with_expected}
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
  Database lists take precedence over hardcoded ones.
  
  ## Examples
      scrape_list_by_key("1001_movies")
      scrape_list_by_key("criterion")
  """
  def scrape_list_by_key(list_key) when is_binary(list_key) do
    case Cinegraph.Movies.MovieLists.get_config(list_key) do
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
  def fetch_single_page(list_id, page \\ 1, tracks_awards \\ false) do
    url = build_imdb_list_url(list_id, page)
    
    Logger.info("Fetching page #{page} from IMDb list #{list_id} (tracks_awards: #{tracks_awards})")
    
    with {:ok, html} <- fetch_html(url),
         {:ok, movies} <- parse_single_page(html, page, tracks_awards) do
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
    # Target the specific element that contains the total count
    # Based on HTML: <ul data-testid="list-page-mc-total-items"><li>297 titles</li></ul>
    count_selectors = [
      "[data-testid='list-page-mc-total-items'] .ipc-inline-list__item",  # Most specific - targets the exact location
      ".ipc-inline-list__item",  # Fallback - broader search
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
          # For each element, check if it contains title count text
          elements
          |> Enum.find_value(fn element ->
            text = Floki.text(element) |> String.trim()
            # Look for patterns like "297 titles" or "1,260 titles"
            if String.match?(text, ~r/^\d+,?\d*\s+titles?$/i), do: text, else: nil
          end)
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
  
  @doc """
  Get the expected movie count for a list by checking the first page.
  Returns the count or nil if unable to determine.
  """
  def get_expected_movie_count(list_id) do
    url = build_imdb_list_url(list_id, 1)
    
    case fetch_html(url) do
      {:ok, html} ->
        document = Floki.parse_document!(html)
        count_text = find_total_count_text(document)
        
        if count_text do
          # Parse patterns looking for title counts
          # First try to find "X titles" pattern directly
          case Regex.run(~r/(\d+,?\d*)\s+titles?/i, count_text) do
            [_, total] when is_binary(total) ->
              total
              |> String.replace(",", "")
              |> String.trim()
              |> String.to_integer()
            _ ->
              # Try "of X" pattern
              case Regex.run(~r/of\s+([\d,]+)/i, count_text) do
                [_, total] when is_binary(total) ->
                  total
                  |> String.replace(",", "")
                  |> String.trim()
                  |> String.to_integer()
                _ ->
                  nil
              end
          end
        else
          nil
        end
        
      {:error, _reason} ->
        nil
    end
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
  defp parse_single_page(html, page, tracks_awards) do
    # Reuse existing parsing logic
    list_config = %{
      name: "Single page",
      metadata: %{
        "tracks_awards" => tracks_awards
      }
    }
    Logger.info("🔧 parse_single_page: Creating config with tracks_awards = #{tracks_awards}")
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
    
    # Check if this list tracks awards
    tracks_awards = get_in(list_config.metadata, ["tracks_awards"]) == true
    Logger.info("=== parse_imdb_list_html: tracks_awards = #{tracks_awards} ===")
    
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
          parse_movie_from_list_item(item, position, tracks_awards) 
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
  
  defp parse_movie_from_list_item(item, position, tracks_awards) do
    # Check if it's a .lister-item (page 1 format)
    item_classes = Floki.attribute(item, "class")
    is_lister = Enum.any?(item_classes, &String.contains?(&1, "lister-item"))
    
    Logger.info("🎭 === parse_movie_from_list_item ===")
    Logger.info("   Position: #{position}")
    Logger.info("   tracks_awards: #{tracks_awards}")
    Logger.info("   Item classes: #{inspect(item_classes)}")
    Logger.info("   Format detected: #{if is_lister, do: "LISTER (old)", else: "IPC (new)"}")
    
    if is_lister do
      parse_lister_item(item, position, tracks_awards)
    else
      # Otherwise, it's probably the newer format (page 2+)
      parse_ipc_item(item, position, tracks_awards)
    end
  end
  
  defp parse_lister_item(item, position, tracks_awards) do
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
        # Basic data that we always extract
        base_data = %{
          imdb_id: imdb_id,
          title: title,
          year: year,
          position: position
        }
        
        # Extract enhanced data only if this list tracks awards
        if tracks_awards do
          Logger.info("   🏆 Extracting enhanced data for: #{title}")
          enhanced_data = extract_enhanced_lister_data(item)
          result = Map.merge(base_data, enhanced_data)
          Logger.info("   Enhanced result has extracted_awards: #{Map.has_key?(result, :extracted_awards)}")
          result
        else
          Logger.info("   ⏭️  Skipping enhanced data for: #{title} (tracks_awards = false)")
          base_data
        end
      else
        nil
      end
    else
      nil
    end
  end
  
  defp parse_ipc_item(item, position, tracks_awards) do
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
        # Basic data
        base_data = %{
          imdb_id: imdb_id,
          title: title,
          year: year,
          position: position
        }
        
        # Extract enhanced data only if this list tracks awards
        if tracks_awards do
          Logger.info("   🏆 IPC: Extracting enhanced data for: #{title}")
          enhanced_data = extract_enhanced_ipc_data(item)
          result = Map.merge(base_data, enhanced_data)
          Logger.info("   IPC: Enhanced result has extracted_awards: #{Map.has_key?(result, :extracted_awards)}")
          result
        else
          Logger.info("   ⏭️  IPC: Skipping enhanced data for: #{title} (tracks_awards = false)")
          base_data
        end
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
  
  defp extract_enhanced_lister_data(item) do
    Logger.info("🔍 === extract_enhanced_lister_data START ===")
    
    # Extract all text content from the item
    full_text = Floki.text(item)
    Logger.info("📝 Full text length: #{String.length(full_text)}")
    
    # Extract description/plot text
    description = extract_description_text(item)
    Logger.info("📄 Description extracted: #{String.slice(description || "", 0, 50)}...")
    
    # CRITICAL FIX: Look for award text in the specific HTML element FIRST
    Logger.info("🎯 Looking for award element with data-testid='title-list-item-description'")
    
    # Try multiple selectors to find the award element
    award_element_selectors = [
      "[data-testid='title-list-item-description'] .ipc-html-content-inner-div",
      "[data-testid='title-list-item-description']",
      ".ipc-html-content-inner-div",
      ".ipc-bq .ipc-html-content-inner-div"
    ]
    
    award_text = Enum.find_value(award_element_selectors, fn selector ->
      Logger.info("🔎 Trying selector: #{selector}")
      elements = Floki.find(item, selector)
      Logger.info("   Found #{length(elements)} elements")
      
      if length(elements) > 0 do
        text = Floki.text(List.first(elements)) |> String.trim()
        if text != "" do
          Logger.info("✅ Award text found in element: '#{text}'")
          text
        else
          nil
        end
      else
        nil
      end
    end)
    
    # Fallback to pattern search if no element found
    if award_text == nil do
      Logger.info("⚠️  No award element found, falling back to pattern search")
      award_text = extract_award_text(full_text)
      if award_text && award_text != "" do
        Logger.info("📍 Award text found via pattern: '#{award_text}'")
      else
        Logger.info("❌ No award text found via patterns")
      end
    end
    
    # Extract metadata (rating, runtime, genre, etc.)
    metadata = extract_movie_metadata_lister(item)
    Logger.info("📊 Metadata extracted: #{map_size(metadata)} fields")
    
    # Extract director and stars
    credits = extract_credits_lister(item)
    Logger.info("🎬 Credits extracted: #{map_size(credits)} fields")
    
    # Parse award text into structured data if awards exist
    extracted_awards = if award_text && award_text != "" do
      Logger.info("🏆 Parsing award text: '#{award_text}'")
      awards = parse_award_text_to_structured(award_text)
      Logger.info("🏅 Parsed #{length(awards)} awards")
      awards
    else
      Logger.info("🚫 No award text to parse, returning empty array")
      []
    end
    
    result = %{
      raw_description: description,
      award_text: award_text,
      extracted_awards: extracted_awards,
      full_text: full_text,
      extracted_metadata: Map.merge(metadata, credits)
    }
    
    Logger.info("✨ extract_enhanced_lister_data COMPLETE")
    Logger.info("   - award_text: #{if award_text, do: "'#{award_text}'", else: "nil"}")
    Logger.info("   - extracted_awards: #{length(extracted_awards)} items")
    
    result
  end
  
  defp extract_enhanced_ipc_data(item) do
    Logger.info("🔍 === extract_enhanced_ipc_data START ===")
    
    # Extract all text content from the item
    full_text = Floki.text(item)
    Logger.info("📝 Full text length: #{String.length(full_text)}")
    
    # Extract description/plot text
    description = extract_description_text_ipc(item)
    Logger.info("📄 Description extracted: #{String.slice(description || "", 0, 50)}...")
    
    # CRITICAL FIX: Look for award text in the specific HTML element FIRST
    Logger.info("🎯 Looking for award element in IPC format")
    
    # Try multiple selectors for IPC format
    award_element_selectors = [
      "[data-testid='title-list-item-description'] .ipc-html-content-inner-div",
      "[data-testid='title-list-item-description']",
      ".ipc-html-content-inner-div",
      ".ipc-bq .ipc-html-content-inner-div",
      ".ipc-html-content--base .ipc-html-content-inner-div"
    ]
    
    award_text = Enum.find_value(award_element_selectors, fn selector ->
      Logger.info("🔎 Trying IPC selector: #{selector}")
      elements = Floki.find(item, selector)
      Logger.info("   Found #{length(elements)} elements")
      
      if length(elements) > 0 do
        text = Floki.text(List.first(elements)) |> String.trim()
        if text != "" do
          Logger.info("✅ Award text found in IPC element: '#{text}'")
          text
        else
          nil
        end
      else
        nil
      end
    end)
    
    # Fallback to pattern search if no element found
    if award_text == nil do
      Logger.info("⚠️  No award element found in IPC format, falling back to pattern search")
      award_text = extract_award_text(full_text)
      if award_text && award_text != "" do
        Logger.info("📍 Award text found via pattern: '#{award_text}'")
      else
        Logger.info("❌ No award text found via patterns")
      end
    end
    
    # Extract metadata for newer format
    metadata = extract_movie_metadata_ipc(item)
    Logger.info("📊 Metadata extracted: #{map_size(metadata)} fields")
    
    # Extract credits info
    credits = extract_credits_ipc(item)
    Logger.info("🎬 Credits extracted: #{map_size(credits)} fields")
    
    # Parse award text into structured data if awards exist
    extracted_awards = if award_text && award_text != "" do
      Logger.info("🏆 Parsing award text: '#{award_text}'")
      awards = parse_award_text_to_structured(award_text)
      Logger.info("🏅 Parsed #{length(awards)} awards")
      awards
    else
      Logger.info("🚫 No award text to parse, returning empty array")
      []
    end
    
    result = %{
      raw_description: description,
      award_text: award_text,
      extracted_awards: extracted_awards,
      full_text: full_text,
      extracted_metadata: Map.merge(metadata, credits)
    }
    
    Logger.info("✨ extract_enhanced_ipc_data COMPLETE")
    Logger.info("   - award_text: #{if award_text, do: "'#{award_text}'", else: "nil"}")
    Logger.info("   - extracted_awards: #{length(extracted_awards)} items")
    
    result
  end
  
  defp extract_description_text(item) do
    # Look for description/plot text in lister format, avoiding metadata
    description_selectors = [
      ".text-muted:not(.text-small)",
      ".plot",
      ".overview",
      "p"
    ]
    
    description_selectors
    |> Enum.find_value(fn selector ->
      case Floki.find(item, selector) do
        [] -> nil
        elements ->
          text = elements
          |> Enum.map(&Floki.text/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.find(fn text ->
            # Only include text that looks like a plot description
            String.length(text) > 50 &&
            !String.match?(text, ~r/^\d+\s*min/) &&
            !String.match?(text, ~r/^(G|PG|PG-13|R|NC-17)/) &&
            !String.match?(text, ~r/Director:|Stars:/) &&
            !String.match?(text, ~r/^\d+\.\d+$/)
          end)
          
          if text && text != "", do: text, else: nil
      end
    end) || ""
  end
  
  defp extract_description_text_ipc(item) do
    # Look for description in newer IPC format
    description_selectors = [
      ".ipc-html-content-inner-div",
      "[data-testid='plot']",
      ".cli-plot",
      ".dli-plot-container"
    ]
    
    description_selectors
    |> Enum.find_value(fn selector ->
      case Floki.find(item, selector) do
        [] -> nil
        elements ->
          text = Floki.text(elements) |> String.trim()
          if text != "", do: text, else: nil
      end
    end) || ""
  end
  
  defp extract_award_text(full_text) do
    # Look for award-specific elements first, then fall back to text patterns
    # This approach is more precise than just splitting by lines
    
    # More precise patterns for award text - match the exact award phrases
    award_patterns = [
      ~r/\[20\d{2}\]:\s*Palme d'Or[^.]*\./i,
      ~r/\[20\d{2}\]:\s*Grand Prix[^.]*\./i,
      ~r/\[20\d{2}\]:\s*Jury Prize[^.]*\./i,
      ~r/\[20\d{2}\]:\s*Caméra d'Or[^.]*\./i,
      ~r/\[20\d{2}\]:\s*Camera d'Or[^.]*\./i,
      ~r/\[20\d{2}\]:\s*Best Director[^.]*\./i,
      ~r/\[20\d{2}\]:\s*Best Actor[^.]*\./i,
      ~r/\[20\d{2}\]:\s*Best Actress[^.]*\./i,
      ~r/Palme d'Or winner[^.]*\./i,
      ~r/Grand Prix winner[^.]*\./i,
      ~r/Jury Prize winner[^.]*\./i,
      ~r/Won.*?Palme d'Or[^.]*\./i,
      ~r/Won.*?Grand Prix[^.]*\./i
    ]
    
    # Extract all matching award phrases
    award_matches = award_patterns
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, full_text, capture: :all)
      |> Enum.map(fn [match] -> String.trim(match) end)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    
    if length(award_matches) > 0 do
      Enum.join(award_matches, " | ")
    else
      # Fallback: look for simple award mentions without full sentences
      simple_patterns = [
        ~r/Palme d'Or/i,
        ~r/Grand Prix/i,
        ~r/Jury Prize/i,
        ~r/Caméra d'Or/i,
        ~r/Camera d'Or/i
      ]
      
      lines = String.split(full_text, ~r/[\n\r\t]+/)
      award_lines = lines
      |> Enum.filter(fn line ->
        trimmed = String.trim(line)
        String.length(trimmed) < 100 &&  # Keep lines short
        !String.match?(trimmed, ~r/^\d+\.\d+$/) &&  # Not ratings
        !String.match?(trimmed, ~r/^\d+h?\s*\d*m?$/) &&  # Not runtime
        !String.match?(trimmed, ~r/^[A-Z]+$/) &&  # Not ratings like R, PG
        !String.match?(trimmed, ~r/Director:|Stars:/) &&  # Not credits
        Enum.any?(simple_patterns, &String.match?(trimmed, &1))
      end)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      
      if length(award_lines) > 0 do
        Enum.join(award_lines, " | ")
      else
        ""
      end
    end
  end
  
  # Parse raw award text into structured award data for database storage.
  defp parse_award_text_to_structured(award_text) when is_binary(award_text) and award_text != "" do
    Logger.info("🎨 === parse_award_text_to_structured START ===")
    Logger.info("   Input: '#{award_text}'")
    
    # Split by separator if multiple awards
    award_parts = String.split(award_text, " | ")
    Logger.info("   Split into #{length(award_parts)} parts")
    
    awards = award_parts
    |> Enum.map(&parse_single_award/1)
    |> Enum.reject(&is_nil/1)
    
    Logger.info("   Parsed #{length(awards)} valid awards")
    Logger.info("🎨 === parse_award_text_to_structured END ===")
    
    awards
  end
  defp parse_award_text_to_structured(_), do: []
  
  defp parse_single_award(award_text) do
    trimmed = String.trim(award_text)
    Logger.info("🏆 Parsing single award: '#{trimmed}'")
    
    # Pattern 1: [YYYY]: Award Name (Category).
    case Regex.run(~r/\[(\d{4})\]:\s*([^(]+?)(?:\s*\(([^)]+)\))?\s*\.?$/i, trimmed) do
      [_, year, award_name, category] ->
        # Clean up award name by removing "winner" suffix
        clean_award_name = String.trim(award_name) |> String.replace(~r/\s+winner\s*$/i, "")
        result = %{
          award_name: clean_award_name,
          award_category: if(category && category != "", do: String.trim(category), else: nil),
          award_year: year,
          raw_text: trimmed
        }
        Logger.info("   ✅ Pattern 1 match: #{inspect(result)}")
        result
        
      [_, year, award_name] ->
        # Clean up award name by removing "winner" suffix
        clean_award_name = String.trim(award_name) |> String.replace(~r/\s+winner\s*$/i, "")
        result = %{
          award_name: clean_award_name,
          award_category: nil,
          award_year: year,
          raw_text: trimmed
        }
        Logger.info("   ✅ Pattern 1 match (no category): #{inspect(result)}")
        result
        
      _ ->
        Logger.info("   ❌ Pattern 1 no match, trying pattern 2")
        # Pattern 2: Award Name winner (Category).
        case Regex.run(~r/^([^(]+?)\s+winner(?:\s*\(([^)]+)\))?\s*\.?$/i, trimmed) do
          [_, award_name, category] ->
            result = %{
              award_name: String.trim(award_name),
              award_category: if(category && category != "", do: String.trim(category), else: nil),
              award_year: nil,
              raw_text: trimmed
            }
            Logger.info("   ✅ Pattern 2 match: #{inspect(result)}")
            result
            
          [_, award_name] ->
            result = %{
              award_name: String.trim(award_name),
              award_category: nil,
              award_year: nil,
              raw_text: trimmed
            }
            Logger.info("   ✅ Pattern 2 match (no category): #{inspect(result)}")
            result
            
          _ ->
            Logger.info("   ❌ Pattern 2 no match, trying pattern 3")
            # Pattern 3: Simple award name
            if Regex.match?(~r/^(Palme d'Or|Grand Prix|Jury Prize|Caméra d'Or|Camera d'Or|Best Director|Best Actor|Best Actress)$/i, trimmed) do
              result = %{
                award_name: String.trim(trimmed),
                award_category: nil,
                award_year: nil,
                raw_text: trimmed
              }
              Logger.info("   ✅ Pattern 3 match: #{inspect(result)}")
              result
            else
              Logger.info("   ❌ Pattern 3 no match, trying pattern 4")
              # Pattern 4: Won [something] format
              case Regex.run(~r/Won\s+(.+?)(?:\s*\(([^)]+)\))?\s*\.?$/i, trimmed) do
                [_, award_name, category] ->
                  result = %{
                    award_name: String.trim(award_name),
                    award_category: if(category && category != "", do: String.trim(category), else: nil),
                    award_year: nil,
                    raw_text: trimmed
                  }
                  Logger.info("   ✅ Pattern 4 match: #{inspect(result)}")
                  result
                  
                [_, award_name] ->
                  result = %{
                    award_name: String.trim(award_name),
                    award_category: nil,
                    award_year: nil,
                    raw_text: trimmed
                  }
                  Logger.info("   ✅ Pattern 4 match (no category): #{inspect(result)}")
                  result
                  
                _ ->
                  Logger.info("   ❌ Pattern 4 no match, trying pattern 5")
                  # Pattern 5: Festival name format (e.g., "2nd Berlin International Film Festival")
                  if Regex.match?(~r/(Festival|Awards?|Prize|Competition)/i, trimmed) do
                    # Extract year if present
                    year = case Regex.run(~r/\b(19\d{2}|20\d{2})\b/, trimmed) do
                      [_, year_str] -> year_str
                      _ -> nil
                    end
                    
                    result = %{
                      award_name: trimmed,
                      award_category: nil,
                      award_year: year,
                      raw_text: trimmed
                    }
                    Logger.info("   ✅ Pattern 5 (festival) match: #{inspect(result)}")
                    result
                  else
                    # Fallback: store as-is for manual review
                    result = %{
                      award_name: trimmed,
                      award_category: nil,
                      award_year: nil,
                      raw_text: trimmed
                    }
                    Logger.info("   ⚠️  Fallback - storing as-is: #{inspect(result)}")
                    result
                  end
              end
            end
        end
    end
  end
  
  defp extract_movie_metadata_lister(item) do
    metadata = %{}
    
    # Extract runtime
    runtime = case Floki.find(item, ".runtime") do
      [] -> nil
      elements -> Floki.text(elements) |> String.trim()
    end
    
    # Extract certificate/rating
    certificate = case Floki.find(item, ".certificate") do
      [] -> nil
      elements -> Floki.text(elements) |> String.trim()
    end
    
    # Extract genre
    genre = case Floki.find(item, ".genre") do
      [] -> nil
      elements -> Floki.text(elements) |> String.trim()
    end
    
    # Extract metascore
    metascore = case Floki.find(item, ".metascore") do
      [] -> nil
      elements -> Floki.text(elements) |> String.trim()
    end
    
    # Extract rating info
    rating_bar = Floki.find(item, ".ratings-bar")
    rating = case Floki.find(rating_bar, "strong") do
      [] -> nil
      elements -> Floki.text(elements) |> String.trim()
    end
    
    # Extract vote count
    votes = case Floki.find(item, ".text-muted:last-child") do
      [] -> nil
      elements -> 
        text = Floki.text(elements)
        case Regex.run(~r/\(([\d,]+)\)/, text) do
          [_, count] -> count
          _ -> nil
        end
    end
    
    metadata
    |> Map.put_new("runtime", runtime)
    |> Map.put_new("certificate", certificate)
    |> Map.put_new("genre", genre)
    |> Map.put_new("metascore", metascore)
    |> Map.put_new("imdb_rating", rating)
    |> Map.put_new("vote_count", votes)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end
  
  defp extract_movie_metadata_ipc(item) do
    metadata = %{}
    
    # Extract metadata from inline list items
    metadata_items = Floki.find(item, ".ipc-inline-list__item")
    
    # Process each metadata item
    metadata_values = metadata_items
    |> Enum.map(&Floki.text/1)
    |> Enum.map(&String.trim/1)
    
    # Try to identify runtime, rating, etc from the values
    runtime = Enum.find(metadata_values, &String.match?(&1, ~r/\d+h\s*\d*m?|\d+m/))
    rating = Enum.find(metadata_values, &String.match?(&1, ~r/^(G|PG|PG-13|R|NC-17|TV-)/))
    
    # Extract IMDb rating
    imdb_rating = case Floki.find(item, "[data-testid='ratingGroup'] span") do
      [] -> nil
      elements -> 
        elements
        |> Enum.map(&Floki.text/1)
        |> Enum.find(&String.match?(&1, ~r/^\d+\.\d+$/))
    end
    
    metadata
    |> Map.put_new("runtime", runtime)
    |> Map.put_new("certificate", rating)
    |> Map.put_new("imdb_rating", imdb_rating)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end
  
  defp extract_credits_lister(item) do
    credits = %{}
    
    # Look for director and stars
    credits_p = Floki.find(item, "p.text-muted")
    
    credits_text = credits_p
    |> Enum.map(&Floki.text/1)
    |> Enum.join(" ")
    
    # Extract director
    director = case Regex.run(~r/Director?s?:\s*([^|]+)/, credits_text) do
      [_, dir] -> String.trim(dir)
      _ -> nil
    end
    
    # Extract stars
    stars = case Regex.run(~r/Stars?:\s*(.+)/, credits_text) do
      [_, stars_text] -> String.trim(stars_text)
      _ -> nil
    end
    
    credits
    |> Map.put_new("director", director)
    |> Map.put_new("stars", stars)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end
  
  defp extract_credits_ipc(_item) do
    # In IPC format, credits might be in different structure
    # This is a placeholder - would need to inspect actual HTML
    %{}
  end
  
  defp process_canonical_movies(movie_data, list_config) do
    source_key = list_config.source_key
    Logger.info("Processing #{length(movie_data)} canonical movies for #{source_key}")
    
    # Dynamic award discovery - extract all awards found across all movies
    discovered_awards = if get_in(list_config.metadata, ["tracks_awards"]) == true do
      discover_awards_from_movies(movie_data, list_config)
    else
      %{}
    end
    
    # Build base metadata from list config
    metadata_base = %{
      "scraped_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source_url" => "https://www.imdb.com/list/#{list_config.list_id}/",
      "source_name" => list_config.name,
      "list_id" => list_config.list_id
    }
    |> Map.merge(list_config.metadata || %{})  # Add any custom metadata
    
    # Add discovered awards to base metadata
    metadata_base = if map_size(discovered_awards) > 0 do
      Map.merge(metadata_base, %{
        "festival_info" => %{
          "festival_name" => extract_festival_name(list_config.name),
          "discovered_awards" => Map.keys(discovered_awards),
          "award_statistics" => discovered_awards,
          "discovery_completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      })
    else
      metadata_base
    end
    
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
    
    if map_size(discovered_awards) > 0 do
      Logger.info("Award discovery complete: #{map_size(discovered_awards)} unique awards found")
      Enum.each(discovered_awards, fn {award, stats} ->
        Logger.info("  - #{award}: #{stats.count} movies, years #{inspect(stats.years)}")
      end)
    end
    
    {:ok, %{
      list_config: list_config,
      results: results,
      discovered_awards: discovered_awards,
      summary: %{
        created: created,
        updated: updated,
        queued: queued,
        skipped: skipped,
        errors: errors,
        total: length(results),
        awards_discovered: map_size(discovered_awards)
      }
    }}
  end
  
  # Dynamically discover awards from movie data across the entire list.
  # This replaces the need for manual award_types configuration.
  defp discover_awards_from_movies(movie_data, list_config) do
    Logger.info("Starting dynamic award discovery for #{list_config.name}")
    
    # Extract all awards from movies that have award data
    all_awards = movie_data
    |> Enum.filter(fn movie -> Map.has_key?(movie, :extracted_awards) && movie.extracted_awards != [] end)
    |> Enum.flat_map(fn movie -> movie.extracted_awards end)
    
    # Build statistics for each discovered award
    award_stats = all_awards
    |> Enum.reduce(%{}, fn award, acc ->
      award_name = award.award_name
      award_year = award.award_year
      
      existing = Map.get(acc, award_name, %{count: 0, years: [], categories: []})
      
      updated_years = if award_year && award_year not in existing.years do
        [award_year | existing.years]
      else
        existing.years
      end
      
      updated_categories = if award.award_category && award.award_category not in existing.categories do
        [award.award_category | existing.categories]
      else
        existing.categories
      end
      
      Map.put(acc, award_name, %{
        count: existing.count + 1,
        years: updated_years |> Enum.sort(:desc),
        categories: updated_categories |> Enum.sort(),
        confidence: calculate_award_confidence(award_name, existing.count + 1)
      })
    end)
    
    Logger.info("Discovered #{map_size(award_stats)} unique awards from movie data")
    award_stats
  end
  
  defp extract_festival_name(list_name) do
    cond do
      String.contains?(list_name, "Cannes") -> "Cannes Film Festival"
      String.contains?(list_name, "Venice") -> "Venice International Film Festival"
      String.contains?(list_name, "Berlin") -> "Berlin International Film Festival"
      String.contains?(list_name, "Sundance") -> "Sundance Film Festival"
      String.contains?(list_name, "Oscar") -> "Academy Awards"
      true -> list_name
    end
  end
  
  defp calculate_award_confidence(award_name, count) do
    # Higher confidence for well-known awards and higher occurrence counts
    base_confidence = cond do
      award_name in ["Palme d'Or", "Grand Prix", "Golden Lion", "Golden Bear"] -> 0.95
      award_name =~ ~r/(Best|Prix|Prize|Award)/i -> 0.85
      count >= 5 -> 0.90
      count >= 2 -> 0.80
      true -> 0.70
    end
    
    # Boost confidence based on frequency
    frequency_boost = min(count * 0.02, 0.1)
    min(base_confidence + frequency_boost, 1.0)
  end
  
  # Helper function to conditionally add non-nil, non-empty values to a map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  # Special case: always include extracted_awards even if empty
  defp maybe_put(map, "extracted_awards", []), do: Map.put(map, "extracted_awards", [])
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  
  defp process_canonical_movie(movie_data, source_key, metadata_base) do
    Logger.info("📦 === process_canonical_movie START ===")
    Logger.info("   Movie: #{movie_data.title} (#{movie_data.imdb_id})")
    Logger.info("   Source key: #{source_key}")
    
    # Add movie-specific metadata
    base_movie_metadata = %{
      "list_position" => movie_data.position,
      "scraped_title" => movie_data.title,
      "scraped_year" => movie_data.year
    }
    
    # Log what enhanced data we have
    Logger.info("   Enhanced data available:")
    Logger.info("     - raw_description: #{if Map.get(movie_data, :raw_description), do: "YES", else: "NO"}")
    Logger.info("     - award_text: #{if Map.get(movie_data, :award_text), do: "YES - '#{Map.get(movie_data, :award_text)}'", else: "NO"}")
    Logger.info("     - extracted_awards: #{length(Map.get(movie_data, :extracted_awards, []))} items")
    
    # Include all enhanced data that exists, not just when raw_description is present
    enhanced_metadata = %{}
      |> maybe_put("raw_description", Map.get(movie_data, :raw_description))
      |> maybe_put("award_text", Map.get(movie_data, :award_text))
      |> maybe_put("extracted_awards", Map.get(movie_data, :extracted_awards, []))
      |> maybe_put("full_text", Map.get(movie_data, :full_text))
      |> maybe_put("extracted_metadata", Map.get(movie_data, :extracted_metadata, %{}))
    
    Logger.info("   Enhanced metadata keys: #{inspect(Map.keys(enhanced_metadata))}")
    
    metadata = metadata_base
      |> Map.merge(base_movie_metadata)
      |> Map.merge(enhanced_metadata)
    
    Logger.info("   Final metadata has extracted_awards: #{Map.has_key?(metadata, "extracted_awards")}")
    
    case Repo.get_by(Movies.Movie, imdb_id: movie_data.imdb_id) do
      nil ->
        # Movie doesn't exist, queue for import
        Logger.info("   🆕 Movie not found, queuing for import")
        queue_canonical_movie_import(movie_data, source_key, metadata)
        
      existing_movie ->
        # Movie exists, update canonical sources
        Logger.info("   ♻️  Movie exists, updating canonical sources")
        update_canonical_sources(existing_movie, source_key, metadata)
    end
    
    Logger.info("📦 === process_canonical_movie END ===")
  end
  
  defp queue_canonical_movie_import(movie_data, source_key, metadata) do
    Logger.info("🚀 === queue_canonical_movie_import START ===")
    Logger.info("   Movie: #{movie_data.title} (#{movie_data.imdb_id})")
    Logger.info("   Source key: #{source_key}")
    Logger.info("   Metadata has extracted_awards: #{Map.has_key?(metadata, "extracted_awards")}")
    
    if Map.has_key?(metadata, "extracted_awards") do
      awards = Map.get(metadata, "extracted_awards")
      Logger.info("   extracted_awards count: #{length(awards)}")
      if length(awards) > 0 do
        Logger.info("   First award: #{inspect(List.first(awards))}")
      end
    end
    
    job_args = %{
      "imdb_id" => movie_data.imdb_id,
      "source" => "canonical_import",
      "canonical_sources" => %{
        source_key => metadata
      }
    }
    
    Logger.info("   Job args canonical_sources.#{source_key} keys: #{inspect(get_in(job_args, ["canonical_sources", source_key]) |> Map.keys())}")
    
    case TMDbDetailsWorker.new(job_args) |> Oban.insert() do
      {:ok, _job} ->
        Logger.info("✅ Successfully queued import for #{movie_data.title}")
        Logger.info("🚀 === queue_canonical_movie_import END ===")
        %{
          action: :queued,
          imdb_id: movie_data.imdb_id,
          title: movie_data.title,
          source_key: source_key
        }
        
      {:error, reason} ->
        Logger.error("❌ Failed to queue import for #{movie_data.title}: #{inspect(reason)}")
        Logger.info("🚀 === queue_canonical_movie_import END ===")
        %{
          action: :error,
          imdb_id: movie_data.imdb_id,
          title: movie_data.title,
          reason: reason
        }
    end
  end
  
  defp update_canonical_sources(movie, source_key, metadata) do
    Logger.info("🔄 === update_canonical_sources START ===")
    Logger.info("   Movie: #{movie.title} (ID: #{movie.id})")
    Logger.info("   Source key: #{source_key}")
    Logger.info("   Metadata has extracted_awards: #{Map.has_key?(metadata, "extracted_awards")}")
    
    if Map.has_key?(metadata, "extracted_awards") do
      awards = Map.get(metadata, "extracted_awards")
      Logger.info("   extracted_awards count: #{length(awards)}")
      if length(awards) > 0 do
        Logger.info("   First award: #{inspect(List.first(awards))}")
      end
    end
    
    current_sources = movie.canonical_sources || %{}
    
    # Log what we're merging
    Logger.info("   Current canonical_sources keys: #{inspect(Map.keys(current_sources))}")
    Logger.info("   Metadata keys being added: #{inspect(Map.keys(metadata))}")
    
    updated_sources = Map.put(current_sources, source_key, Map.merge(%{
      "included" => true
    }, metadata))
    
    Logger.info("   Updated canonical_sources.#{source_key} keys: #{inspect(get_in(updated_sources, [source_key]) |> Map.keys())}")
    
    case movie
         |> Movies.Movie.changeset(%{canonical_sources: updated_sources})
         |> Repo.update() do
      {:ok, updated_movie} ->
        Logger.info("✅ Successfully marked #{movie.title} as canonical")
        
        # Verify the update
        stored_metadata = get_in(updated_movie.canonical_sources, [source_key])
        if stored_metadata do
          Logger.info("   Verification: stored metadata has extracted_awards: #{Map.has_key?(stored_metadata, "extracted_awards")}")
        end
        
        Logger.info("🔄 === update_canonical_sources END ===")
        %{
          action: :updated,
          movie_id: movie.id,
          title: movie.title,
          source_key: source_key
        }
        
      {:error, changeset} ->
        Logger.error("❌ Failed to update canonical sources for #{movie.title}: #{inspect(changeset.errors)}")
        Logger.info("🔄 === update_canonical_sources END ===")
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