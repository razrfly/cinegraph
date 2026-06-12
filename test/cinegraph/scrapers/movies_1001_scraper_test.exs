defmodule Cinegraph.Scrapers.Movies1001ScraperTest do
  use ExUnit.Case, async: false

  alias Cinegraph.Scrapers.{FestivalHttpStub, Movies1001Scraper}

  setup do
    FestivalHttpStub.reset!()
    :ok
  end

  defp edition_html(films) do
    items =
      Enum.map_join(films, "\n", fn
        {title, year, nil} ->
          "<li>#{title} (#{year})</li>"

        {title, year, imdb_id} ->
          ~s|<li><a href="https://www.imdb.com/title/#{imdb_id}/">#{title}</a> (#{year})</li>|
      end)

    "<html><body><ul id=\"films\">#{items}</ul></body></html>"
  end

  describe "parse_edition/1" do
    test "extracts title, year, and imdb_id from list items" do
      html = edition_html([{"The Godfather", 1972, "tt0068646"}, {"Solaris", 1972, nil}])
      entries = Movies1001Scraper.parse_edition(html)

      assert %{title: "The Godfather", year: 1972, imdb_id: "tt0068646"} in entries
      assert %{title: "Solaris", year: 1972, imdb_id: nil} in entries
    end
  end

  describe "scrape/1 edition diffing" do
    test "baseline edition adds every film; later editions diff add/remove" do
      e2003 =
        edition_html([{"A Film", 1960, "tt1"}, {"B Film", 1961, "tt2"}, {"C Film", 1962, "tt3"}])

      # B removed, D added
      e2006 =
        edition_html([{"A Film", 1960, "tt1"}, {"C Film", 1962, "tt3"}, {"D Film", 1963, "tt4"}])

      FestivalHttpStub.set_response("/2003", {:ok, e2003})
      FestivalHttpStub.set_response("/2006", {:ok, e2006})

      editions = [{"2003", "https://example.test/2003"}, {"2006", "https://example.test/2006"}]

      assert {:ok, events, %{coverage: coverage}} = Movies1001Scraper.scrape(editions: editions)

      # Baseline 2003: A, B, C added (3). 2006: D added (1), B removed (1).
      adds_2003 = Enum.filter(events, &(&1.event_type == :added and &1.event_edition == "2003"))
      assert length(adds_2003) == 3

      add_2006 = Enum.filter(events, &(&1.event_type == :added and &1.event_edition == "2006"))
      assert [%{raw_title: "D Film"}] = add_2006

      removed = Enum.filter(events, &(&1.event_type == :removed))
      assert [%{raw_title: "B Film", event_edition: "2006"}] = removed

      assert coverage.adds == 4
      assert coverage.removes == 1
      assert coverage.editions_fetched == ["2003", "2006"]
      assert coverage.cross_check == "all_editions_fetched"
    end

    test "diffs by imdb_id even when the title text differs" do
      e1 = edition_html([{"Persona", 1966, "tt0060827"}])
      # Same imdb_id, different title wording → NOT a remove+add churn.
      e2 = edition_html([{"Persona (Bergman)", 1966, "tt0060827"}])

      FestivalHttpStub.set_response("/ed1", {:ok, e1})
      FestivalHttpStub.set_response("/ed2", {:ok, e2})

      editions = [{"2003", "https://example.test/ed1"}, {"2008", "https://example.test/ed2"}]
      {:ok, events, _} = Movies1001Scraper.scrape(editions: editions)

      # Only the 2003 baseline add; no churn in 2008.
      assert Enum.count(events, &(&1.event_type == :added)) == 1
      assert Enum.count(events, &(&1.event_type == :removed)) == 0
    end

    test "a failed edition is skipped and logged as a coverage cap" do
      e2003 = edition_html([{"A Film", 1960, "tt1"}])
      e2010 = edition_html([{"A Film", 1960, "tt1"}, {"E Film", 1965, "tt5"}])

      FestivalHttpStub.set_response("/2003", {:ok, e2003})
      FestivalHttpStub.set_response("/2006", {:error, :forbidden})
      FestivalHttpStub.set_response("/2010", {:ok, e2010})

      editions = [
        {"2003", "https://example.test/2003"},
        {"2006", "https://example.test/2006"},
        {"2010", "https://example.test/2010"}
      ]

      {:ok, events, %{coverage: coverage}} = Movies1001Scraper.scrape(editions: editions)

      # 2006 skipped; diff spans 2003 → 2010 (E added at 2010, no spurious churn).
      assert coverage.editions_fetched == ["2003", "2010"]
      assert [{"2006", _}] = coverage.editions_skipped
      assert coverage.cross_check == "partial_editions"
      assert coverage.cap_reason =~ "2006"
      assert Enum.any?(events, &(&1.raw_title == "E Film" and &1.event_edition == "2010"))
    end

    test "returns an error when no editions are configured" do
      assert {:error, :no_editions_configured} = Movies1001Scraper.scrape(editions: [])
    end
  end
end
