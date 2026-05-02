defmodule Cinegraph.Maintenance.RefreshAvailabilityTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Maintenance.RefreshAvailability
  alias Cinegraph.Movies.{Movie, MovieAvailabilityRefresh}
  alias Cinegraph.Repo

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  describe "run/1" do
    test "dry-run counts eligible movies without enqueueing" do
      insert_movie!()

      assert {:ok, %{found: 1, enqueued: 0, failed: 0, dry_run: true}} =
               RefreshAvailability.run(dry_run: true)

      assert Repo.aggregate(Oban.Job, :count, :id) == 0
    end

    test "honors limit and enqueues availability refresh jobs" do
      insert_movie!()
      insert_movie!()

      assert {:ok, %{found: 1, enqueued: 1, failed: 0, dry_run: false}} =
               RefreshAvailability.run(limit: 1)

      [job] = Repo.all(Oban.Job)
      assert job.worker == "Cinegraph.Workers.MovieAvailabilityRefreshWorker"
      refute Map.has_key?(job.args, "regions")
      assert job.args["force"] == false
    end

    test "selects stale refresh rows" do
      movie = insert_movie!()
      insert_refresh!(movie, ~U[2026-01-01 00:00:00Z])

      assert {:ok, %{found: 1, enqueued: 1}} =
               RefreshAvailability.run(now: ~U[2026-05-02 00:00:00Z])
    end

    test "uses requested regions when selecting missing refresh rows" do
      movie = insert_movie!()
      insert_refresh!(movie, ~U[2026-06-01 00:00:00Z], "US")

      assert {:ok, %{found: 1, enqueued: 1}} =
               RefreshAvailability.run(regions: ["CA"], now: ~U[2026-05-02 00:00:00Z])

      [job] = Repo.all(Oban.Job)
      assert job.args["movie_id"] == movie.id
      assert job.args["regions"] == ["CA"]
    end
  end

  defp insert_movie!(attrs \\ %{}) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Refresh Availability Movie",
      original_title: "Refresh Availability Movie",
      import_status: "full"
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_refresh!(movie, stale_after, region \\ "US") do
    %MovieAvailabilityRefresh{}
    |> MovieAvailabilityRefresh.changeset(%{
      movie_id: movie.id,
      region: region,
      source: "tmdb",
      status: "success",
      fetched_at: DateTime.add(stale_after, -30 * 86_400, :second),
      stale_after: stale_after
    })
    |> Repo.insert!()
  end
end
