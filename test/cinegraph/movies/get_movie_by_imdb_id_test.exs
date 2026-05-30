defmodule Cinegraph.Movies.GetMovieByImdbIdTest do
  use Cinegraph.DataCase, async: true

  # Regression tests for #1013: Repo.get_by(Movie, imdb_id:) raised
  # Ecto.MultipleResultsError when duplicate imdb_id rows existed.
  # get_movie_by_imdb_id/1 now uses LIMIT 2 so it never raises, and
  # logs a warning when duplicates are detected.

  import ExUnit.CaptureLog

  alias Cinegraph.Movies
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  defp insert_movie!(attrs) do
    base = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Test Movie",
      original_title: "Test Movie",
      release_date: ~D[2020-01-01],
      import_status: "full",
      adult: false,
      runtime: 90
    }

    %Movie{}
    |> Movie.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  describe "get_movie_by_imdb_id/1" do
    test "returns nil when no movie has the given imdb_id" do
      assert Movies.get_movie_by_imdb_id("tt9999999") == nil
    end

    test "returns the movie when exactly one row matches" do
      movie = insert_movie!(%{imdb_id: "tt1234567"})
      assert Movies.get_movie_by_imdb_id("tt1234567").id == movie.id
    end

    test "returns the oldest row and does not raise when duplicate imdb_id rows exist" do
      # Insert two movies with the same imdb_id (the data-quality gap from #1013).
      first = insert_movie!(%{imdb_id: "tt9876543", title: "First"})
      _second = insert_movie!(%{imdb_id: "tt9876543", title: "Second"})

      # Must not raise Ecto.MultipleResultsError; must return the lower-id (older) row.
      result = Movies.get_movie_by_imdb_id("tt9876543")
      assert result != nil
      assert result.id == first.id
    end

    test "emits a warning log when duplicate imdb_id rows exist" do
      insert_movie!(%{imdb_id: "tt1111111", title: "Dup A"})
      insert_movie!(%{imdb_id: "tt1111111", title: "Dup B"})

      assert capture_log(fn -> Movies.get_movie_by_imdb_id("tt1111111") end) =~
               "Multiple rows share imdb_id"
    end
  end
end
