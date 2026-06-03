defmodule Cinegraph.Maintenance.BackfillOmdbTest do
  use Cinegraph.DataCase, async: false

  import Ecto.Query

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

    test "ignores movies that already have a stored omdb_data blob" do
      insert_movie!(omdb: true)
      insert_movie!(omdb: false)

      assert {:ok, %{found: 1}} = BackfillOmdb.run(dry_run: true)
    end

    # #1053: eligibility keys on the blob, NOT on a source='omdb' row. A movie
    # with an omdb metric row but no blob still needs a fetch (to get the blob),
    # so it stays eligible — the inverse of the pre-#1053 behaviour.
    test "still enqueues a movie that has an omdb metric row but no blob" do
      insert_movie!(metric_row: true)

      assert {:ok, %{found: 1}} = BackfillOmdb.run(dry_run: true)
    end

    # #1053: a recent fetch_attempt (source-absent) sits on a 90-day cooldown.
    test "excludes movies with a recent fetch_attempt" do
      insert_movie!(fetch_attempt_at: DateTime.utc_now())

      assert {:ok, %{found: 0}} = BackfillOmdb.run(dry_run: true)
    end

    test "includes movies whose fetch_attempt is older than the 90-day cooldown" do
      old = DateTime.add(DateTime.utc_now(), -91 * 24 * 3600, :second)
      insert_movie!(fetch_attempt_at: old)

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

    # #1051 Stage A2 — scope the backlog to a specific id set (the candidate universe).
    test ":movie_ids restricts the backlog to the given set" do
      a = insert_movie!(omdb: false)
      b = insert_movie!(omdb: false)
      _c = insert_movie!(omdb: false)

      assert {:ok, %{found: 2}} = BackfillOmdb.run(movie_ids: [a.id, b.id], dry_run: true)
      assert {:ok, %{found: 3}} = BackfillOmdb.run(dry_run: true)
    end
  end

  describe "eligible_ids/1 (#1051 Stage A2)" do
    test "returns only in-scope, OMDb-missing, imdb_id-bearing ids" do
      a = insert_movie!(omdb: false)
      _b = insert_movie!(omdb: true)
      _c = insert_movie!(omdb: false)

      assert BackfillOmdb.eligible_ids(movie_ids: [a.id]) == [a.id]
    end
  end

  # Generate a valid IMDb ID (tt + 7+ digits) matching the format checked by
  # valid_imdb_id?/1 in OMDb.ApiProcessors: ~r/^tt\d{7,}$/
  defp generate_imdb_id do
    n = System.unique_integer([:positive]) |> rem(9_000_000) |> Kernel.+(1_000_000)
    "tt#{n}"
  end

  # opts:
  #   :imdb_id          - explicit IMDb ID (default: auto-generated valid; pass nil to test exclusion)
  #   :omdb             - set a stored omdb_data blob ("already fetched", #1053). Default false.
  #   :metric_row       - insert a source='omdb' metric row WITHOUT a blob. Default false.
  #   :fetch_attempt_at - insert an omdb/fetch_attempt row at this %DateTime{}. Default nil.
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
      Repo.update_all(from(m in Movie, where: m.id == ^movie.id),
        set: [omdb_data: %{"Response" => "True", "Title" => "Enriched"}]
      )
    end

    if Keyword.get(opts, :metric_row, false) do
      insert_metric!(movie.id, "rating_average", DateTime.utc_now())
    end

    case Keyword.get(opts, :fetch_attempt_at) do
      nil -> :ok
      %DateTime{} = at -> insert_metric!(movie.id, "fetch_attempt", at)
    end

    movie
  end

  defp insert_metric!(movie_id, metric_type, fetched_at) do
    base = %{
      movie_id: movie_id,
      source: "omdb",
      metric_type: metric_type,
      fetched_at: DateTime.truncate(fetched_at, :second)
    }

    attrs =
      case metric_type do
        "fetch_attempt" -> Map.put(base, :text_value, "tried")
        _ -> Map.put(base, :value, 7.5)
      end

    %ExternalMetric{}
    |> ExternalMetric.changeset(attrs)
    |> Repo.insert!()
  end

  defp omdb_job_count do
    Repo.aggregate(
      from(j in Oban.Job, where: j.worker == "Cinegraph.Workers.OMDbEnrichmentWorker"),
      :count,
      :id
    )
  end
end
