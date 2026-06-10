defmodule Cinegraph.Workers.TMDbMovieRefreshWorkerTest do
  @moduledoc "#1106 — unified per-movie TMDb refresh worker."
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Workers.TMDbMovieRefreshWorker
  alias Cinegraph.Freshness.DataRefresh
  alias Cinegraph.Movies.{ExternalMetric, Movie}
  alias Cinegraph.Repo

  defp movie!(attrs) do
    %Movie{}
    |> Movie.changeset(
      Map.merge(
        %{tmdb_id: System.unique_integer([:positive]), title: "Old Title", runtime: 90},
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp ledger(id, src),
    do: Repo.get_by(DataRefresh, entity_type: "movie", entity_id: id, source: src)

  defp canned(tmdb_id, watch_results, imdb_id \\ nil) do
    %{
      "id" => tmdb_id,
      "imdb_id" => imdb_id,
      "title" => "Refreshed Title",
      "runtime" => 142,
      "overview" => "fresh overview",
      "vote_average" => 8.1,
      "vote_count" => 5000,
      "popularity" => 77.0,
      "credits" => %{"cast" => [], "crew" => []},
      "watch_providers" => %{"results" => watch_results}
    }
  end

  test "successful refresh updates the movie + metrics and touches both ledger sources" do
    m = movie!(%{release_date: ~D[2020-01-01]})
    # no providers in payload → watch_providers terminal :empty
    fetch = fn _ -> {:ok, canned(m.tmdb_id, %{})} end

    # no providers AND no imdb_id in payload → both terminal :empty
    assert {:ok, %{watch_present?: false, imdb_present?: false}} =
             TMDbMovieRefreshWorker.refresh(m.id, fetch_fun: fetch)

    updated = Repo.get(Movie, m.id)
    assert updated.runtime == 142
    assert updated.title == "Refreshed Title"

    assert Repo.get_by(ExternalMetric,
             movie_id: m.id,
             source: "tmdb",
             metric_type: "rating_average"
           )

    assert ledger(m.id, "tmdb_details").status == "ok"
    assert ledger(m.id, "watch_providers").status == "empty"
    assert ledger(m.id, "imdb_id").status == "empty"
  end

  test "watch_providers + imdb_id ledgers are :ok when the payload carries them" do
    m = movie!(%{release_date: ~D[2021-01-01]})
    fetch = fn _ -> {:ok, canned(m.tmdb_id, %{"US" => %{}}, "tt1234567")} end

    assert {:ok, %{watch_present?: true, imdb_present?: true}} =
             TMDbMovieRefreshWorker.refresh(m.id, fetch_fun: fetch)

    assert ledger(m.id, "watch_providers").status == "ok"
    assert ledger(m.id, "tmdb_details").status == "ok"
    assert ledger(m.id, "imdb_id").status == "ok"
  end

  test "fetch error touches all three sources :error and returns the error" do
    m = movie!(%{release_date: ~D[2019-01-01]})
    fetch = fn _ -> {:error, :timeout} end

    assert {:error, :timeout} = TMDbMovieRefreshWorker.refresh(m.id, fetch_fun: fetch)
    assert ledger(m.id, "tmdb_details").status == "error"
    assert ledger(m.id, "watch_providers").status == "error"
    assert ledger(m.id, "imdb_id").status == "error"
  end

  # (No "missing tmdb_id" test: movies.tmdb_id is NOT NULL, so that worker branch is
  # defensive-only and can't be constructed as a fixture.)

  test "missing movie → cancel" do
    assert {:cancel, :movie_not_found} = TMDbMovieRefreshWorker.refresh(999_999_999)
  end
end
