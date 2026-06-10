defmodule Cinegraph.Maintenance.MarkImdbIdAbsentTest do
  @moduledoc "#1109 — mark checked-but-null imdb_id movies source-absent in the ledger."
  use Cinegraph.DataCase, async: false

  import Ecto.Query

  alias Cinegraph.Freshness
  alias Cinegraph.Freshness.DataRefresh
  alias Cinegraph.Maintenance.MarkImdbIdAbsent
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  defp movie!(imdb_id) do
    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      imdb_id: imdb_id,
      title: "M #{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp imdb_marker(id),
    do: Repo.get_by(DataRefresh, entity_type: "movie", entity_id: id, source: "imdb_id")

  test "marks a null-imdb movie that has a tmdb_details attempt as source-absent" do
    m = movie!(nil)
    Freshness.touch("movie", m.id, "tmdb_details", :ok)

    assert {:ok, %{found: 1, marked: 1, failed: 0, dry_run: false}} = MarkImdbIdAbsent.run()
    assert imdb_marker(m.id).status == "empty"
  end

  test "treats all checked tmdb_details statuses (ok/empty/ineligible) as 'checked'" do
    for status <- [:ok, :empty, :ineligible] do
      m = movie!(nil)
      Freshness.touch("movie", m.id, "tmdb_details", status)
    end

    assert {:ok, %{found: 3, marked: 3, failed: 0}} = MarkImdbIdAbsent.run()
  end

  test "marks a blank-string imdb_id (not just nil)" do
    m = movie!("")
    Freshness.touch("movie", m.id, "tmdb_details", :ok)

    assert {:ok, %{found: 1, marked: 1}} = MarkImdbIdAbsent.run()
    assert imdb_marker(m.id).status == "empty"
  end

  test "skips a null-imdb movie that was never detail-fetched" do
    m = movie!(nil)

    assert {:ok, %{found: 0}} = MarkImdbIdAbsent.run(dry_run: true)
    assert imdb_marker(m.id) == nil
  end

  test "skips a movie that already has an imdb_id" do
    m = movie!("tt0000001")
    Freshness.touch("movie", m.id, "tmdb_details", :ok)

    assert {:ok, %{found: 0}} = MarkImdbIdAbsent.run(dry_run: true)
  end

  test "is idempotent — re-run marks nothing new and creates no duplicate" do
    m = movie!(nil)
    Freshness.touch("movie", m.id, "tmdb_details", :ok)

    assert {:ok, %{marked: 1}} = MarkImdbIdAbsent.run()
    assert {:ok, %{found: 0, marked: 0}} = MarkImdbIdAbsent.run()

    assert Repo.aggregate(
             from(r in DataRefresh, where: r.entity_id == ^m.id and r.source == "imdb_id"),
             :count,
             :id
           ) == 1
  end

  test "dry_run finds the set but writes nothing" do
    m = movie!(nil)
    Freshness.touch("movie", m.id, "tmdb_details", :ok)

    assert {:ok, %{found: 1, marked: 0, dry_run: true}} = MarkImdbIdAbsent.run(dry_run: true)
    assert imdb_marker(m.id) == nil
  end
end
