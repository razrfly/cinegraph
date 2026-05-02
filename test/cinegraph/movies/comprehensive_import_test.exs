defmodule Cinegraph.Movies.ComprehensiveImportTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Movies

  alias Cinegraph.Movies.{
    Movie,
    MovieAvailabilityRefresh,
    MovieWatchProvider
  }

  alias Cinegraph.Repo

  describe "store_movie_comprehensive_data/2" do
    test "stores raw TMDb watch providers and normalizes availability" do
      payload = tmdb_payload(watch_payload())

      assert {:ok, %Movie{} = movie} = Movies.store_movie_comprehensive_data(payload)

      movie = Repo.get!(Movie, movie.id)
      assert movie.tmdb_data["watch_providers"] == watch_payload()

      [row] = Repo.all(MovieWatchProvider) |> Repo.preload(:watch_provider)
      assert row.movie_id == movie.id
      assert row.region == "US"
      assert row.monetization_type == "flatrate"
      assert row.tmdb_link == "https://example.test/watch"
      assert row.watch_provider.name == "Netflix"

      [refresh] = Repo.all(MovieAvailabilityRefresh)
      assert refresh.movie_id == movie.id
      assert refresh.region == "US"
      assert refresh.status == "success"
    end

    test "stores movie and records availability error when watch providers are missing" do
      payload = tmdb_payload(nil) |> Map.delete("watch_providers")

      assert {:ok, %Movie{} = movie} = Movies.store_movie_comprehensive_data(payload)

      assert Repo.get!(Movie, movie.id).tmdb_data["watch_providers"] == nil

      [refresh] = Repo.all(MovieAvailabilityRefresh)
      assert refresh.movie_id == movie.id
      assert refresh.status == "error"
      assert refresh.error_reason == "invalid_tmdb_watch_providers_payload"
      assert Repo.aggregate(MovieWatchProvider, :count) == 0
    end

    test "replaces prior availability rows when the same movie is stored again" do
      assert {:ok, movie} =
               Movies.store_movie_comprehensive_data(tmdb_payload(watch_payload(8, "Netflix")))

      assert {:ok, same_movie} =
               Movies.store_movie_comprehensive_data(
                 tmdb_payload(watch_payload(337, "Disney Plus"), title: "Updated Title")
               )

      assert same_movie.id == movie.id

      [row] = Repo.all(MovieWatchProvider) |> Repo.preload(:watch_provider)
      assert row.movie_id == movie.id
      assert row.watch_provider.name == "Disney Plus"

      assert Repo.aggregate(MovieAvailabilityRefresh, :count) == 1
      assert Repo.get!(Movie, movie.id).title == "Updated Title"
    end

    test "availability store errors do not fail comprehensive storage" do
      store_fun = fn _movie, _payload, _opts -> {:error, :availability_failed} end

      assert {:ok, %Movie{} = movie} =
               Movies.store_movie_comprehensive_data(tmdb_payload(watch_payload()),
                 availability_store_fun: store_fun
               )

      assert Repo.get!(Movie, movie.id)
      assert Repo.aggregate(MovieAvailabilityRefresh, :count) == 0
    end

    test "availability store exceptions do not fail comprehensive storage" do
      store_fun = fn _movie, _payload, _opts -> raise "availability exploded" end

      assert {:ok, %Movie{} = movie} =
               Movies.store_movie_comprehensive_data(tmdb_payload(watch_payload()),
                 availability_store_fun: store_fun
               )

      assert Repo.get!(Movie, movie.id)
      assert Repo.aggregate(MovieAvailabilityRefresh, :count) == 0
    end
  end

  defp tmdb_payload(watch_providers, opts \\ []) do
    title = Keyword.get(opts, :title, "Comprehensive Availability Movie")

    %{
      "id" => 880_001,
      "title" => title,
      "original_title" => title,
      "release_date" => "2026-05-02",
      "runtime" => 100,
      "overview" => "A focused test payload.",
      "tagline" => nil,
      "original_language" => "en",
      "status" => "Released",
      "adult" => false,
      "homepage" => nil,
      "poster_path" => nil,
      "backdrop_path" => nil,
      "origin_country" => ["US"],
      "vote_average" => 7.5,
      "vote_count" => 100,
      "popularity" => 12.0,
      "watch_providers" => watch_providers
    }
  end

  defp watch_payload(provider_id \\ 8, provider_name \\ "Netflix") do
    %{
      "results" => %{
        "US" => %{
          "link" => "https://example.test/watch",
          "flatrate" => [
            %{
              "provider_id" => provider_id,
              "provider_name" => provider_name,
              "logo_path" => "/provider-#{provider_id}.jpg",
              "display_priority" => 1
            }
          ]
        }
      }
    }
  end
end
