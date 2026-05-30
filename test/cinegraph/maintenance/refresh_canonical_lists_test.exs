defmodule Cinegraph.Maintenance.RefreshCanonicalListsTest do
  use Cinegraph.DataCase, async: false

  import Ecto.Query

  alias Cinegraph.Maintenance.RefreshCanonicalLists
  alias Cinegraph.Movies.{Movie, MovieList}
  alias Cinegraph.Repo

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  test "dry-run returns selected lists without enqueuing" do
    insert_list!(source_key: "blank_list")

    assert {:ok, %{found: 1, enqueued: 0, failed: 0, dry_run: true, lists: ["blank_list"]}} =
             RefreshCanonicalLists.run(blank_only: true, dry_run: true)

    assert canonical_job_count() == 0
  end

  test "list selector queues exactly that IMDb list" do
    insert_list!(source_key: "afi_100")
    insert_list!(source_key: "other_blank")

    assert {:ok, %{found: 1, enqueued: 1, lists: ["afi_100"]}} =
             RefreshCanonicalLists.run(list: "afi_100")

    assert canonical_job_count() == 1
  end

  test "blank_only queues only blank active IMDb lists" do
    nonblank = insert_list!(source_key: "nonblank")
    insert_movie!(canonical_sources: %{nonblank.source_key => %{}})
    insert_list!(source_key: "blank")

    insert_list!(
      source_key: "custom_blank",
      source_type: "custom",
      source_url: "https://example.com/list"
    )

    assert {:ok, %{found: 1, enqueued: 1, lists: ["blank"]}} =
             RefreshCanonicalLists.run(blank_only: true)
  end

  test "stale_days queues stale nonblank lists" do
    stale =
      insert_list!(
        source_key: "stale",
        last_import_at: days_ago(120),
        last_import_status: "success"
      )

    insert_movie!(canonical_sources: %{stale.source_key => %{}})

    assert {:ok, %{found: 1, enqueued: 1, lists: ["stale"]}} =
             RefreshCanonicalLists.run(stale_days: 90)
  end

  test "limit caps selection deterministically" do
    insert_list!(source_key: "a_blank")
    insert_list!(source_key: "b_blank")
    insert_list!(source_key: "c_blank")

    assert {:ok, %{found: 2, enqueued: 2, lists: ["a_blank", "b_blank"]}} =
             RefreshCanonicalLists.run(blank_only: true, limit: 2)
  end

  test "Oban uniqueness conflicts count as already queued" do
    insert_list!(source_key: "blank")

    assert {:ok, %{enqueued: 1, already_queued: 0}} =
             RefreshCanonicalLists.run(blank_only: true)

    assert {:ok, %{enqueued: 0, already_queued: 1}} =
             RefreshCanonicalLists.run(blank_only: true)
  end

  test "raises without a selector" do
    assert_raise ArgumentError, fn -> RefreshCanonicalLists.run(dry_run: true) end
  end

  test "raises with conflicting selectors" do
    assert_raise ArgumentError, fn ->
      RefreshCanonicalLists.run(blank_only: true, all: true, dry_run: true)
    end
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
