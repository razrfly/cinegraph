defmodule Cinegraph.Workers.DataRepairWorkerTest do
  @moduledoc """
  #1053 regression: the external_metrics materialization (`backfill_external_metrics_omdb`)
  re-derives `external_metrics` from stored `omdb_data` blobs via `insert_all`. It silently
  discarded on prod from #1054 until 2026-06-08 because `inserted_at`/`updated_at` were built
  as `DateTime` while the columns are `:naive_datetime` (insert_all does no casting → ChangeError).
  This test exercises the real insert_all path so the type mismatch can't reappear.
  """
  use Cinegraph.DataCase, async: false
  use Oban.Testing, repo: Cinegraph.Repo

  alias Cinegraph.Movies.{ExternalMetric, Movie}
  alias Cinegraph.Repo
  alias Cinegraph.Workers.DataRepairWorker

  defp movie_with_omdb!(blob) do
    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      title: "Repair #{System.unique_integer([:positive])}",
      import_status: "full",
      imdb_id: "tt#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
    # omdb_data is load_in_query: false — set it directly
    |> Ecto.Changeset.change(omdb_data: blob)
    |> Repo.update!()
  end

  test "backfill_external_metrics_omdb materializes rows from the blob via insert_all" do
    movie = movie_with_omdb!(%{"imdbRating" => "8.5", "imdbVotes" => "12,345"})

    assert :ok =
             perform_job(DataRepairWorker, %{
               "repair_type" => "backfill_external_metrics_omdb",
               "batch_size" => 200,
               "last_id" => 0,
               "total_processed" => 0,
               "total_inserted" => 0
             })

    rows = Repo.all(from e in ExternalMetric, where: e.movie_id == ^movie.id)
    assert Enum.any?(rows, &(&1.source == "imdb" and &1.metric_type == "rating_average"))

    # imdbVotes parses to an integer (12_345) but the column is :float — insert_all does no
    # casting, so process_metric_batch/2 must coerce it. Assert that coercion actually happened.
    votes_row = Enum.find(rows, &(&1.source == "imdb" and &1.metric_type == "rating_votes"))
    assert votes_row
    assert is_float(votes_row.value)

    # timestamps must be the schema's :naive_datetime (the bug shipped a DateTime here)
    sample = hd(rows)
    assert %NaiveDateTime{} = sample.inserted_at
    assert %NaiveDateTime{} = sample.updated_at
  end

  test "the backfill is idempotent — a second pass inserts nothing new" do
    movie = movie_with_omdb!(%{"imdbRating" => "7.0"})

    args = %{
      "repair_type" => "backfill_external_metrics_omdb",
      "batch_size" => 200,
      "last_id" => 0,
      "total_processed" => 0,
      "total_inserted" => 0
    }

    assert :ok = perform_job(DataRepairWorker, args)
    before = Repo.aggregate(from(e in ExternalMetric, where: e.movie_id == ^movie.id), :count)

    assert :ok = perform_job(DataRepairWorker, args)

    after_count =
      Repo.aggregate(from(e in ExternalMetric, where: e.movie_id == ^movie.id), :count)

    assert before == after_count
  end
end
