defmodule Cinegraph.Scrapers.NfrScraperTest do
  use ExUnit.Case, async: false

  alias Cinegraph.Scrapers.{FestivalHttpStub, NfrScraper}

  setup do
    FestivalHttpStub.reset!()
    :ok
  end

  # Wikipedia wikitable: Title | Type | Year released | Year inducted.
  # Includes "2001: A Space Odyssey" to exercise the year-in-title guard.
  defp wikipedia_html do
    """
    <html><body>
    <table class="wikitable sortable">
      <tr><th>Film</th><th>Type</th><th>Year released</th><th>Year inducted</th></tr>
      <tr><td>"Casablanca"</td><td>Narrative feature</td><td>1942</td><td>1989</td></tr>
      <tr><td>"2001: A Space Odyssey"</td><td>Narrative feature</td><td>1968</td><td>1991</td></tr>
      <tr><td>"12 Angry Men"[1]</td><td>Narrative feature</td><td>1957</td><td>2007</td></tr>
    </table>
    </body></html>
    """
  end

  # loc.gov listing: Title | Year of Release | Year Inducted. The title is a
  # row-scope <th> (not a <td>) — exactly as loc.gov renders it.
  defp loc_html do
    """
    <html><body>
    <table>
      <tr><th>Film Title</th><th>Year of Release</th><th>Year Inducted</th></tr>
      <tr><th>Casablanca</th><td>1942</td><td>1989</td></tr>
      <tr><th>2001: A Space Odyssey</th><td>1968</td><td>1991</td></tr>
    </table>
    </body></html>
    """
  end

  describe "scrape/0 with cross-check" do
    test "produces one :added event per film with the induction year as edition" do
      FestivalHttpStub.set_response("National_Film_Registry", {:ok, wikipedia_html()})
      FestivalHttpStub.set_response("loc.gov", {:ok, loc_html()})

      assert {:ok, events, %{coverage: coverage}} = NfrScraper.scrape()
      assert length(events) == 3

      casablanca = Enum.find(events, &(&1.raw_title == "Casablanca"))
      assert casablanca.event_type == :added
      assert casablanca.event_edition == "nfr_1989"
      assert casablanca.raw_year == 1942
      assert casablanca.raw_imdb_id == nil

      assert coverage.cross_check == "loc+wikipedia"
      assert coverage.events_found == 3
    end

    test "does not let a year embedded in the title pollute the induction year" do
      FestivalHttpStub.set_response("National_Film_Registry", {:ok, wikipedia_html()})
      FestivalHttpStub.set_response("loc.gov", {:ok, loc_html()})

      {:ok, events, _} = NfrScraper.scrape()
      odyssey = Enum.find(events, &(&1.raw_title == "2001: A Space Odyssey"))

      assert odyssey.raw_year == 1968
      assert odyssey.event_edition == "nfr_1991"
    end

    test "strips footnote markers from titles" do
      FestivalHttpStub.set_response("National_Film_Registry", {:ok, wikipedia_html()})
      FestivalHttpStub.set_response("loc.gov", {:ok, loc_html()})

      {:ok, events, _} = NfrScraper.scrape()
      assert Enum.any?(events, &(&1.raw_title == "12 Angry Men"))
    end
  end

  describe "degradation" do
    test "succeeds with a coverage cap when loc.gov is unavailable" do
      FestivalHttpStub.set_response("National_Film_Registry", {:ok, wikipedia_html()})
      FestivalHttpStub.set_response("loc.gov", {:error, :forbidden})

      assert {:ok, events, %{coverage: coverage}} = NfrScraper.scrape()
      assert length(events) == 3
      assert coverage.cross_check == "wikipedia_only"
      assert coverage.cap_reason =~ "loc.gov unavailable"
    end

    test "errors when the primary Wikipedia fetch fails" do
      FestivalHttpStub.set_response("National_Film_Registry", {:error, :forbidden})

      assert {:error, :forbidden} = NfrScraper.scrape()
    end
  end
end
