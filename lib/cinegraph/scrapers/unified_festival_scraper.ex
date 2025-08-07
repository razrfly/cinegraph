defmodule Cinegraph.Scrapers.UnifiedFestivalScraper do
  @moduledoc """
  Unified scraper for multiple film festivals and awards from IMDb.
  Supports Cannes, BAFTA, Berlin, and Venice film festivals.
  """

  require Logger
  
  alias Cinegraph.Events
  alias Cinegraph.Events.{FestivalEvent, FestivalEventCache}

  @timeout 30_000

  @doc """
  Fetch festival data for a specific festival and year.

  ## Parameters
    * festival_key - One of: "cannes", "bafta", "berlin", "venice"
    * year - The festival year
    
  ## Returns
    * {:ok, data} - Structured festival data
    * {:error, reason} - Error details
  """
  def fetch_festival_data(festival_key, year) when is_binary(festival_key) do
    case Events.get_active_by_source_key(festival_key) do
      nil ->
        {:error, "Unknown festival: #{festival_key}"}

      festival_event ->
        festival_config = FestivalEvent.to_scraper_config(festival_event)
        url = build_imdb_url(festival_config.event_id, year)
        Logger.info("Fetching #{festival_config.name} data for #{year} from: #{url}")

        case fetch_html_direct(url) do
          {:ok, html} ->
            parse_festival_html(html, year, festival_config)

          {:error, reason} ->
            Logger.error("Failed to fetch #{festival_config.name} #{year}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  @doc """
  Get all supported festival keys.
  """
  def supported_festivals do
    FestivalEventCache.get_active_events()
    |> Enum.map(& &1.source_key)
  end

  @doc """
  Get festival configuration by key.
  """
  def get_festival_config(festival_key) do
    case Events.get_active_by_source_key(festival_key) do
      nil -> nil
      festival_event -> FestivalEvent.to_scraper_config(festival_event)
    end
  end

  defp build_imdb_url(event_id, year) do
    "https://www.imdb.com/event/#{event_id}/#{year}/1/"
  end

  defp fetch_html_direct(url) do
    headers = [
      {"User-Agent",
       "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"},
      {"Accept-Language", "en-US,en;q=0.9"},
      {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}
    ]

    options = [
      timeout: @timeout,
      recv_timeout: @timeout,
      follow_redirect: true,
      max_redirect: 5
    ]

    case HTTPoison.get(url, headers, options) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        Logger.info("Successfully fetched HTML (#{byte_size(body)} bytes)")
        {:ok, body}

      {:ok, %HTTPoison.Response{status_code: status_code}} ->
        {:error, "HTTP #{status_code}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  def parse_festival_html(html, year, festival_config) do
    # First try looking for __NEXT_DATA__ (modern IMDb format)
    case Regex.run(~r/<script id="__NEXT_DATA__" type="application\/json">(.*?)<\/script>/s, html) do
      [_, json_content] ->
        case Jason.decode(json_content) do
          {:ok, data} ->
            extract_festival_awards(data, year, festival_config)

          {:error, reason} ->
            Logger.error("Failed to parse __NEXT_DATA__ JSON: #{inspect(reason)}")
            parse_html_fallback(html, year, festival_config)
        end

      nil ->
        Logger.info("No __NEXT_DATA__ found, using HTML fallback parser")
        parse_html_fallback(html, year, festival_config)
    end
  end

  defp parse_html_fallback(html, year, festival_config) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        extract_from_html(document, year, festival_config)

      {:error, reason} ->
        Logger.error("Failed to parse HTML: #{inspect(reason)}")
        {:error, "HTML parse error"}
    end
  end

  defp extract_festival_awards(next_data, year, festival_config) do
    try do
      awards = get_in(next_data, ["props", "pageProps", "edition", "awards"])

      if awards && length(awards) > 0 do
        parsed_awards = parse_awards(awards, festival_config)

        {:ok,
         %{
           year: year,
           festival: festival_config.name,
           festival_key: get_festival_key(festival_config),
           awards: parsed_awards,
           source: "imdb",
           timestamp: DateTime.utc_now(),
           parser: "next_data"
         }}
      else
        Logger.warning("No awards data found in __NEXT_DATA__")
        {:ok, empty_festival_data(year, festival_config)}
      end
    rescue
      e ->
        Logger.error("Error extracting festival nominations: #{inspect(e)}")
        {:ok, empty_festival_data(year, festival_config)}
    end
  end

  defp extract_from_html(document, year, festival_config) do
    # Look for movie links
    movie_links = Floki.find(document, "a[href*='/title/tt']")

    awards =
      if length(movie_links) > 0 do
        # Extract basic award information from HTML
        extract_awards_from_links(movie_links, document, festival_config)
      else
        %{}
      end

    {:ok,
     %{
       year: year,
       festival: festival_config.name,
       festival_key: get_festival_key(festival_config),
       awards: awards,
       source: "imdb",
       timestamp: DateTime.utc_now(),
       parser: "html_fallback"
     }}
  end

  defp extract_awards_from_links(movie_links, _document, festival_config) do
    # Group movies into a generic award category
    default_category = get_default_category(festival_config)

    nominees =
      Enum.map(movie_links, fn link ->
        href = Floki.attribute(link, "href") |> List.first()
        imdb_id = extract_imdb_id(href)
        title = Floki.text(link) |> String.trim()

        %{
          films: [%{imdb_id: imdb_id, title: title}],
          people: [],
          # Can't determine from basic HTML
          winner: false
        }
      end)
      |> Enum.uniq_by(fn n -> get_in(n, [:films, Access.at(0), :imdb_id]) end)

    %{default_category => nominees}
  end

  defp parse_awards(awards, festival_config) when is_list(awards) do
    awards
    |> Enum.flat_map(&parse_award_category(&1, festival_config))
    |> Map.new()
  end

  defp parse_awards(_, _), do: %{}

  defp parse_award_category(award, festival_config) do
    award_text = award["text"] || get_default_category(festival_config)
    nomination_categories = award["nominationCategories"] || %{}
    edges = nomination_categories["edges"] || []

    if length(edges) > 0 do
      edges
      |> Enum.map(fn edge ->
        node = edge["node"] || %{}
        category_name = get_in(node, ["category", "text"]) || award_text
        nominations_data = node["nominations"] || %{}
        nomination_edges = nominations_data["edges"] || []

        if length(nomination_edges) > 0 do
          parsed_nominations =
            nomination_edges
            |> Enum.map(&parse_nomination_edge/1)
            |> Enum.reject(&is_nil/1)

          {normalize_category_name(category_name, festival_config), parsed_nominations}
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
    node = edge["node"] || %{}
    awarded_entities = node["awardedEntities"] || %{}

    # Extract films
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
          original_title: get_in(title, ["originalTitleText", "text"])
        }
      end)
      |> Enum.filter(& &1[:imdb_id])

    # Extract people
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

    is_winner = node["isWinner"] || false
    notes = node["notes"]

    %{
      films: film_nominees,
      people: person_nominees,
      winner: is_winner,
      notes: notes
    }
  end

  defp normalize_category_name(name, festival_config) do
    # Normalize category names based on festival
    normalized =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s]/, "")
      |> String.trim()
      |> String.replace(~r/\s+/, "_")

    # Apply festival-specific mappings if needed
    apply_festival_mappings(normalized, festival_config)
  end

  defp apply_festival_mappings(name, festival_config) do
    # Try to get category mappings from database metadata
    case get_festival_event_by_config(festival_config) do
      %{metadata: %{"category_mappings" => mappings}} when is_map(mappings) ->
        Map.get(mappings, name, name)
      _ ->
        # No mapping found, return name as-is
        name
    end
  end
  
  defp get_festival_event_by_config(festival_config) do
    FestivalEventCache.find_by_abbreviation(festival_config.abbreviation)
  end

  defp extract_imdb_id(nil), do: nil

  defp extract_imdb_id(href) do
    case Regex.run(~r/(tt\d+|nm\d+)/, href) do
      [_, id] -> id
      _ -> nil
    end
  end

  defp get_festival_key(festival_config) do
    # Try to find the festival by abbreviation in the database
    case get_festival_event_by_config(festival_config) do
      %{source_key: source_key} -> source_key
      nil -> String.downcase(festival_config.abbreviation || "unknown")
    end
  end

  defp get_default_category(festival_config) do
    # Try to get default category from database metadata
    case get_festival_event_by_config(festival_config) do
      %{metadata: %{"default_category" => default_category}} when is_binary(default_category) ->
        default_category
      _ ->
        # Fallback to a generic category
        "festival_award"
    end
  end

  defp empty_festival_data(year, festival_config) do
    %{
      year: year,
      festival: festival_config.name,
      festival_key: get_festival_key(festival_config),
      awards: %{},
      source: "imdb",
      timestamp: DateTime.utc_now(),
      parser: "empty",
      note: "No awards data found"
    }
  end
end
