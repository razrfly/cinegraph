defmodule Cinegraph.Maintenance.BackfillFreshnessTest do
  @moduledoc "#1096 Phase B — seeding the data_refreshes ledger from existing signals."
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Maintenance.BackfillFreshness
  alias Cinegraph.Freshness.DataRefresh
  alias Cinegraph.Movies.{Credit, Movie, Person}
  alias Cinegraph.Repo

  defp movie!(attrs) do
    %Movie{}
    |> Movie.changeset(
      Map.merge(
        %{tmdb_id: System.unique_integer([:positive]), title: "M", import_status: "full"},
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp set_omdb!(m, blob), do: m |> Ecto.Changeset.change(omdb_data: blob) |> Repo.update!()

  defp fetch_attempt!(m) do
    %Cinegraph.Movies.ExternalMetric{}
    |> Cinegraph.Movies.ExternalMetric.changeset(%{
      movie_id: m.id,
      source: "omdb",
      metric_type: "fetch_attempt",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp row(et, id, src), do: Repo.get_by(DataRefresh, entity_type: et, entity_id: id, source: src)

  test "seeds tmdb_details, omdb (ok + empty), and tmdb_person; is idempotent" do
    # tmdb_details: a full movie → ok
    fetched =
      movie!(%{imdb_id: "tt1", release_date: ~D[2015-01-01]})
      |> set_omdb!(%{"Response" => "True"})

    # omdb source-absent: tried, no blob
    tried = movie!(%{imdb_id: "tt2"})
    fetch_attempt!(tried)

    # canonical person with a bio → ok; without → pending
    canonical = movie!(%{canonical_sources: %{"1001_movies" => %{"included" => true}}})
    with_bio = person!("Has Bio", "a real biography")
    no_bio = person!("No Bio", nil)
    credit!(canonical, with_bio)
    credit!(canonical, no_bio)

    {:ok, results} = BackfillFreshness.run(sleep_ms: 0)

    # tmdb_details for every full movie (all 3)
    assert row("movie", fetched.id, "tmdb_details").status == "ok"

    # omdb partition
    assert row("movie", fetched.id, "omdb").status == "ok"
    assert row("movie", fetched.id, "omdb").fetched_at
    assert row("movie", tried.id, "omdb").status == "empty"
    assert is_nil(row("movie", tried.id, "omdb").fetched_at)
    assert results.omdb.fetched == 1
    assert results.omdb.empty == 1

    # person partition
    assert row("person", with_bio.id, "tmdb_person").status == "ok"
    assert row("person", no_bio.id, "tmdb_person").status == "pending"

    # idempotency: a second run inserts nothing
    before = Repo.aggregate(DataRefresh, :count)
    {:ok, _} = BackfillFreshness.run(sleep_ms: 0)
    assert Repo.aggregate(DataRefresh, :count) == before
  end

  defp person!(name, bio) do
    %Person{}
    |> Person.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      name: name,
      biography: bio
    })
    |> Repo.insert!()
  end

  defp credit!(movie, person) do
    %Credit{}
    |> Credit.changeset(%{
      movie_id: movie.id,
      person_id: person.id,
      credit_type: "cast",
      credit_id: "c#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end
end
