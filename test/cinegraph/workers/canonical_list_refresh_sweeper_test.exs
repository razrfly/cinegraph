defmodule Cinegraph.Workers.CanonicalListRefreshSweeperTest do
  use Cinegraph.DataCase, async: false
  use Oban.Testing, repo: Cinegraph.Repo

  import Ecto.Query

  alias Cinegraph.Movies.{Movie, MovieList}
  alias Cinegraph.Repo
  alias Cinegraph.Workers.CanonicalListRefreshSweeper

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  test "queues blank and stale canonical lists in separate refresh passes" do
    blank = insert_list!(source_key: "blank")

    stale =
      insert_list!(
        source_key: "stale",
        last_import_at: days_ago(120),
        last_import_status: "success"
      )

    insert_movie!(canonical_sources: %{stale.source_key => %{}})

    assert {:ok, %{found: 2, enqueued: 2, lists: lists}} =
             perform_job(CanonicalListRefreshSweeper, %{})

    assert lists == [blank.source_key, stale.source_key]
    assert canonical_job_count() == 2
  end

  test "does not count blank stale lists twice or spend stale pass budget on them" do
    overlap =
      insert_list!(
        source_key: "overlap",
        last_import_at: days_ago(120),
        last_import_status: "success"
      )

    stale =
      insert_list!(
        source_key: "stale",
        last_import_at: days_ago(120),
        last_import_status: "success"
      )

    insert_movie!(canonical_sources: %{stale.source_key => %{}})

    assert {:ok, %{found: 2, enqueued: 2, already_queued: 0, lists: lists}} =
             perform_job(CanonicalListRefreshSweeper, %{})

    assert lists == [overlap.source_key, stale.source_key]
    assert canonical_job_count() == 2
  end

  defp canonical_job_count do
    Repo.aggregate(
      from(j in Oban.Job, where: j.worker == "Cinegraph.Workers.CanonicalImportWorker"),
      :count,
      :id
    )
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

  defp days_ago(days) do
    DateTime.utc_now()
    |> DateTime.add(-days * 86_400, :second)
    |> DateTime.truncate(:second)
  end
end
