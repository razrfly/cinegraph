defmodule Cinegraph.Scrapers.UnifiedFestivalScraperTest do
  # DataCase (instead of ExUnit.Case) is required for fetch_festival_data/2
  # tests, which query the DB for the festival event record.
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Events.FestivalEvent
  alias Cinegraph.Repo
  alias Cinegraph.Scrapers.{FestivalHttpStub, UnifiedFestivalScraper}

  setup do
    FestivalHttpStub.reset!()
    :ok
  end

  # ---------------------------------------------------------------------------
  # build_candidate_years/2
  # ---------------------------------------------------------------------------

  describe "build_candidate_years/2" do
    test "current year is first when no hint given" do
      [first | _] = UnifiedFestivalScraper.build_candidate_years(nil)
      assert first == Date.utc_today().year
    end

    test "descends from current year" do
      current = Date.utc_today().year
      candidates = UnifiedFestivalScraper.build_candidate_years(nil, 5)
      assert candidates == [current, current - 1, current - 2, current - 3, current - 4]
    end

    test "respects max_attempts cap" do
      assert length(UnifiedFestivalScraper.build_candidate_years(nil, 5)) == 5
      assert length(UnifiedFestivalScraper.build_candidate_years(nil, 10)) == 10
    end

    test "known_good_year is placed first" do
      candidates = UnifiedFestivalScraper.build_candidate_years(2018)
      assert hd(candidates) == 2018
    end

    test "known_good_year is not duplicated in the list" do
      current = Date.utc_today().year
      candidates = UnifiedFestivalScraper.build_candidate_years(current)
      assert Enum.count(candidates, &(&1 == current)) == 1
    end

    test "known_good_year outside the base window is prepended and capped at max_attempts" do
      candidates = UnifiedFestivalScraper.build_candidate_years(1999, 5)
      assert hd(candidates) == 1999
      assert length(candidates) == 5
    end
  end

  # ---------------------------------------------------------------------------
  # extract_available_years/2  (pure parsing — no HTTP)
  # ---------------------------------------------------------------------------

  describe "extract_available_years/2" do
    test "extracts and sorts years from valid __NEXT_DATA__" do
      html = next_data_html([2022, 2024, 2023])
      assert {:ok, years} = UnifiedFestivalScraper.extract_available_years(html, "ev0000001")
      assert years == [2024, 2023, 2022]
    end

    test "returns error for empty historyEventEditions" do
      html = next_data_html([])
      assert {:error, _} = UnifiedFestivalScraper.extract_available_years(html, "ev0000001")
    end

    test "returns error when __NEXT_DATA__ is absent" do
      html = "<html><body><p>Nothing here</p></body></html>"

      assert {:error, "No __NEXT_DATA__ found"} =
               UnifiedFestivalScraper.extract_available_years(html, "ev0000001")
    end

    test "returns error for malformed JSON" do
      html =
        ~s(<html><body><script id="__NEXT_DATA__" type="application/json">{bad json</script></body></html>)

      assert {:error, "JSON parsing failed"} =
               UnifiedFestivalScraper.extract_available_years(html, "ev0000001")
    end
  end

  # ---------------------------------------------------------------------------
  # fetch_available_years/2  (fallback chain — uses HTTP stub)
  # ---------------------------------------------------------------------------

  describe "fetch_available_years/2 fallback chain" do
    test "happy path: major festival hits current year on first attempt" do
      current = Date.utc_today().year
      years = Enum.to_list(2000..current)
      FestivalHttpStub.set_response("/#{current}/", {:ok, next_data_html(years)})

      assert {:ok, result} = UnifiedFestivalScraper.fetch_available_years("ev0000147")
      assert length(result) > 20
    end

    test "falls through 403 to find a valid earlier year" do
      current = Date.utc_today().year
      FestivalHttpStub.set_response("/#{current}/", {:error, :forbidden})

      FestivalHttpStub.set_response(
        "/#{current - 1}/",
        {:ok, next_data_html([current - 1, current - 2, current - 3])}
      )

      assert {:ok, years} = UnifiedFestivalScraper.fetch_available_years("ev0000001")
      assert (current - 1) in years
    end

    test "falls through empty editions to find a valid earlier year" do
      current = Date.utc_today().year
      FestivalHttpStub.set_response("/#{current}/", {:ok, next_data_html([])})

      FestivalHttpStub.set_response(
        "/#{current - 1}/",
        {:ok, next_data_html([current - 1, current - 2])}
      )

      assert {:ok, years} = UnifiedFestivalScraper.fetch_available_years("ev0000001")
      assert (current - 1) in years
    end

    test "falls through missing __NEXT_DATA__ to find a valid earlier year" do
      current = Date.utc_today().year
      FestivalHttpStub.set_response("/#{current}/", {:ok, "<html><body></body></html>"})

      FestivalHttpStub.set_response(
        "/#{current - 1}/",
        {:ok, next_data_html([current - 1, current - 2])}
      )

      assert {:ok, years} = UnifiedFestivalScraper.fetch_available_years("ev0000001")
      assert (current - 1) in years
    end

    test "exhausting all candidates returns :no_year_with_editions" do
      assert {:error, :no_year_with_editions} =
               UnifiedFestivalScraper.fetch_available_years("ev0000001", max_attempts: 3)
    end

    # #994 — IMDb event pages require JS rendering to bypass Cloudflare WAF.
    # Verify the stub receives mode: :javascript so the correct Crawlbase API
    # key (JS) is used in production.
    test "passes mode: :javascript to the HTTP client" do
      current = Date.utc_today().year
      FestivalHttpStub.set_response("/#{current}/", {:ok, next_data_html([current, current - 1])})

      assert {:ok, _years} = UnifiedFestivalScraper.fetch_available_years("ev0000147")

      assert FestivalHttpStub.last_opts() |> Keyword.get(:mode) == :javascript
    end

    test "known_good_year hint is tried first and short-circuits" do
      FestivalHttpStub.set_response("/2018/", {:ok, next_data_html([2018, 2017, 2016])})

      assert {:ok, years} =
               UnifiedFestivalScraper.fetch_available_years("ev0000001",
                 known_good_year: 2018,
                 max_attempts: 3
               )

      assert 2018 in years
    end

    test "falls through to base candidates when known_good_year hint itself fails" do
      current = Date.utc_today().year
      # hint fails; chain must continue to base candidates and find current year
      FestivalHttpStub.set_response("/2018/", {:error, :forbidden})

      FestivalHttpStub.set_response(
        "/#{current}/",
        {:ok, next_data_html([current - 1, current - 2])}
      )

      assert {:ok, years} =
               UnifiedFestivalScraper.fetch_available_years("ev0000001",
                 known_good_year: 2018,
                 max_attempts: 3
               )

      assert (current - 1) in years
    end
  end

  # ---------------------------------------------------------------------------
  # fetch_festival_data/2  (uses HTTP stub via http_client/0 injection)
  # ---------------------------------------------------------------------------

  describe "fetch_festival_data/2" do
    # ApiTracker.track_lookup/5 spawns a Task to write metrics. The shared
    # sandbox mode lets that task use the test's DB connection rather than
    # failing with a DBConnection.ConnectionError.
    setup do
      Ecto.Adapters.SQL.Sandbox.mode(Cinegraph.Repo, {:shared, self()})
      :ok
    end

    # #994 — both IMDb event-page fetch paths must use mode: :javascript.
    # This test verifies the festival-import path mirrors the year-discovery path.
    test "passes mode: :javascript to the HTTP client" do
      # source_config must carry "event_id" — to_scraper_config/1 reads from
      # there, not from the top-level imdb_event_id column.
      event_id = "ev0000147"
      year = 2024

      festival =
        insert_festival!(
          source_key: "cannes_test",
          imdb_event_id: event_id,
          source_config: %{"event_id" => event_id, "imdb_event_id" => event_id}
        )

      # Stub the URL build_festival_url/2 will construct.
      FestivalHttpStub.set_response(
        "/event/#{event_id}/#{year}/",
        {:ok, next_data_html([year, year - 1])}
      )

      # The result may be a parse error (we haven't stubbed full award HTML),
      # but we only need to verify the fetch opts — the stub records them
      # regardless of what the parser does with the response.
      UnifiedFestivalScraper.fetch_festival_data(festival.source_key, year)

      assert FestivalHttpStub.last_opts() |> Keyword.get(:mode) == :javascript
    end
  end

  # ---------------------------------------------------------------------------
  # Integration (opt-in only — hits live Crawlbase)
  # ---------------------------------------------------------------------------

  describe "integration: New Horizons (ev0002561)" do
    @describetag :integration
    @describetag timeout: 300_000

    setup do
      saved = Application.get_env(:cinegraph, :festival_http_client)
      Application.put_env(:cinegraph, :festival_http_client, Cinegraph.Scrapers.Http.Client)
      on_exit(fn -> Application.put_env(:cinegraph, :festival_http_client, saved) end)
      :ok
    end

    test "returns >= 10 years via live Crawlbase fallback" do
      assert {:ok, years} = UnifiedFestivalScraper.fetch_available_years("ev0002561")
      assert length(years) >= 10
    end
  end

  describe "integration: Locarno (ev0000400)" do
    @describetag :integration
    @describetag timeout: 300_000

    setup do
      saved = Application.get_env(:cinegraph, :festival_http_client)
      Application.put_env(:cinegraph, :festival_http_client, Cinegraph.Scrapers.Http.Client)
      on_exit(fn -> Application.put_env(:cinegraph, :festival_http_client, saved) end)
      :ok
    end

    test "returns >= 10 years via live Crawlbase fallback" do
      assert {:ok, years} = UnifiedFestivalScraper.fetch_available_years("ev0000400")
      assert length(years) >= 10
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_festival!(opts) do
    %FestivalEvent{}
    |> FestivalEvent.changeset(%{
      source_key: Keyword.fetch!(opts, :source_key),
      name: Keyword.get(opts, :name, "Test Festival #{Keyword.fetch!(opts, :source_key)}"),
      imdb_event_id: Keyword.get(opts, :imdb_event_id),
      source_config: Keyword.get(opts, :source_config, %{}),
      active: true,
      primary_source: "imdb"
    })
    |> Repo.insert!()
  end

  defp next_data_html(years) do
    editions = Enum.map(years, &%{"year" => &1})

    json =
      Jason.encode!(%{
        "props" => %{"pageProps" => %{"historyEventEditions" => editions}}
      })

    ~s(<html><body><script id="__NEXT_DATA__" type="application/json">#{json}</script></body></html>)
  end
end
