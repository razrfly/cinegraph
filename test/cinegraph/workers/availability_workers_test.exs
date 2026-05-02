defmodule Cinegraph.Workers.AvailabilityWorkersTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Movies.{Availability, Movie, MovieAvailabilityRefresh, MovieWatchProvider}
  alias Cinegraph.Repo

  alias Cinegraph.Workers.{
    AvailabilityRefreshSweeper,
    MovieAvailabilityRefreshWorker,
    WatchProviderCatalogRefreshWorker
  }

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  describe "MovieAvailabilityRefreshWorker.refresh_movie/2" do
    test "fetches TMDb payload and stores normalized rows" do
      movie = insert_movie!()

      assert {:ok, %{status: "refreshed"}} =
               MovieAvailabilityRefreshWorker.refresh_movie(movie,
                 fetch_fun: fn _tmdb_id -> {:ok, watch_payload()} end
               )

      assert Repo.aggregate(MovieWatchProvider, :count) == 1
      assert Repo.one(MovieAvailabilityRefresh).status == "success"
    end

    test "skips fresh rows when not forced" do
      movie = insert_movie!()
      assert {:ok, _} = Availability.store_tmdb_watch_providers(movie, watch_payload())

      assert {:ok, %{status: "fresh"}} =
               MovieAvailabilityRefreshWorker.refresh_movie(movie,
                 fetch_fun: fn _tmdb_id -> raise "should not fetch" end
               )
    end

    test "refreshes fresh rows when forced" do
      movie = insert_movie!()

      assert {:ok, _} =
               Availability.store_tmdb_watch_providers(movie, watch_payload(8, "Netflix"))

      assert {:ok, %{status: "refreshed"}} =
               MovieAvailabilityRefreshWorker.refresh_movie(movie,
                 force: true,
                 fetch_fun: fn _tmdb_id -> {:ok, watch_payload(337, "Disney Plus")} end
               )

      [row] = Repo.all(MovieWatchProvider) |> Repo.preload(:watch_provider)
      assert row.watch_provider.name == "Disney Plus"
    end

    test "writes error refresh rows on TMDb errors" do
      movie = insert_movie!()

      assert {:ok, %{status: "error"}} =
               MovieAvailabilityRefreshWorker.refresh_movie(movie,
                 fetch_fun: fn _tmdb_id -> {:error, :rate_limited} end
               )

      refresh = Repo.one(MovieAvailabilityRefresh)
      assert refresh.status == "error"
      assert refresh.error_reason =~ "rate_limited"
    end
  end

  describe "WatchProviderCatalogRefreshWorker.refresh_catalog/1" do
    test "runs provider and region sync paths" do
      stats =
        WatchProviderCatalogRefreshWorker.refresh_catalog(
          provider_fetch_fun: fn [watch_region: "US"] ->
            {:ok, %{"results" => [provider(8, "Netflix")]}}
          end,
          region_fetch_fun: fn ->
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
        )

      assert stats == %{providers: 1, regions: 1}
    end
  end

  describe "AvailabilityRefreshSweeper.perform/1" do
    test "returns zero stats on empty DB" do
      assert {:ok, %{found: 0, enqueued: 0, failed: 0, dry_run: false}} =
               AvailabilityRefreshSweeper.perform(%Oban.Job{})
    end
  end

  defp insert_movie!(attrs \\ %{}) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Availability Worker Movie",
      original_title: "Availability Worker Movie",
      import_status: "full"
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp watch_payload(provider_id \\ 8, provider_name \\ "Netflix") do
    %{
      "results" => %{
        "US" => %{
          "link" => "https://example.test/watch",
          "flatrate" => [provider(provider_id, provider_name)]
        }
      }
    }
  end

  defp provider(id, name) do
    %{
      "provider_id" => id,
      "provider_name" => name,
      "logo_path" => "/provider-#{id}.jpg",
      "display_priority" => 1
    }
  end
end
