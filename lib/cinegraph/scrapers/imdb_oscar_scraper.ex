defmodule Cinegraph.Scrapers.ImdbOscarScraper do
  @moduledoc """
  DEPRECATED: This scraper should no longer be used.
  Oscar data should come exclusively from oscars.org via Cinegraph.Scrapers.OscarScraper.

  Previously used to fetch IMDb IDs for Oscar nominees, but this functionality
  has been removed to avoid hardcoded festival logic.

  Kept for reference only - DO NOT USE.
  """

  require Logger

  @zyte_api_url "https://api.zyte.com/v1/extract"
  @timeout 60_000
  @max_retries 3

  # IMDb Oscar event ID
  @oscar_event_id "ev0000003"

  @category_mappings [
    {"best motion picture of the year", "best picture"},
    {"best performance by an actor", "actor"},
    {"best performance by an actress", "actress"},
    {"best achievement in", ""},
    {"music written for motion pictures original score", "music original score"},
    {"music written for motion pictures original song", "music original song"},
    {"best animated short film", "short film animated"},
    {"best live action short film", "short film live action"},
    {"best adapted screenplay", "writing adapted screenplay"},
    {"best original screenplay", "writing original screenplay"}
  ]

  # Year mapping for early ceremonies (from oscar_data)
  @year_map %{
    1927 => 1929,
    1928 => 1930,
    1929 => 1930,
    1930 => 1931,
    1931 => 1932,
    1932 => 1932,
    1933 => 1934
  }

  @doc """
  Fetch IMDb Oscar data for a specific ceremony year.
  Returns structured data with IMDb IDs.
  """
  def fetch_ceremony_imdb_data(ceremony_year) do
    # Map ceremony year to IMDb URL year
    url_year = Map.get(@year_map, ceremony_year, ceremony_year + 1)
    url = "https://www.imdb.com/event/#{@oscar_event_id}/#{url_year}/1"

    Logger.info("Fetching IMDb Oscar data for #{ceremony_year} from: #{url}")

    fetch_with_zyte(url, ceremony_year)
  end

  defp fetch_with_zyte(url, ceremony_year, retries \\ 0) do
    api_key = Application.get_env(:cinegraph, :zyte_api_key)

    if is_nil(api_key) || api_key == "" do
      Logger.error("No ZYTE_API_KEY configured")
      {:error, :missing_zyte_api_key}
    else
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
              parse_imdb_oscar_html(html, ceremony_year)

            error ->
              Logger.error("Failed to parse Zyte response: #{inspect(error)}")
              retry_or_fail(url, ceremony_year, retries, "JSON parsing failed")
          end

        {:ok, %{status_code: status, body: body}} ->
          Logger.error("Zyte API error (#{status}): #{body}")
          retry_or_fail(url, ceremony_year, retries, "HTTP #{status}")

        {:error, %HTTPoison.Error{reason: reason}} ->
          Logger.error("Failed to fetch from Zyte: #{inspect(reason)}")
          retry_or_fail(url, ceremony_year, retries, "HTTP error: #{inspect(reason)}")
      end
    end
  end

  defp retry_or_fail(_url, _ceremony_year, retries, error) when retries >= @max_retries do
    Logger.error("Max retries (#{@max_retries}) reached. Last error: #{error}")
    {:error, error}
  end

  defp retry_or_fail(url, ceremony_year, retries, error) do
    new_retries = retries + 1

    Logger.info(
      "Retrying request (attempt #{new_retries}/#{@max_retries}). Previous error: #{error}"
    )

    Process.sleep(1000 * new_retries)
    fetch_with_zyte(url, ceremony_year, new_retries)
  end

  @doc """
  Parse IMDb Oscar HTML to extract structured data.
  Following oscar_data's approach to find the __NEXT_DATA__ JSON.
  """
  def parse_imdb_oscar_html(html, ceremony_year) do
    # Look for the __NEXT_DATA__ script tag
    case Regex.run(~r/<script id="__NEXT_DATA__" type="application\/json">(.*?)<\/script>/s, html) do
      [_, json_content] ->
        case Jason.decode(json_content) do
          {:ok, data} ->
            extract_nominations(data, ceremony_year)

          {:error, reason} ->
            Logger.error("Failed to parse __NEXT_DATA__ JSON: #{inspect(reason)}")
            {:error, "JSON parse error"}
        end

      nil ->
        Logger.error("Could not find __NEXT_DATA__ in IMDb page")
        {:error, "No __NEXT_DATA__ found"}
    end
  end

  defp extract_nominations(next_data, ceremony_year) do
    # Navigate the JSON structure to find nomination data
    # The correct path is props.pageProps.edition.awards
    try do
      awards =
        next_data
        |> get_in(["props", "pageProps", "edition", "awards"]) || []

      if awards do
        nominations = parse_awards(awards)

        {:ok,
         %{
           year: ceremony_year,
           awards: nominations,
           source: "imdb",
           timestamp: DateTime.utc_now()
         }}
      else
        Logger.error("Could not find awards in __NEXT_DATA__ structure")

        Logger.error(
          "Available keys in pageProps: #{inspect(get_in(next_data, ["props", "pageProps"]) |> Map.keys())}"
        )

        {:error, "No awards data found"}
      end
    rescue
      e ->
        Logger.error("Error extracting nominations: #{inspect(e)}")
        {:error, "Data extraction error"}
    end
  end

  defp parse_awards(awards) when is_list(awards) do
    awards
    |> Enum.flat_map(&parse_award_category/1)
    |> Map.new()
  end

  defp parse_awards(_), do: %{}

  defp parse_award_category(award) do
    # Following the actual IMDb structure
    award_text = award["text"] || "Oscar"
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
            |> Enum.map(&parse_nomination_edge/1)
            |> Enum.reject(&is_nil/1)

          {category_name, parsed_nominations}
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp parse_nomination_edge(edge) do
    # Following the actual IMDb structure
    node = edge["node"] || %{}

    # Extract awarded entities
    awarded_entities = node["awardedEntities"] || %{}

    # Extract film info from awardTitles (for Best Picture) or secondaryAwardTitles (for acting categories)
    award_titles = awarded_entities["awardTitles"] || []
    secondary_titles = awarded_entities["secondaryAwardTitles"] || []

    film_nominees =
      (award_titles ++ secondary_titles)
      |> Enum.map(fn award_title ->
        title = award_title["title"] || %{}

        %{
          imdb_id: title["id"],
          title: get_in(title, ["titleText", "text"]),
          year: get_in(title, ["releaseDate", "year"])
        }
      end)
      |> Enum.filter(& &1[:imdb_id])

    # Extract person info from awardNames (for acting) or secondaryAwardNames (for producing)
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

    # Check if winner
    is_winner = node["isWinner"] || false

    # Get additional notes
    notes = node["notes"]

    %{
      films: film_nominees,
      people: person_nominees,
      winner: is_winner,
      notes: notes
    }
  end

  @doc """
  Match IMDb data with our Oscar ceremony data.
  Returns enhanced ceremony data with IMDb IDs.
  """
  def enhance_ceremony_with_imdb(ceremony) do
    # Oscar ceremonies honor films from the previous year
    # e.g., 2023 ceremony (95th) honors 2022 films
    film_year = ceremony.year - 1

    case fetch_ceremony_imdb_data(film_year) do
      {:ok, imdb_data} ->
        enhanced_categories = enhance_categories(ceremony.data["categories"], imdb_data[:awards])

        updated_data =
          ceremony.data
          |> Map.put("categories", enhanced_categories)
          |> Map.put("imdb_matched", true)
          |> Map.put("imdb_match_timestamp", DateTime.utc_now())

        {:ok, updated_data}

      {:error, reason} ->
        Logger.error(
          "Failed to fetch IMDb data for ceremony #{ceremony.year} (film year #{film_year}): #{reason}"
        )

        {:error, reason}
    end
  end

  defp enhance_categories(categories, imdb_awards)
       when is_list(categories) and is_map(imdb_awards) do
    categories
    |> Enum.map(fn category ->
      # Try to match category name
      imdb_category_data = find_matching_imdb_category(category["category"], imdb_awards)

      if imdb_category_data do
        enhanced_nominees = enhance_nominees(category["nominees"], imdb_category_data)
        Map.put(category, "nominees", enhanced_nominees)
      else
        Logger.warning("No IMDb match for category: #{category["category"]}")
        category
      end
    end)
  end

  defp enhance_categories(categories, _), do: categories || []

  defp find_matching_imdb_category(category_name, imdb_awards) do
    # Try exact match first
    case Map.get(imdb_awards, category_name) do
      nil ->
        # Try to find a fuzzy match
        imdb_awards
        |> Enum.find(fn {imdb_cat, _} ->
          normalize_category_name(imdb_cat) == normalize_category_name(category_name)
        end)
        |> case do
          {_, data} -> data
          nil -> nil
        end

      data ->
        data
    end
  end

  defp normalize_category_name(name) do
    # Normalize category names to match between Oscar.org and IMDb
    normalized =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, "")
      |> String.trim()

    # Handle common variations
    Enum.reduce(@category_mappings, normalized, fn {from, to}, acc ->
      String.replace(acc, from, to)
    end)
    |> String.trim()
  end

  defp enhance_nominees(nominees, imdb_nominations)
       when is_list(nominees) and is_list(imdb_nominations) do
    nominees
    |> Enum.map(fn nominee ->
      # Find matching IMDb nomination
      imdb_match = find_matching_imdb_nomination(nominee, imdb_nominations)

      if imdb_match do
        nominee
        |> add_imdb_film_data(imdb_match[:films])
        |> add_imdb_person_data(imdb_match[:people])
      else
        nominee
      end
    end)
  end

  defp enhance_nominees(nominees, _), do: nominees || []

  defp find_matching_imdb_nomination(nominee, imdb_nominations) do
    # Match by winner status and film/person names
    Enum.find(imdb_nominations, fn imdb_nom ->
      imdb_nom[:winner] == nominee["winner"] &&
        (film_matches?(nominee["film"], imdb_nom[:films]) ||
           person_matches?(nominee["name"], imdb_nom[:people]))
    end)
  end

  defp film_matches?(film_title, imdb_films) when is_binary(film_title) and is_list(imdb_films) do
    Enum.any?(imdb_films, fn imdb_film ->
      normalize_title(film_title) == normalize_title(imdb_film[:title])
    end)
  end

  defp film_matches?(_, _), do: false

  defp person_matches?(person_name, imdb_people)
       when is_binary(person_name) and is_list(imdb_people) do
    # Handle multiple people (producers, etc.)
    person_names = String.split(person_name, ~r/,\s*/)

    Enum.any?(person_names, fn name ->
      normalized = normalize_title(name)

      Enum.any?(imdb_people, fn imdb_person ->
        normalize_title(imdb_person[:name]) == normalized
      end)
    end)
  end

  defp person_matches?(_, _), do: false

  defp normalize_title(title) when is_binary(title) do
    title
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
  end

  defp normalize_title(_), do: ""

  defp add_imdb_film_data(nominee, imdb_films) when is_list(imdb_films) do
    case List.first(imdb_films) do
      nil ->
        nominee

      film_data ->
        nominee
        |> Map.put("film_imdb_id", film_data[:imdb_id])
        |> Map.put("film_year", film_data[:year])
    end
  end

  defp add_imdb_film_data(nominee, _), do: nominee

  defp add_imdb_person_data(nominee, imdb_people) when is_list(imdb_people) do
    if length(imdb_people) > 0 do
      person_ids = Enum.map(imdb_people, & &1[:imdb_id])
      Map.put(nominee, "person_imdb_ids", person_ids)
    else
      nominee
    end
  end

  defp add_imdb_person_data(nominee, _), do: nominee
end
