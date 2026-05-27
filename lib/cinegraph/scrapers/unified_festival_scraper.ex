defmodule Cinegraph.Scrapers.UnifiedFestivalScraper do
  @moduledoc """
  Unified scraper for multiple film festivals and awards from IMDb.
  Supports Cannes, BAFTA, Berlin, and Venice film festivals.
  """

  require Logger

  alias Cinegraph.Events
  alias Cinegraph.Events.FestivalEvent
  alias Cinegraph.Metrics.ApiTracker
  alias Cinegraph.Scrapers.Http.Client, as: HttpClient

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

        # Build URL using template from database or fall back to default IMDb format
        url = build_festival_url(festival_config, year)

        if url do
          Logger.info("Fetching #{festival_config.name} data for #{year} from: #{url}")

          # Track the festival scraping operation
          ApiTracker.track_lookup("festival_scraper", "fetch_#{festival_key}", "#{year}", fn ->
            case http_client().fetch(url, :imdb, mode: :javascript) do
              {:ok, html} ->
                parse_festival_html(html, year, festival_config)

              {:error, reason} ->
                Logger.error(
                  "Failed to fetch #{festival_config.name} #{year}: #{inspect(reason)}"
                )

                {:error, reason}
            end
          end)
        else
          {:error, "No URL template or event ID configured for #{festival_key}"}
        end
    end
  end

  @doc """
  Get all supported festival keys.
  """
  def supported_festivals do
    Events.list_active_events()
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

  @doc """
  Fetch available years for an IMDb event.

  Tries candidate years in descending order starting from the current year,
  falling back to earlier years if the current-year IMDb page doesn't exist
  (403, empty editions, missing __NEXT_DATA__, etc.). Bounded by `max_attempts`
  to avoid runaway API calls.

  ## Parameters
    * event_id - IMDb event ID (e.g., "ev0000147" for Cannes, "ev0000003" for Oscars)
    * opts
      * `:known_good_year` - hint from DB (tried first, skips fallback for warm events)
      * `:max_attempts` - max candidate years to try (default 15)

  ## Returns
    * {:ok, [years]} - List of years (integers) sorted descending
    * {:error, :no_year_with_editions} - all candidates exhausted
    * {:error, reason} - other error

  """
  def fetch_available_years(event_id, opts \\ []) when is_binary(event_id) do
    max_attempts = Keyword.get(opts, :max_attempts, 15)
    known_good_year = Keyword.get(opts, :known_good_year)
    candidates = build_candidate_years(known_good_year, max_attempts)

    Logger.info(
      "Fetching available years for event #{event_id} (#{length(candidates)} candidates, hint: #{inspect(known_good_year)})"
    )

    ApiTracker.track_lookup("festival_scraper", "fetch_years", event_id, fn ->
      try_years(event_id, candidates)
    end)
  end

  @doc false
  def build_candidate_years(known_good_year, max_attempts \\ 15) do
    current = Date.utc_today().year
    base = for offset <- 0..(max_attempts - 1), do: current - offset

    candidates =
      if known_good_year do
        [known_good_year | Enum.reject(base, &(&1 == known_good_year))]
      else
        base
      end

    Enum.take(candidates, max_attempts)
  end

  defp try_years(event_id, candidates), do: try_years(event_id, candidates, nil)

  defp try_years(_event_id, [], last_reason) do
    Logger.warning(
      "YearDiscovery: exhausted all candidates, last failure: #{inspect(last_reason)}"
    )

    {:error, :no_year_with_editions}
  end

  defp try_years(event_id, [year | rest], _last_reason) do
    url = "https://www.imdb.com/event/#{event_id}/#{year}/1/"
    Logger.debug("YearDiscovery: trying #{url}")

    with {:ok, html} <- http_client().fetch(url, :imdb, mode: :javascript),
         {:ok, years} <- extract_available_years(html, event_id) do
      {:ok, years}
    else
      error -> try_years(event_id, rest, error)
    end
  end

  defp http_client do
    Application.get_env(:cinegraph, :festival_http_client, HttpClient)
  end

  @doc false
  def extract_available_years(html, event_id) do
    case Regex.run(~r/<script id="__NEXT_DATA__" type="application\/json">(.*?)<\/script>/s, html) do
      [_, json_content] ->
        case Jason.decode(json_content) do
          {:ok, data} ->
            editions = get_in(data, ["props", "pageProps", "historyEventEditions"]) || []

            years =
              editions
              |> Enum.map(fn edition -> edition["year"] end)
              |> Enum.reject(&is_nil/1)
              |> Enum.sort(:desc)

            if length(years) > 0 do
              Logger.info(
                "Found #{length(years)} years for event #{event_id}: #{Enum.min(years)}-#{Enum.max(years)}"
              )

              {:ok, years}
            else
              Logger.warning("No years found in historyEventEditions for event #{event_id}")
              {:error, "No years found in historyEventEditions"}
            end

          {:error, reason} ->
            Logger.error(
              "Failed to parse __NEXT_DATA__ JSON for year discovery: #{inspect(reason)}"
            )

            {:error, "JSON parsing failed"}
        end

      nil ->
        Logger.warning("No __NEXT_DATA__ found for event #{event_id}")
        {:error, "No __NEXT_DATA__ found"}
    end
  end

  defp build_festival_url(festival_config, year) do
    cond do
      # First check for url_template in config
      festival_config[:url_template] ->
        festival_config[:url_template]
        |> String.replace("{event_id}", festival_config[:event_id] || "")
        |> String.replace("{year}", to_string(year))

      # Fall back to IMDb URL if event_id is present
      festival_config[:event_id] ->
        "https://www.imdb.com/event/#{festival_config[:event_id]}/#{year}/1/"

      # No URL can be built
      true ->
        nil
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

  defp extract_imdb_id(nil), do: nil

  defp extract_imdb_id(href) do
    case Regex.run(~r/(tt\d+|nm\d+)/, href) do
      [_, id] -> id
      _ -> nil
    end
  end

  defp get_festival_event_by_config(festival_config) do
    Events.list_active_events()
    |> Enum.find(fn event -> event.abbreviation == festival_config.abbreviation end)
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
