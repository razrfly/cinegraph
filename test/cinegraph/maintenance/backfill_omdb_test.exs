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

    # #993 — movies without imdb_id must be excluded; OMDb has no alternative
    # identifier and these jobs would cycle through the backlog forever.
    test "excludes movies with nil imdb_id" do
      insert_movie!(imdb_id: nil, omdb: false)

      assert {:ok, %{found: 0}} = BackfillOmdb.run(dry_run: true)
    end

    test "excludes movies with blank imdb_id" do
      insert_movie!(imdb_id: "", omdb: false)

      assert {:ok, %{found: 0}} = BackfillOmdb.run(dry_run: true)
    end

    test "includes movies with a valid imdb_id" do
      insert_movie!(imdb_id: "tt1234567", omdb: false)

      assert {:ok, %{found: 1}} = BackfillOmdb.run(dry_run: true)
    end
  end

  # Generate a valid IMDb ID (tt + 7+ digits) matching the format checked by
  # valid_imdb_id?/1 in OMDb.ApiProcessors: ~r/^tt\d{7,}$/
  defp generate_imdb_id do
    n = System.unique_integer([:positive]) |> rem(9_000_000) |> Kernel.+(1_000_000)
    "tt#{n}"
  end

  # opts:
  #   :imdb_id  - explicit IMDb ID (default: auto-generated valid ID; pass nil to test exclusion)
  #   :omdb     - whether to insert a matching external_metrics row (default: false)
  defp insert_movie!(opts) do
    {imdb_id, opts} = Keyword.pop(opts, :imdb_id, generate_imdb_id())

    movie =
      %Movie{}
      |> Movie.changeset(%{
        tmdb_id: System.unique_integer([:positive]),
        title: "Movie #{System.unique_integer([:positive])}",
        imdb_id: imdb_id
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
