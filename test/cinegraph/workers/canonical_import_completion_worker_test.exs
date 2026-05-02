defmodule Cinegraph.Workers.CanonicalImportCompletionWorkerTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Movies.{Movie, MovieList}
  alias Cinegraph.Repo
  alias Cinegraph.Workers.CanonicalImportCompletionWorker

  test "zero actual movies with expected count becomes failed" do
    insert_list!(source_key: "empty_expected")

    assert {:ok, list} =
             CanonicalImportCompletionWorker.perform(%Oban.Job{
               args: %{"list_key" => "empty_expected", "expected_count" => 1, "total_pages" => 0}
             })

    assert list.last_import_status == "failed"
    assert list.metadata["actual_movie_count"] == 0
    assert list.metadata["expected_movie_count"] == 1
    assert list.metadata["last_import_error"]
  end

  test "non-zero actual below expected becomes partial" do
    list = insert_list!(source_key: "partial_expected")
    insert_movie!(canonical_sources: %{list.source_key => %{}})

    assert {:ok, updated} =
             CanonicalImportCompletionWorker.perform(%Oban.Job{
               args: %{
                 "list_key" => "partial_expected",
                 "expected_count" => 2,
                 "total_pages" => 0
               }
             })

    assert updated.last_import_status == "partial"
    assert updated.metadata["actual_movie_count"] == 1
    assert updated.metadata["expected_movie_count"] == 2
    refute Map.has_key?(updated.metadata, "last_import_error")
  end

  test "actual count meeting expected becomes success" do
    list = insert_list!(source_key: "success_expected")
    insert_movie!(canonical_sources: %{list.source_key => %{}})

    assert {:ok, updated} =
             CanonicalImportCompletionWorker.perform(%Oban.Job{
               args: %{
                 "list_key" => "success_expected",
                 "expected_count" => 1,
                 "total_pages" => 0
               }
             })

    assert updated.last_import_status == "success"
    assert updated.metadata["actual_movie_count"] == 1
  end

  test "finalizing an already terminal import does not increment twice" do
    list = insert_list!(source_key: "duplicate_finalize", last_import_status: "pending")
    insert_movie!(canonical_sources: %{list.source_key => %{}})

    job = %Oban.Job{
      args: %{
        "list_key" => "duplicate_finalize",
        "expected_count" => 1,
        "total_pages" => 0
      }
    }

    assert {:ok, first} = CanonicalImportCompletionWorker.perform(job)
    assert first.last_import_status == "success"
    assert first.total_imports == 1

    assert {:ok, second} = CanonicalImportCompletionWorker.perform(job)
    assert second.last_import_status == "success"
    assert second.total_imports == 1
  end

  defp insert_list!(attrs) do
    source_key = Keyword.fetch!(attrs, :source_key)

    defaults = %{
      source_key: source_key,
      name: "List #{source_key}",
      source_type: "imdb",
      source_url: "https://www.imdb.com/list/ls#{System.unique_integer([:positive])}/",
      category: "curated",
      active: true,
      metadata: %{}
    }

    attrs = Enum.into(attrs, %{})

    %MovieList{}
    |> MovieList.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_movie!(attrs) do
    attrs = Enum.into(attrs, %{})

    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Movie #{System.unique_integer([:positive])}"
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end
