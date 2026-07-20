defmodule Cinegraph.Scrapers.NfrScraper do
  @moduledoc """
  Scrapes National Film Registry induction events (#1115) — the crown-jewel source.

  Every NFR member carries a true **induction year**, which the DB previously
  lacked (`movies.canonical_sources["national_film_registry"]["scraped_year"]` is
  the film's *release* year). This scraper produces one `:added` event per film,
  with the induction year as `event_edition` (`"nfr_<year>"`) and the release year
  as `raw_year` (used for matching) — finally separating the two.

  Two sources are fetched and cross-checked:

    * **Wikipedia** (`https://en.wikipedia.org/wiki/National_Film_Registry`) — a
      single sortable `wikitable`: Title | Type | Year released | Year inducted.
      Parse-reliable and the primary event source.
    * **loc.gov complete listing** — the authoritative public record, used only to
      cross-check Wikipedia (it 403s easily behind a WAF; when it is unavailable
      the scrape still succeeds and the gap is logged in coverage, never fatal).

  NFR never removes films, so every event is `:added`. NFR titles carry no
  imdb_id, so matching relies on the title+year matcher downstream.

  Returns `{:ok, events, %{coverage: map}}` or `{:error, reason}` where each event
  is `%{event_type: :added, event_edition:, event_date: nil, raw_title:, raw_year:,
  raw_imdb_id: nil, source_url:, provenance: %{}}`.
  """

  require Logger

  alias Cinegraph.Scrapers.Http.Client, as: HttpClient

  @source_key "national_film_registry"
  @wikipedia_url "https://en.wikipedia.org/wiki/National_Film_Registry"
  @loc_url "https://www.loc.gov/programs/national-film-preservation-board/film-registry/complete-national-film-registry-listing/"

  @min_year 1888
  @max_year 2100

  @doc "Source key this scraper populates."
  def source_key, do: @source_key

  @doc """
  Fetch + parse NFR induction events. Wikipedia is the event source; loc.gov is a
  best-effort cross-check.
  """
  def scrape(_opts \\ []) do
    case fetch(:wikipedia, @wikipedia_url) do
      {:ok, wiki_html} ->
        wiki_films = parse_nfr_table(wiki_html, @wikipedia_url)
        loc_result = fetch_loc_films()
        events = Enum.map(wiki_films, &to_event/1)
        coverage = build_coverage(wiki_films, loc_result)
        {:ok, events, %{coverage: coverage}}

      {:error, reason} ->
        Logger.error("NfrScraper: Wikipedia fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_loc_films do
    case fetch(:loc, @loc_url) do
      {:ok, html} -> {:ok, parse_nfr_table(html, @loc_url)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_event(%{title: title, release_year: release_year, induction_year: induction_year}) do
    %{
      event_type: :added,
      event_edition: "nfr_#{induction_year}",
      event_date: nil,
      raw_title: title,
      raw_year: release_year,
      raw_imdb_id: nil,
      source_url: @wikipedia_url,
      provenance: %{"induction_year" => induction_year, "source" => "wikipedia"}
    }
  end

  # ── Table parsing ─────────────────────────────────────────────────────────

  @doc """
  Parse an NFR-style table into `%{title, release_year, induction_year}` rows.

  Works for both the Wikipedia wikitable (Title | Type | Release | Inducted) and
  the loc.gov listing (Title | Release | Inducted): the title is always the first
  cell, and the release/induction years are the min/max of the 4-digit years found
  in the *remaining* cells — so titles that contain a year ("2001", "1917", "1900")
  do not pollute the year detection. Rows without two parseable years are dropped
  (header/garbage rows).
  """
  def parse_nfr_table(html, source_url) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        doc
        |> Floki.find("table tr")
        |> Enum.map(&parse_row/1)
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        Logger.warning("NfrScraper: parse failed for #{source_url}: #{inspect(reason)}")
        []
    end
  end

  defp parse_row(row) do
    # Title may be a row-scope <th> (loc.gov) or a <td> (Wikipedia); take cells in
    # document order so the first is always the title and the rest hold the years.
    cells = Floki.find(row, "th, td")

    case cells do
      [] ->
        nil

      [title_cell | rest] ->
        title = clean_title(Floki.text(title_cell))
        years = rest |> Enum.flat_map(&extract_years(Floki.text(&1)))

        case {title, years} do
          {"", _} -> nil
          {_, []} -> nil
          {t, [single]} -> %{title: t, release_year: nil, induction_year: single}
          {t, ys} -> %{title: t, release_year: Enum.min(ys), induction_year: Enum.max(ys)}
        end
    end
  end

  # Strip surrounding quotes, footnote markers ([1], [a]), and whitespace.
  defp clean_title(text) do
    text
    |> String.replace(~r/\[[0-9a-z]+\]/iu, "")
    |> String.trim()
    |> String.trim("\"")
    |> String.trim()
  end

  defp extract_years(text) do
    ~r/\b(1[89]\d\d|20\d\d)\b/
    |> Regex.scan(text)
    |> Enum.map(fn [_, y] -> String.to_integer(y) end)
    |> Enum.filter(&(&1 >= @min_year and &1 <= @max_year))
  end

  # ── Cross-check coverage ──────────────────────────────────────────────────

  defp build_coverage(wiki_films, loc_result) do
    base = %{
      source_key: @source_key,
      events_found: length(wiki_films),
      # NFR only ever inducts (never removes), so every event is an add.
      adds: length(wiki_films),
      removes: 0,
      primary_source: "wikipedia",
      induction_years: wiki_films |> Enum.map(& &1.induction_year) |> Enum.uniq() |> Enum.sort()
    }

    case loc_result do
      {:ok, loc_films} ->
        wiki_titles = title_set(wiki_films)
        loc_titles = title_set(loc_films)

        Map.merge(base, %{
          cross_check: "loc+wikipedia",
          loc_events_found: length(loc_films),
          wikipedia_only: MapSet.difference(wiki_titles, loc_titles) |> MapSet.size(),
          loc_only: MapSet.difference(loc_titles, wiki_titles) |> MapSet.size()
        })

      {:error, reason} ->
        Map.merge(base, %{
          cross_check: "wikipedia_only",
          cap_reason: "loc.gov unavailable: #{inspect(reason)}"
        })
    end
  end

  defp title_set(films) do
    films
    |> Enum.map(&Cinegraph.ListEvents.MovieMatcher.normalize(&1.title))
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  # ── HTTP indirection (test seam) ──────────────────────────────────────────

  defp fetch(:wikipedia, url), do: wikipedia_client().fetch(url, :wikipedia, [])
  defp fetch(:loc, url), do: loc_client().fetch(url, :loc, [])

  defp wikipedia_client,
    do: Application.get_env(:cinegraph, :wikipedia_http_client, HttpClient)

  defp loc_client, do: Application.get_env(:cinegraph, :loc_http_client, HttpClient)
end
