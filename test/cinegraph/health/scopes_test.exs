defmodule Cinegraph.Health.ScopesTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.Scopes
  alias Cinegraph.Movies.{Credit, Movie, Person}
  alias Cinegraph.Repo

  setup do
    Cachex.clear(:health_cache)
    :ok
  end

  describe "canonical_movies/0" do
    test "returns a composable query that filters out non-canonical movies" do
      import Ecto.Query
      canonical = insert_movie!(canonical: true)
      _excluded = insert_movie!(canonical: false)

      ids =
        from(m in Scopes.canonical_movies(), select: m.id)
        |> Repo.all()

      assert ids == [canonical.id]
    end
  end

  describe "canonical_movies_count/0" do
    test "counts only canonical movies" do
      insert_movie!(canonical: true)
      insert_movie!(canonical: true)
      insert_movie!(canonical: false)

      assert Scopes.canonical_movies_count() == 2
    end
  end

  describe "canonical_people_count/0" do
    test "counts distinct people with at least one credit on a canonical movie" do
      canonical_movie = insert_movie!(canonical: true)
      another_canonical = insert_movie!(canonical: true)
      non_canonical = insert_movie!(canonical: false)

      # Counted: credit on canonical movie
      counted = insert_person!(%{tmdb_id: 1, name: "In Canon"})
      insert_credit!(counted, canonical_movie)

      # Counted once even with multiple canonical credits (DISTINCT)
      multi = insert_person!(%{tmdb_id: 2, name: "Multi-Canon"})
      insert_credit!(multi, canonical_movie)
      insert_credit!(multi, another_canonical)

      # Not counted: only non-canonical credits
      non_canon = insert_person!(%{tmdb_id: 3, name: "Long Tail"})
      insert_credit!(non_canon, non_canonical)

      # Not counted: no credits at all
      _orphan = insert_person!(%{tmdb_id: 4, name: "Orphan"})

      assert Scopes.canonical_people_count() == 2
    end
  end

  defp insert_person!(attrs) do
    %Person{}
    |> Person.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_movie!(opts) do
    canonical = Keyword.get(opts, :canonical, false)
    canonical_sources = if canonical, do: %{"1001_movies" => %{"included" => true}}, else: %{}

    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      title: "Movie #{System.unique_integer([:positive])}",
      canonical_sources: canonical_sources
    })
    |> Repo.insert!()
  end

  defp insert_credit!(person, movie) do
    %Credit{}
    |> Credit.changeset(%{
      movie_id: movie.id,
      person_id: person.id,
      credit_type: "cast",
      character: "Self",
      cast_order: 0,
      credit_id: "credit-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end
end
