defmodule Cinegraph.ListEvents.MovieMatcherTest do
  use Cinegraph.DataCase, async: true

  alias Cinegraph.ListEvents.MovieMatcher
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  defp insert_movie(attrs) do
    %Movie{}
    |> Movie.changeset(Map.put_new(attrs, :tmdb_id, System.unique_integer([:positive])))
    |> Repo.insert!()
  end

  describe "normalize/1" do
    test "downcases, strips punctuation, collapses whitespace" do
      assert MovieMatcher.normalize("The   Godfather!!!") == "godfather"
    end

    test "strips a single leading article" do
      assert MovieMatcher.normalize("The Godfather") == "godfather"
      assert MovieMatcher.normalize("A Woman Under the Influence") == "woman under the influence"
      assert MovieMatcher.normalize("Le Samouraï") == "samourai"
    end

    test "folds accents" do
      assert MovieMatcher.normalize("Amélie") == "amelie"
    end

    test "does not treat an embedded year as removable" do
      assert MovieMatcher.normalize("2001: A Space Odyssey") == "2001 a space odyssey"
    end

    test "nil and blank are empty" do
      assert MovieMatcher.normalize(nil) == ""
      assert MovieMatcher.normalize("   ") == ""
    end
  end

  describe "match/1 by imdb_id" do
    test "resolves on exact imdb_id" do
      movie = insert_movie(%{title: "Whatever", imdb_id: "tt0068646"})

      assert {:ok, matched, :imdb_id} =
               MovieMatcher.match(%{raw_imdb_id: "tt0068646", raw_title: "x", raw_year: 1})

      assert matched.id == movie.id
    end
  end

  describe "match/1 by title + year" do
    test "resolves on normalized title within the year window" do
      movie = insert_movie(%{title: "The Godfather", release_date: ~D[1972-03-24]})

      assert {:ok, matched, :title_year} =
               MovieMatcher.match(%{raw_title: "Godfather", raw_year: 1972})

      assert matched.id == movie.id
    end

    test "tolerates a ±1 year disagreement" do
      movie = insert_movie(%{title: "Solaris", release_date: ~D[1972-09-26]})

      assert {:ok, matched, :title_year} =
               MovieMatcher.match(%{raw_title: "Solaris", raw_year: 1973})

      assert matched.id == movie.id
    end

    test "matches against original_title" do
      movie =
        insert_movie(%{
          title: "Breathless",
          original_title: "À bout de souffle",
          release_date: ~D[1960-03-16]
        })

      assert {:ok, matched, :title_year} =
               MovieMatcher.match(%{raw_title: "A bout de souffle", raw_year: 1960})

      assert matched.id == movie.id
    end

    test "no match returns :no_match" do
      assert :no_match =
               MovieMatcher.match(%{raw_title: "Nonexistent Zzqx Film", raw_year: 1999})
    end

    test "year outside the window does not match" do
      insert_movie(%{title: "Drift", release_date: ~D[1950-01-01]})
      assert :no_match = MovieMatcher.match(%{raw_title: "Drift", raw_year: 1999})
    end

    test "more than one candidate is :ambiguous, never guessed" do
      insert_movie(%{title: "The Mummy", release_date: ~D[1999-05-07]})
      insert_movie(%{title: "The Mummy", release_date: ~D[1999-06-01]})

      assert :ambiguous = MovieMatcher.match(%{raw_title: "The Mummy", raw_year: 1999})
    end
  end

  describe "match/1 resolution order" do
    test "falls back to title+year when imdb_id is absent" do
      movie = insert_movie(%{title: "Stalker", release_date: ~D[1979-05-25]})

      assert {:ok, matched, :title_year} =
               MovieMatcher.match(%{raw_imdb_id: nil, raw_title: "Stalker", raw_year: 1979})

      assert matched.id == movie.id
    end
  end
end
