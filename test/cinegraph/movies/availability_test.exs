defmodule Cinegraph.Movies.AvailabilityTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Movies.{
    Availability,
    Movie,
    MovieAvailabilityRefresh,
    MovieWatchProvider,
    WatchProvider,
    WatchProviderRegion
  }

  alias Cinegraph.Repo

  describe "store_tmdb_watch_providers/3" do
    test "stores every TMDb monetization type and the region link" do
      movie = insert_movie!()
      fetched_at = ~U[2026-05-02 12:00:00Z]

      assert {:ok, [%{status: "success"}]} =
               Availability.store_tmdb_watch_providers(movie, watch_payload(),
                 fetched_at: fetched_at
               )

      rows =
        MovieWatchProvider
        |> Repo.all()
        |> Repo.preload(:watch_provider)

      assert rows |> Enum.map(& &1.monetization_type) |> Enum.sort() ==
               ~w(ads buy flatrate free rent)

      assert Enum.all?(rows, &(&1.region == "US"))
      assert Enum.all?(rows, &(&1.source == "tmdb"))

      assert Enum.all?(
               rows,
               &(&1.tmdb_link == "https://www.themoviedb.org/movie/1/watch?locale=US")
             )

      assert Enum.all?(rows, &(&1.fetched_at == fetched_at))
      assert Enum.all?(rows, &(&1.stale_after == ~U[2026-06-01 12:00:00Z]))

      assert Enum.map(rows, & &1.watch_provider.name) |> Enum.sort() == [
               "Amazon Video",
               "Hoopla",
               "Netflix",
               "Pluto TV",
               "YouTube"
             ]
    end

    test "reuses one provider row across multiple monetization types" do
      movie = insert_movie!()

      payload = %{
        "results" => %{
          "US" => %{
            "link" => "https://example.test/watch",
            "rent" => [provider(10, "Amazon Video", 6)],
            "buy" => [provider(10, "Amazon Video", 6)]
          }
        }
      }

      assert {:ok, [%{status: "success"}]} =
               Availability.store_tmdb_watch_providers(movie, payload)

      assert Repo.aggregate(WatchProvider, :count) == 1
      assert Repo.aggregate(MovieWatchProvider, :count) == 2

      provider = Repo.one(WatchProvider)
      rows = Repo.all(MovieWatchProvider)
      assert Enum.all?(rows, &(&1.watch_provider_id == provider.id))
    end

    test "creates a success refresh row when provider rows exist" do
      movie = insert_movie!()

      assert {:ok, [%{status: "success", refresh: refresh}]} =
               Availability.store_tmdb_watch_providers(movie, watch_payload())

      assert refresh.status == "success"
      assert refresh.region == "US"
      assert refresh.source == "tmdb"
      assert refresh.tmdb_link == "https://www.themoviedb.org/movie/1/watch?locale=US"
      assert Repo.aggregate(MovieAvailabilityRefresh, :count) == 1
    end

    test "creates a no_results refresh row when selected region is missing" do
      movie = insert_movie!()

      assert {:ok, [%{status: "no_results", refresh: refresh, availabilities: []}]} =
               Availability.store_tmdb_watch_providers(movie, %{"results" => %{"CA" => %{}}})

      assert refresh.status == "no_results"
      assert refresh.region == "US"
      assert refresh.error_reason == nil
      assert Repo.aggregate(MovieWatchProvider, :count) == 0
    end

    test "creates a no_results refresh row when selected region is empty" do
      movie = insert_movie!()

      assert {:ok, [%{status: "no_results", refresh: refresh, availabilities: []}]} =
               Availability.store_tmdb_watch_providers(movie, %{
                 "results" => %{"US" => %{"link" => "https://example.test/watch"}}
               })

      assert refresh.status == "no_results"
      assert refresh.tmdb_link == "https://example.test/watch"
      assert Repo.aggregate(MovieWatchProvider, :count) == 0
    end

    test "creates an error refresh row for invalid payloads" do
      movie = insert_movie!()

      assert {:ok, [%{status: "error", refresh: refresh, availabilities: []}]} =
               Availability.store_tmdb_watch_providers(movie, %{})

      assert refresh.status == "error"
      assert refresh.error_reason == "invalid_tmdb_watch_providers_payload"
      assert Repo.aggregate(MovieWatchProvider, :count) == 0
    end

    test "ignores malformed provider rows when valid provider rows also exist" do
      movie = insert_movie!()

      payload = %{
        "results" => %{
          "US" => %{
            "link" => "https://example.test/watch",
            "flatrate" => [
              %{"provider_id" => nil, "provider_name" => "Broken"},
              %{"provider_id" => 8},
              provider(8, "Netflix", 3)
            ]
          }
        }
      }

      assert {:ok, [%{status: "success", refresh: refresh}]} =
               Availability.store_tmdb_watch_providers(movie, payload)

      rows = Repo.all(MovieWatchProvider) |> Repo.preload(:watch_provider)
      assert length(rows) == 1
      assert hd(rows).watch_provider.name == "Netflix"
      assert refresh.error_reason == nil
    end

    test "all malformed provider rows produce an error refresh and no availability rows" do
      movie = insert_movie!()

      payload = %{
        "results" => %{
          "US" => %{
            "link" => "https://example.test/watch",
            "flatrate" => [
              %{"provider_id" => nil, "provider_name" => "Broken"},
              %{"provider_id" => 8}
            ]
          }
        }
      }

      assert {:ok, [%{status: "error", refresh: refresh, availabilities: []}]} =
               Availability.store_tmdb_watch_providers(movie, payload)

      assert refresh.error_reason == "invalid_provider_entries"
      assert Repo.aggregate(MovieWatchProvider, :count) == 0
    end

    test "second store replaces current rows for the same movie region and source" do
      movie = insert_movie!()

      assert {:ok, [%{status: "success"}]} =
               Availability.store_tmdb_watch_providers(movie, watch_payload())

      assert Repo.aggregate(MovieWatchProvider, :count) == 5

      second_payload = %{
        "results" => %{
          "US" => %{
            "link" => "https://example.test/new-watch",
            "flatrate" => [provider(337, "Disney Plus", 1)]
          }
        }
      }

      assert {:ok, [%{status: "success"}]} =
               Availability.store_tmdb_watch_providers(movie, second_payload)

      rows = Repo.all(MovieWatchProvider) |> Repo.preload(:watch_provider)
      assert length(rows) == 1
      assert hd(rows).watch_provider.name == "Disney Plus"
      assert hd(rows).tmdb_link == "https://example.test/new-watch"
      assert Repo.aggregate(MovieAvailabilityRefresh, :count) == 1
    end
  end

  describe "catalog and refresh helpers" do
    test "sync_provider_catalog! upserts providers and merges display priorities by region" do
      fetched_at = ~U[2026-05-02 12:00:00Z]

      fetch_fun = fn
        [watch_region: "US"] ->
          {:ok, %{"results" => [provider(8, "Netflix", 3)]}}

        [watch_region: "CA"] ->
          {:ok, %{"results" => [provider(8, "Netflix", 7)]}}
      end

      assert [_us, _ca] =
               Availability.sync_provider_catalog!(
                 regions: ["US", "CA"],
                 fetched_at: fetched_at,
                 fetch_fun: fetch_fun
               )

      assert Repo.aggregate(WatchProvider, :count) == 1

      provider = Repo.one(WatchProvider)
      assert provider.source_provider_id == "8"
      assert provider.tmdb_provider_id == 8
      assert provider.display_priorities == %{"US" => 3, "CA" => 7}
      assert provider.last_seen_at == fetched_at
    end

    test "sync_regions! upserts supported regions" do
      fetched_at = ~U[2026-05-02 12:00:00Z]

      fetch_fun = fn ->
        {:ok,
         %{
           "results" => [
             %{
               "iso_3166_1" => "US",
               "english_name" => "United States of America",
               "native_name" => "United States"
             }
           ]
         }}
      end

      assert [_region] = Availability.sync_regions!(fetched_at: fetched_at, fetch_fun: fetch_fun)

      region = Repo.one(WatchProviderRegion)
      assert region.iso_3166_1 == "US"
      assert region.english_name == "United States of America"
      assert region.last_seen_at == fetched_at
    end

    test "record_availability_error writes error refresh rows" do
      movie = insert_movie!()

      assert {:ok, [refresh]} =
               Availability.record_availability_error(movie, ["US"], {:api_error, 500},
                 fetched_at: ~U[2026-05-02 12:00:00Z]
               )

      assert refresh.status == "error"
      assert refresh.error_reason =~ "api_error"
      assert refresh.stale_after == ~U[2026-06-01 12:00:00Z]
    end
  end

  describe "availability read APIs" do
    test "list_movie_availability/3 returns grouped rows sorted by display priority" do
      movie = insert_movie!()

      payload = %{
        "results" => %{
          "US" => %{
            "link" => "https://example.test/watch",
            "flatrate" => [
              provider(9, "Prime Video", 9),
              provider(8, "Netflix", 1)
            ],
            "rent" => [provider(10, "Amazon Video", 4)]
          }
        }
      }

      assert {:ok, _} = Availability.store_tmdb_watch_providers(movie, payload)

      groups = Availability.list_movie_availability(movie.id, "US")

      assert Enum.map(groups["flatrate"], & &1.watch_provider.name) == ["Netflix", "Prime Video"]
      assert Enum.map(groups["rent"], & &1.watch_provider.name) == ["Amazon Video"]
      assert groups["free"] == []
    end

    test "availability_freshness/3 returns refresh row or nil" do
      movie = insert_movie!()
      assert Availability.availability_freshness(movie.id, "US") == nil

      assert {:ok, _} = Availability.store_tmdb_watch_providers(movie, watch_payload())

      assert %MovieAvailabilityRefresh{status: "success"} =
               Availability.availability_freshness(movie.id, "US")
    end

    test "availability_refresh_queued?/2 detects active matching Oban jobs" do
      Repo.delete_all(Oban.Job)
      movie = insert_movie!()

      refute Availability.availability_refresh_queued?(movie.id, "US")

      %{"movie_id" => movie.id, "regions" => ["US"], "force" => true}
      |> Cinegraph.Workers.MovieAvailabilityRefreshWorker.new()
      |> Oban.insert!()

      assert Availability.availability_refresh_queued?(movie.id, "US")
      refute Availability.availability_refresh_queued?(movie.id, "CA")
    end
  end

  describe "changeset validations" do
    test "watch provider rejects invalid sources" do
      changeset =
        WatchProvider.changeset(%WatchProvider{}, %{
          source: "unknown",
          source_provider_id: "1",
          name: "Unknown"
        })

      assert "is invalid" in errors_on(changeset).source
    end

    test "availability refresh rejects invalid statuses" do
      changeset =
        MovieAvailabilityRefresh.changeset(%MovieAvailabilityRefresh{}, %{
          movie_id: 1,
          region: "US",
          source: "tmdb",
          status: "stale",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
          stale_after: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert "is invalid" in errors_on(changeset).status
    end

    test "movie watch provider rejects invalid monetization types" do
      changeset =
        MovieWatchProvider.changeset(%MovieWatchProvider{}, %{
          movie_id: 1,
          watch_provider_id: 1,
          region: "US",
          monetization_type: "subscription",
          source: "tmdb",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
          stale_after: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert "is invalid" in errors_on(changeset).monetization_type
    end
  end

  defp insert_movie!(attrs \\ %{}) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Availability Test Movie",
      original_title: "Availability Test Movie",
      import_status: "full"
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp watch_payload do
    %{
      "results" => %{
        "US" => %{
          "link" => "https://www.themoviedb.org/movie/1/watch?locale=US",
          "flatrate" => [provider(8, "Netflix", 3)],
          "free" => [provider(212, "Hoopla", 34)],
          "ads" => [provider(300, "Pluto TV", 73)],
          "rent" => [provider(10, "Amazon Video", 6)],
          "buy" => [provider(192, "YouTube", 17)]
        }
      }
    }
  end

  defp provider(id, name, priority) do
    %{
      "provider_id" => id,
      "provider_name" => name,
      "logo_path" => "/provider-#{id}.jpg",
      "display_priority" => priority
    }
  end
end
