defmodule Cinegraph.Scrapers.VeniceFilmFestivalScraper do
  @moduledoc """
  Scraper for Venice Film Festival (La Mostra) pages on IMDb to extract nominations and winners.

  Venice Film Festival is held annually and IMDb stores comprehensive award data
  including Golden Lion, Silver Lion, and various other prizes.

  IMDb Venice event ID: ev0000681
  URL pattern: https://www.imdb.com/event/ev0000681/{year}/1/
  """

  require Logger

  @zyte_api_url "https://api.zyte.com/v1/extract"
  # Increased to 2 minutes for Venice pages
  @timeout 120_000
  @max_retries 3

  # Venice Film Festival IMDb event ID
  @venice_event_id "ev0000681"

  # Venice-specific award mappings for normalization
  @venice_category_mappings [
    {"golden lion", "golden_lion"},
    {"silver lion", "silver_lion"},
    {"volpi cup", "volpi_cup"},
    {"special jury prize", "special_jury_prize"},
    {"marcello mastroianni award", "mastroianni_award"},
    {"orizzonti", "horizons"},
    {"luigi de laurentiis", "luigi_de_laurentiis"},
    {"premio osella", "osella_award"},
    {"jaeger-lecoultre glory to the filmmaker", "glory_to_filmmaker"}
  ]

  @doc """
  Fetch Venice Film Festival data for a specific year from IMDb.

  ## Parameters
    * year - The festival year (e.g., 2024 for the 81st Venice Film Festival)
    
  ## Returns
    * {:ok, data} - Structured festival data with categories, nominees, and winners
    * {:error, reason} - Error details
    
  ## Examples

      iex> VeniceFilmFestivalScraper.fetch_festival_data(2024)
      {:ok, %{year: 2024, festival: "Venice Film Festival", awards: %{...}}}
      
  """
  def fetch_festival_data(year) do
    url = "https://www.imdb.com/event/#{@venice_event_id}/#{year}/1/"

    Logger.info("Fetching Venice Film Festival data for #{year} from: #{url}")

    fetch_with_zyte(url, year)
  end

  @doc """
  Get available years for Venice Film Festival on IMDb.
  Scrapes the main event page to find all available years.

  ## Returns
    * {:ok, years} - List of available years
    * {:error, reason} - Error details
  """
  def get_available_years do
    url = "https://www.imdb.com/event/#{@venice_event_id}/"

    Logger.info("Fetching available Venice Film Festival years from: #{url}")

    case fetch_with_zyte(url, nil, "years") do
      {:ok, data} ->
        years = extract_available_years(data)
        {:ok, years}

      error ->
        error
    end
  end

  @doc """
  Fetch multiple years of Venice data in parallel.

  ## Parameters
    * years - List or range of years to fetch
    * opts - Options including :max_concurrency (default 3)
    
  ## Returns
    * {:ok, results} - Map of year => result
    * {:error, reason} - If unable to process
  """
  def fetch_multiple_years(years, opts \\ []) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 3)
    year_list = if is_list(years), do: years, else: Enum.to_list(years)

    Logger.info(
      "Fetching Venice data for #{length(year_list)} years with max_concurrency=#{max_concurrency}"
    )

    # Use Task.async_stream for controlled concurrency
    results =
      year_list
      |> Task.async_stream(
        &fetch_festival_data/1,
        max_concurrency: max_concurrency,
        timeout: @timeout * 2
      )
      |> Enum.map(fn
        {:ok, {:ok, data}} -> {data.year, {:ok, data}}
        {:ok, {:error, _reason}} = result -> {nil, result}
        {:exit, reason} -> {nil, {:error, {:timeout, reason}}}
      end)
      |> Enum.reject(fn {year, _} -> is_nil(year) end)
      |> Map.new()

    {:ok, results}
  end

  defp fetch_with_zyte(url, year, type \\ "festival") do
    # Try direct HTTP first, like the canonical scraper
    case fetch_html_direct(url) do
      {:ok, html} ->
        Logger.info("Successfully fetched Venice page directly")

        if type == "years" do
          {:ok, html}
        else
          parse_venice_festival_html(html, year)
        end

      {:error, _reason} ->
        # Fallback to Zyte API if direct fetch fails
        Logger.info("Direct fetch failed, trying Zyte API")
        api_key = Application.get_env(:cinegraph, :zyte_api_key)

        if is_nil(api_key) || api_key == "" do
          Logger.error("No ZYTE_API_KEY configured and direct fetch failed")
          {:error, :no_fetch_method_available}
        else
          fetch_with_zyte_request(url, year, type, 0)
        end
    end
  end

  defp fetch_html_direct(url) do
    # Direct HTTP fetch - use simpler headers that work with curl
    headers = [
      {"User-Agent",
       "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"},
      {"Accept-Language", "en-US,en;q=0.9"},
      {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}
    ]

    options = [
      timeout: 30_000,
      recv_timeout: 30_000,
      follow_redirect: true,
      max_redirect: 5
    ]

    Logger.info("Attempting direct HTTP fetch from: #{url}")

    case HTTPoison.get(url, headers, options) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        Logger.info("Successfully fetched HTML directly (#{byte_size(body)} bytes)")
        # Check if we got the full page with __NEXT_DATA__
        if String.contains?(body, "__NEXT_DATA__") do
          Logger.info("Got full page with __NEXT_DATA__")
        else
          Logger.warning("Page doesn't contain __NEXT_DATA__, may be simplified HTML")
        end

        {:ok, body}

      {:ok, %HTTPoison.Response{status_code: status_code, headers: headers}} ->
        Logger.error("HTTP #{status_code} response from IMDb")
        # Check if it's a redirect
        location =
          Enum.find_value(headers, fn {name, value} ->
            if String.downcase(name) == "location", do: value
          end)

        if location do
          Logger.info("Following redirect to: #{location}")
          fetch_html_direct(location)
        else
          {:error, "HTTP #{status_code}"}
        end

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("Failed to fetch directly: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_with_zyte_request(url, year, type, retries) do
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
            if type == "years" do
              {:ok, html}
            else
              parse_venice_festival_html(html, year)
            end

          error ->
            Logger.error("Failed to parse Zyte response: #{inspect(error)}")
            retry_or_fail(url, year, type, retries, "JSON parsing failed")
        end

      {:ok, %{status_code: status, body: body}} ->
        Logger.error("Zyte API error (#{status}): #{body}")
        retry_or_fail(url, year, type, retries, "HTTP #{status}")

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("Failed to fetch from Zyte: #{inspect(reason)}")
        retry_or_fail(url, year, type, retries, "HTTP error: #{inspect(reason)}")
    end
  end

  defp retry_or_fail(_url, _year, _type, retries, error) when retries >= @max_retries do
    Logger.error("Max retries (#{@max_retries}) reached. Last error: #{error}")
    {:error, error}
  end

  defp retry_or_fail(url, year, type, retries, error) do
    new_retries = retries + 1

    Logger.info(
      "Retrying request (attempt #{new_retries}/#{@max_retries}). Previous error: #{error}"
    )

    Process.sleep(1000 * new_retries)
    fetch_with_zyte_request(url, year, type, new_retries)
  end

  @doc """
  Parse Venice Film Festival HTML to extract structured award data.
  Tries multiple parsing strategies depending on the HTML structure.
  """
  def parse_venice_festival_html(html, year) do
    # First try looking for the __NEXT_DATA__ script tag (newer IMDb format)
    case Regex.run(~r/<script id="__NEXT_DATA__" type="application\/json">(.*?)<\/script>/s, html) do
      [_, json_content] ->
        case Jason.decode(json_content) do
          {:ok, data} ->
            extract_venice_awards(data, year)

          {:error, reason} ->
            Logger.error("Failed to parse __NEXT_DATA__ JSON: #{inspect(reason)}")
            # Fall back to HTML parsing
            parse_venice_html_fallback(html, year)
        end

      nil ->
        Logger.info("No __NEXT_DATA__ found, using HTML fallback parser")
        # Fall back to direct HTML parsing
        parse_venice_html_fallback(html, year)
    end
  end

  defp parse_venice_html_fallback(html, year) do
    # Parse HTML using Floki (HTML parser)
    case Floki.parse_document(html) do
      {:ok, document} ->
        extract_venice_from_html(document, year)

      {:error, reason} ->
        Logger.error("Failed to parse HTML: #{inspect(reason)}")
        {:error, "HTML parse error"}
    end
  end

  defp extract_venice_from_html(document, year) do
    # Try to extract awards from HTML structure
    # Look for common patterns in IMDb event pages

    # Look for award sections
    award_sections =
      Floki.find(document, "[class*='awards'], [class*='event-section'], [data-testid*='award']")

    awards =
      if length(award_sections) > 0 do
        # Extract from structured sections
        Enum.map(award_sections, &extract_award_from_section/1)
      else
        # Try alternative patterns
        extract_awards_from_list_format(document)
      end

    if length(awards) > 0 do
      {:ok,
       %{
         year: year,
         festival: "Venice Film Festival",
         awards: Map.new(awards),
         source: "imdb",
         timestamp: DateTime.utc_now(),
         parser: "html_fallback"
       }}
    else
      # Return minimal data structure to prevent errors
      Logger.warning("No awards found in HTML for Venice #{year}, returning empty structure")

      {:ok,
       %{
         year: year,
         festival: "Venice Film Festival",
         awards: %{},
         source: "imdb",
         timestamp: DateTime.utc_now(),
         parser: "html_fallback",
         note: "No awards data found - page may be empty or structure changed"
       }}
    end
  end

  defp extract_award_from_section(section) do
    # Extract award name and nominees from a section
    award_name =
      Floki.find(section, "h2, h3, .award-name")
      |> Floki.text()
      |> String.trim()
      |> normalize_venice_category_name()

    nominees =
      Floki.find(section, ".nominee, .winner, [class*='nominee'], [class*='winner']")
      |> Enum.map(&extract_nominee_info/1)

    {award_name, nominees}
  end

  defp extract_nominee_info(nominee_element) do
    # Extract film and person information from nominee element
    film_link = Floki.find(nominee_element, "a[href*='/title/']") |> List.first()
    person_links = Floki.find(nominee_element, "a[href*='/name/']")

    film_info =
      if film_link do
        href = Floki.attribute(film_link, "href") |> List.first()
        imdb_id = extract_imdb_id_from_href(href)
        title = Floki.text(film_link) |> String.trim()

        %{
          imdb_id: imdb_id,
          title: title
        }
      end

    people_info =
      Enum.map(person_links, fn link ->
        href = Floki.attribute(link, "href") |> List.first()
        imdb_id = extract_imdb_id_from_href(href)
        name = Floki.text(link) |> String.trim()

        %{
          imdb_id: imdb_id,
          name: name
        }
      end)

    is_winner =
      String.contains?(Floki.raw_html(nominee_element), "winner") ||
        String.contains?(Floki.text(nominee_element), "WINNER")

    %{
      films: if(film_info, do: [film_info], else: []),
      people: people_info,
      winner: is_winner
    }
  end

  defp extract_awards_from_list_format(document) do
    # Alternative extraction for list-based format
    # Venice 2025 might use a simpler list structure

    # Look for any links to titles (movies)
    movie_links = Floki.find(document, "a[href*='/title/tt']")

    if length(movie_links) > 0 do
      # Group movies by their surrounding context
      movies =
        Enum.map(movie_links, fn link ->
          href = Floki.attribute(link, "href") |> List.first()
          imdb_id = extract_imdb_id_from_href(href)
          title = Floki.text(link) |> String.trim()

          # Try to find award context
          parent = Floki.find(document, "body") |> List.first()
          context_text = if parent, do: Floki.text(parent), else: ""

          award_category =
            cond do
              String.contains?(context_text, "Golden Lion") -> "golden_lion"
              String.contains?(context_text, "Silver Lion") -> "silver_lion"
              String.contains?(context_text, "Volpi Cup") -> "volpi_cup"
              String.contains?(context_text, "Special Jury") -> "special_jury_prize"
              true -> "venice_award"
            end

          {award_category,
           [
             %{
               films: [%{imdb_id: imdb_id, title: title}],
               people: [],
               winner: true
             }
           ]}
        end)

      # Group by award category
      movies
      |> Enum.group_by(fn {category, _} -> category end, fn {_, nominees} -> nominees end)
      |> Enum.map(fn {category, nominee_groups} ->
        {category, List.flatten(nominee_groups)}
      end)
    else
      []
    end
  end

  defp extract_imdb_id_from_href(nil), do: nil

  defp extract_imdb_id_from_href(href) do
    case Regex.run(~r/(tt\d+|nm\d+)/, href) do
      [_, id] -> id
      _ -> nil
    end
  end

  def extract_venice_awards(next_data, year) do
    # Navigate the JSON structure to find nomination data
    # Similar path to Oscar scraper: props.pageProps.edition.awards
    try do
      awards =
        next_data
        |> get_in(["props", "pageProps", "edition", "awards"])

      if awards && length(awards) > 0 do
        parsed_awards = parse_venice_awards(awards)

        {:ok,
         %{
           year: year,
           festival: "Venice Film Festival",
           awards: parsed_awards,
           source: "imdb",
           timestamp: DateTime.utc_now(),
           parser: "next_data"
         }}
      else
        Logger.error("Could not find awards in Venice __NEXT_DATA__ structure")
        available_keys = get_in(next_data, ["props", "pageProps"])

        if available_keys do
          Logger.error("Available keys in pageProps: #{inspect(Map.keys(available_keys))}")
        end

        {:error, "No awards data found"}
      end
    rescue
      e ->
        Logger.error("Error extracting Venice nominations: #{inspect(e)}")
        {:error, "Data extraction error"}
    end
  end

  defp parse_venice_awards(awards) when is_list(awards) do
    awards
    |> Enum.flat_map(&parse_venice_award_category/1)
    |> Map.new()
  end

  defp parse_venice_awards(_), do: %{}

  defp parse_venice_award_category(award) do
    # Following the IMDb structure for Venice awards
    award_text = award["text"] || "Venice Award"
    nomination_categories = award["nominationCategories"] || %{}
    edges = nomination_categories["edges"] || []

    if length(edges) > 0 do
      # Parse each category edge
      edges
      |> Enum.map(fn edge ->
        node = edge["node"] || %{}
        # Category name is in node.category.text
        category_name = get_in(node, ["category", "text"]) || award_text
        nominations_data = node["nominations"] || %{}
        nomination_edges = nominations_data["edges"] || []

        if length(nomination_edges) > 0 do
          parsed_nominations =
            nomination_edges
            |> Enum.map(&parse_venice_nomination_edge/1)
            |> Enum.reject(&is_nil/1)

          {normalize_venice_category_name(category_name), parsed_nominations}
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp parse_venice_nomination_edge(edge) do
    # Following the same structure as Oscar scraper
    node = edge["node"] || %{}

    # Extract awarded entities
    awarded_entities = node["awardedEntities"] || %{}

    # Extract film info from awardTitles and secondaryAwardTitles
    award_titles = awarded_entities["awardTitles"] || []
    secondary_titles = awarded_entities["secondaryAwardTitles"] || []

    film_nominees =
      (award_titles ++ secondary_titles)
      |> Enum.map(fn award_title ->
        title = award_title["title"] || %{}

        %{
          imdb_id: title["id"],
          title: get_in(title, ["titleText", "text"]),
          year: get_in(title, ["releaseDate", "year"]),
          # Venice often has international films
          original_title: get_in(title, ["originalTitleText", "text"])
        }
      end)
      |> Enum.filter(& &1[:imdb_id])

    # Extract person info from awardNames and secondaryAwardNames
    award_names = awarded_entities["awardNames"] || []
    secondary_names = awarded_entities["secondaryAwardNames"] || []

    person_nominees =
      (award_names ++ secondary_names)
      |> Enum.map(fn award_name ->
        name = award_name["name"] || %{}

        %{
          imdb_id: name["id"],
          name: get_in(name, ["nameText", "text"])
        }
      end)
      |> Enum.filter(& &1[:imdb_id])

    # Check if winner (Venice has both winners and nominees)
    is_winner = node["isWinner"] || false

    # Get additional notes (Venice often has specific prize details)
    notes = node["notes"]

    %{
      films: film_nominees,
      people: person_nominees,
      winner: is_winner,
      notes: notes
    }
  end

  defp normalize_venice_category_name(name) do
    # Normalize Venice category names for consistency
    normalized =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, "")
      |> String.trim()

    # Handle common Venice award variations
    Enum.reduce(@venice_category_mappings, normalized, fn {from, to}, acc ->
      String.replace(acc, from, to)
    end)
    |> String.trim()
  end

  defp extract_available_years(html) do
    # Extract years from the main Venice event page
    # Look for year links in the format /event/ev0000681/2024/
    case Regex.scan(~r|/event/ev0000681/(\d{4})/|, html) do
      matches when matches != [] ->
        matches
        |> Enum.map(fn [_, year_str] -> String.to_integer(year_str) end)
        |> Enum.uniq()
        |> Enum.sort(:desc)

      _ ->
        Logger.warning("No Venice festival years found in HTML")
        []
    end
  end

  @doc """
  Create festival organization and ceremony records for Venice Film Festival.

  ## Parameters
    * year - Festival year
    * festival_data - Parsed festival data from IMDb
    
  ## Returns
    * {:ok, ceremony} - Created or updated ceremony record
    * {:error, reason} - Error details
  """
  def create_or_update_ceremony(year, festival_data) do
    # Get or create Venice Film Festival organization
    venice_org = get_or_create_venice_organization()

    case venice_org do
      %{id: org_id} ->
        ceremony_attrs = %{
          organization_id: org_id,
          year: year,
          name: "#{year} Venice International Film Festival",
          data: festival_data,
          data_source: "imdb",
          source_url: "https://www.imdb.com/event/#{@venice_event_id}/#{year}/1/",
          scraped_at: DateTime.utc_now(),
          source_metadata: %{
            "scraper" => "VeniceFilmFestivalScraper",
            "version" => "1.0",
            "festival" => "Venice Film Festival",
            "event_id" => @venice_event_id
          }
        }

        # Use the Festivals context to create/update ceremony
        Cinegraph.Festivals.upsert_ceremony(ceremony_attrs)

      {:error, reason} ->
        {:error, "Failed to create Venice organization: #{reason}"}
    end
  end

  defp get_or_create_venice_organization do
    # Create Venice Film Festival organization if it doesn't exist
    org_attrs = %{
      name: "Venice International Film Festival",
      abbreviation: "VIFF",
      country: "Italy",
      founded_year: 1932,
      website: "https://www.labiennale.org/en/cinema"
    }

    case Cinegraph.Festivals.get_organization_by_abbreviation("VIFF") do
      nil ->
        # Create using the same pattern as Oscar organization
        %Cinegraph.Festivals.FestivalOrganization{}
        |> Cinegraph.Festivals.FestivalOrganization.changeset(org_attrs)
        |> Cinegraph.Repo.insert()
        |> case do
          {:ok, org} ->
            org

          {:error, _changeset} ->
            # Race condition - try to get again
            Cinegraph.Repo.get_by!(Cinegraph.Festivals.FestivalOrganization, abbreviation: "VIFF")
        end

      existing_org ->
        existing_org
    end
  end
end
