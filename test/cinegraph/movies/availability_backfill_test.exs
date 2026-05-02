defmodule Cinegraph.Movies.AvailabilityBackfillTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Movies.{
    Availability,
    AvailabilityBackfill,
    Movie,
    MovieAvailabilityRefresh,
    MovieWatchProvider
  }

  alias Cinegraph.Repo

  describe "run/1" do
    test "dry-run counts eligible movies without inserting rows" do
      insert_movie!(%{tmdb_data: %{"watch_providers" => watch_payload()}})
      insert_movie!(%{tmdb_data: %{"watch_providers" => no_results_payload()}})

      assert {:ok, stats} = AvailabilityBackfill.run(dry_run: true)

      assert stats.processed == 2
      assert stats.success == 1
      assert stats.no_results == 1
      assert stats.error == 0
      assert stats.skipped == 0
      assert stats.dry_run == true
      assert Repo.aggregate(MovieAvailabilityRefresh, :count) == 0
      assert Repo.aggregate(MovieWatchProvider, :count) == 0
    end

    test "limited run processes only the requested number of eligible movies" do
      first = insert_movie!(%{tmdb_data: %{"watch_providers" => watch_payload()}})
      insert_movie!(%{tmdb_data: %{"watch_providers" => watch_payload(337, "Disney Plus")}})

      assert {:ok, stats} = AvailabilityBackfill.run(limit: 1)

      assert stats.processed == 1
      assert stats.success == 1
      assert stats.last_id == first.id
      assert Repo.aggregate(MovieAvailabilityRefresh, :count) == 1
      assert Repo.aggregate(MovieWatchProvider, :count) == 1
    end

    test "after_id resumes after a known movie id" do
      first = insert_movie!(%{tmdb_data: %{"watch_providers" => watch_payload(8, "Netflix")}})

      second =
        insert_movie!(%{tmdb_data: %{"watch_providers" => watch_payload(337, "Disney Plus")}})

      assert {:ok, stats} = AvailabilityBackfill.run(after_id: first.id)

      assert stats.processed == 1
      assert stats.success == 1
      assert stats.last_id == second.id

      [row] = Repo.all(MovieWatchProvider) |> Repo.preload(:watch_provider)
      assert row.movie_id == second.id
      assert row.watch_provider.name == "Disney Plus"
    end

    test "movies without watch-provider JSON are skipped by selection" do
      insert_movie!(%{tmdb_data: %{}})
      insert_movie!(%{tmdb_data: %{"watch_providers" => watch_payload()}})

      assert {:ok, stats} = AvailabilityBackfill.run()

      assert stats.processed == 1
      assert stats.success == 1
      assert stats.skipped == 0
      assert Repo.aggregate(MovieAvailabilityRefresh, :count) == 1
    end

    test "already-normalized movie region rows are skipped" do
      movie = insert_movie!(%{tmdb_data: %{"watch_providers" => watch_payload()}})
      assert {:ok, _results} = Availability.store_tmdb_watch_providers(movie, watch_payload())

      assert {:ok, stats} = AvailabilityBackfill.run()

      assert stats.processed == 0
      assert stats.success == 0
      assert stats.skipped == 1
      assert stats.last_id == movie.id
      assert Repo.aggregate(MovieAvailabilityRefresh, :count) == 1
      assert Repo.aggregate(MovieWatchProvider, :count) == 1
    end

    test "stats include last_id for the last inspected eligible movie" do
      first = insert_movie!(%{tmdb_data: %{"watch_providers" => no_results_payload()}})
      second = insert_movie!(%{tmdb_data: %{"watch_providers" => watch_payload()}})

      assert {:ok, stats} = AvailabilityBackfill.run(batch_size: 1)

      assert stats.processed == 2
      assert stats.no_results == 1
      assert stats.success == 1
      assert stats.last_id == second.id
      assert first.id < stats.last_id
    end
  end

  defp insert_movie!(attrs) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Availability Backfill Movie",
      original_title: "Availability Backfill Movie",
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

  defp no_results_payload do
    %{"results" => %{"US" => %{"link" => "https://example.test/watch"}}}
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
