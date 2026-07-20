defmodule Cinegraph.Scrapers.Movies1001Scraper do
  @moduledoc """
  Scrapes edition-to-edition add/remove events for "1001 Movies You Must See
  Before You Die" (#1115).

  The DB stamps all 1,257 `1001_movies` rows with edition `"2024"` — the
  all-editions union, including ~250 films that were *removed* in later editions
  yet are still graded as positives. This scraper recovers the real per-edition
  history by **diffing consecutive edition membership sets**:

    * a film in edition N but not in the previous fetched edition → `:added` at N
    * a film in the previous fetched edition but not in N → `:removed` at N
    * every film in the earliest fetched edition → `:added` at that baseline

  Edition list pages are operator-configurable (the canonical data is
  fan-maintained, no single authoritative URL). Set them via:

      config :cinegraph, :movies_1001_edition_urls, [
        {"2003", "https://.../2003-edition"},
        {"2004", "https://.../2004-edition"},
        ...
      ]

  in chronological order. Each page is parsed into `%{title, year, imdb_id}`
  entries; identity for diffing is `imdb_id` when present, else normalized
  title+year. An edition whose page fails to fetch/parse is **skipped and logged
  as a coverage cap** — the diff then spans the gap (events at the next fetched
  edition cover the skipped span), never producing spurious churn against a
  missing edition.

  Returns `{:ok, events, %{coverage: map}}` or `{:error, reason}`. Each event is
  `%{event_type: :added|:removed, event_edition:, event_date: nil, raw_title:,
  raw_year:, raw_imdb_id:, source_url:, provenance: %{}}`.
  """

  require Logger

  alias Cinegraph.ListEvents.MovieMatcher
  alias Cinegraph.Scrapers.Http.Client, as: HttpClient

  @source_key "1001_movies"

  @doc "Source key this scraper populates."
  def source_key, do: @source_key

  @doc """
  Fetch every configured edition page, diff consecutive fetched editions, and
  return the add/remove events plus coverage.

  Options:
    * `:editions` — override the configured `[{edition, url}]` list (used by tests).
  """
  def scrape(opts \\ []) do
    editions = Keyword.get(opts, :editions) || configured_editions()

    case editions do
      [] ->
        {:error, :no_editions_configured}

      editions ->
        fetched = Enum.map(editions, &fetch_edition/1)
        ok = Enum.filter(fetched, &match?({:ok, _ed, _url, _entries}, &1))
        skipped = for {:error, ed, reason} <- fetched, do: {ed, reason}

        events = diff_editions(ok)
        coverage = build_coverage(editions, ok, skipped, events)
        {:ok, events, %{coverage: coverage}}
    end
  end

  defp configured_editions do
    Application.get_env(:cinegraph, :movies_1001_edition_urls, [])
  end

  # ── Fetch + parse one edition ─────────────────────────────────────────────

  defp fetch_edition({edition, url}) do
    case http_client().fetch(url, :wikipedia, []) do
      {:ok, html} ->
        case parse_edition(html) do
          [] -> {:error, edition, :no_entries_parsed}
          entries -> {:ok, edition, url, entries}
        end

      {:error, reason} ->
        Logger.warning("Movies1001Scraper: edition #{edition} fetch failed: #{inspect(reason)}")
        {:error, edition, reason}
    end
  end

  @doc """
  Parse one edition list page into `%{title, year, imdb_id}` entries.

  Each list item (`li`) is expected to carry a film title and a 4-digit year in
  parentheses; an IMDb id is captured from any `tt\\d+` link in the item when
  present. Items without a title are dropped.
  """
  def parse_edition(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        doc
        |> Floki.find("li")
        |> Enum.map(&parse_item/1)
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        Logger.warning("Movies1001Scraper: parse failed: #{inspect(reason)}")
        []
    end
  end

  defp parse_item(item) do
    text = item |> Floki.text() |> String.trim()
    imdb_id = extract_imdb_id(item)
    year = extract_year(text)
    title = clean_title(text)

    if title == "" do
      nil
    else
      %{title: title, year: year, imdb_id: imdb_id}
    end
  end

  defp extract_imdb_id(item) do
    item
    |> Floki.attribute("a", "href")
    |> Enum.find_value(fn href ->
      case Regex.run(~r/(tt\d{6,})/, href) do
        [_, id] -> id
        _ -> nil
      end
    end)
  end

  defp extract_year(text) do
    case Regex.run(~r/\((1[89]\d\d|20\d\d)\)/, text) do
      [_, y] -> String.to_integer(y)
      _ -> nil
    end
  end

  # Title is the text with the trailing "(YYYY)" and footnote markers removed.
  defp clean_title(text) do
    text
    |> String.replace(~r/\((1[89]\d\d|20\d\d)\).*$/, "")
    |> String.replace(~r/\[[0-9a-z]+\]/iu, "")
    |> String.trim()
  end

  # ── Diff consecutive fetched editions ─────────────────────────────────────

  defp diff_editions(ok_editions) do
    ok_editions
    |> Enum.reduce({MapSet.new(), %{}, []}, fn {:ok, edition, url, entries},
                                               {prev_keys, prev_by_key, acc} ->
      by_key = Map.new(entries, fn e -> {identity(e), e} end)
      keys = MapSet.new(Map.keys(by_key))

      added = MapSet.difference(keys, prev_keys)
      removed = MapSet.difference(prev_keys, keys)

      add_events =
        Enum.map(added, fn k -> to_event(:added, edition, url, Map.fetch!(by_key, k)) end)

      remove_events =
        Enum.map(removed, fn k -> to_event(:removed, edition, url, Map.fetch!(prev_by_key, k)) end)

      {keys, by_key, acc ++ add_events ++ remove_events}
    end)
    |> elem(2)
  end

  defp identity(%{imdb_id: imdb_id}) when is_binary(imdb_id), do: {:imdb, imdb_id}

  defp identity(%{title: title, year: year}),
    do: {:title_year, MovieMatcher.normalize(title), year}

  defp to_event(type, edition, url, %{title: title, year: year, imdb_id: imdb_id}) do
    %{
      event_type: type,
      event_edition: edition,
      event_date: nil,
      raw_title: title,
      raw_year: year,
      raw_imdb_id: imdb_id,
      source_url: url,
      provenance: %{"edition" => edition, "source" => "1001_edition_diff"}
    }
  end

  # ── Coverage ──────────────────────────────────────────────────────────────

  defp build_coverage(all_editions, ok_editions, skipped, events) do
    fetched = for {:ok, ed, _url, _entries} <- ok_editions, do: ed

    %{
      source_key: @source_key,
      editions_configured: length(all_editions),
      editions_fetched: fetched,
      editions_skipped: skipped,
      events_found: length(events),
      adds: Enum.count(events, &(&1.event_type == :added)),
      removes: Enum.count(events, &(&1.event_type == :removed)),
      cross_check: cross_check_status(skipped),
      cap_reason: cap_reason(skipped)
    }
  end

  defp cross_check_status([]), do: "all_editions_fetched"
  defp cross_check_status(_skipped), do: "partial_editions"

  defp cap_reason([]), do: nil

  defp cap_reason(skipped) do
    "skipped editions: " <>
      (skipped
       |> Enum.map(fn {ed, reason} -> "#{ed} (#{inspect(reason)})" end)
       |> Enum.join(", "))
  end

  # ── HTTP indirection (test seam) ──────────────────────────────────────────

  defp http_client,
    do: Application.get_env(:cinegraph, :wikipedia_http_client, HttpClient)
end
