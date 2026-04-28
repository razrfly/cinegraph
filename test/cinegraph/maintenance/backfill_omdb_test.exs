defmodule Cinegraph.Maintenance.BackfillOmdbTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Maintenance.BackfillOmdb
  alias Cinegraph.Movies.{ExternalMetric, Movie}
  alias Cinegraph.Repo

  describe "run/1 (#745 Phase 1.1)" do
    test "dry-run returns count without enqueuing" do
      insert_movie!(omdb: false)

      assert {:ok, %{found: 1, enqueued: 0, failed: 0, dry_run: true}} =
               BackfillOmdb.run(dry_run: true)

      assert omdb_job_count() == 0
    end

    test "enqueues one job per movie missing OMDb metric" do
      insert_movie!(omdb: false)
      insert_movie!(omdb: false)

      assert {:ok, %{found: 2, enqueued: 2, failed: 0, dry_run: false}} = BackfillOmdb.run([])
      assert omdb_job_count() == 2
    end

    test "ignores movies that already have an OMDb external_metric" do
      insert_movie!(omdb: true)
      insert_movie!(omdb: false)

      assert {:ok, %{found: 1}} = BackfillOmdb.run(dry_run: true)
    end

    test "respects :limit cap" do
      Enum.each(1..3, fn _ -> insert_movie!(omdb: false) end)

      assert {:ok, %{found: 2, enqueued: 2}} = BackfillOmdb.run(limit: 2)
    end

    test "raises ArgumentError for non-positive :limit" do
      assert_raise ArgumentError, fn -> BackfillOmdb.run(limit: 0) end
      assert_raise ArgumentError, fn -> BackfillOmdb.run(limit: -1) end
    end
  end

  defp insert_movie!(opts) do
    movie =
      %Movie{}
      |> Movie.changeset(%{
        tmdb_id: System.unique_integer([:positive]),
        title: "Movie #{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    if Keyword.get(opts, :omdb, false) do
      %ExternalMetric{}
      |> ExternalMetric.changeset(%{
        movie_id: movie.id,
        source: "omdb",
        metric_type: "rating_average",
        value: 7.5,
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()
    end

    movie
  end

  defp omdb_job_count do
    import Ecto.Query

    Repo.aggregate(
      from(j in Oban.Job, where: j.worker == "Cinegraph.Workers.OMDbEnrichmentWorker"),
      :count,
      :id
    )
  end
end
