defmodule Cinegraph.Maintenance.RepairImdbIdsTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Maintenance.RepairImdbIds
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  describe "run/1 (#745 Phase 1.2)" do
    test "dry-run returns count without enqueuing" do
      insert_movie!(imdb_id: nil)

      assert {:ok, %{found: 1, enqueued: 0, failed: 0, dry_run: true}} =
               RepairImdbIds.run(dry_run: true)

      assert tmdb_details_job_count() == 0
    end

    test "enqueues one job per movie missing imdb_id" do
      insert_movie!(imdb_id: nil)
      insert_movie!(imdb_id: "")

      assert {:ok, %{found: 2, enqueued: 2}} = RepairImdbIds.run([])
      assert tmdb_details_job_count() == 2
    end

    test "ignores movies that already have an imdb_id" do
      insert_movie!(imdb_id: "tt0000001")

      assert {:ok, %{found: 0}} = RepairImdbIds.run(dry_run: true)
    end

    # Note: `movies.tmdb_id` is NOT NULL at the DB level, so the
    # "ignores movies without tmdb_id" branch is structurally unreachable.
    # The query keeps the predicate defensively in case the constraint is
    # ever relaxed.

    test "skips movies already marked imdb_id source-absent (#1109)" do
      marked = insert_movie!(imdb_id: nil)
      _unmarked = insert_movie!(imdb_id: nil)
      Cinegraph.Freshness.touch("movie", marked.id, "imdb_id", :empty)

      # only the unmarked null-id movie is selected for repair
      assert {:ok, %{found: 1}} = RepairImdbIds.run(dry_run: true)
    end

    test "respects :limit cap" do
      Enum.each(1..3, fn _ -> insert_movie!(imdb_id: nil) end)

      assert {:ok, %{found: 2}} = RepairImdbIds.run(limit: 2, dry_run: true)
    end

    test "raises ArgumentError for non-positive :limit" do
      assert_raise ArgumentError, fn -> RepairImdbIds.run(limit: 0) end
    end
  end

  defp insert_movie!(opts) do
    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      imdb_id: Keyword.get(opts, :imdb_id),
      title: "Movie #{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp tmdb_details_job_count do
    import Ecto.Query

    Repo.aggregate(
      from(j in Oban.Job, where: j.worker == "Cinegraph.Workers.TMDbDetailsWorker"),
      :count,
      :id
    )
  end
end
