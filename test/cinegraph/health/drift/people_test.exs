defmodule Cinegraph.Health.Drift.PeopleTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.Drift
  alias Cinegraph.Movies.{Credit, Movie, Person}
  alias Cinegraph.Repo

  setup do
    Cachex.clear(:health_cache)
    :ok
  end

  # Pre-fix, each of these checks raised Ecto.SubQueryError and the
  # whole `mix cinegraph.health` task surfaced them as `crashed`. Post-fix,
  # they return a real `Drift.result/N` map. Status stays `:unknown` at this
  # layer (Verdict colors it downstream); the regression signal is
  # `blocked_reason == nil` and a real `affected_count`.

  describe "missing_profile_path/0 (regression: schemaless subquery select)" do
    test "returns a real result instead of crashing on Ecto.SubQueryError" do
      insert_person!(%{tmdb_id: 1, name: "No Photo", profile_path: nil})
      insert_person!(%{tmdb_id: 2, name: "Has Photo", profile_path: "/abc.jpg"})

      result = Drift.People.missing_profile_path()

      assert result.check == :missing_profile_path
      assert result.blocked_reason == nil
      assert result.affected_count >= 1
    end
  end

  describe "missing_biography/0 (#735 Phase 1.2 — canonical-list scope)" do
    test "counts only people with credits on canonical-list movies and missing biography" do
      canonical_movie = insert_movie!(canonical: true)
      non_canonical_movie = insert_movie!(canonical: false)

      # Should count: in canonical list, missing biography
      counted = insert_person!(%{tmdb_id: 100, name: "Canonical NoBio", biography: nil})
      insert_credit!(counted, canonical_movie)

      # Should NOT count: not in any canonical list
      _excluded_non_canonical =
        insert_person!(%{tmdb_id: 101, name: "Non-Canonical NoBio", biography: nil})
        |> tap(&insert_credit!(&1, non_canonical_movie))

      # Should NOT count: in canonical list but biography populated
      _excluded_has_bio =
        insert_person!(%{tmdb_id: 102, name: "Canonical HasBio", biography: "Hello"})
        |> tap(&insert_credit!(&1, canonical_movie))

      # Should NOT count: in canonical list, blank biography (treated as missing)
      # — this one SHOULD count actually (biography == "")
      blank = insert_person!(%{tmdb_id: 103, name: "Canonical Blank", biography: ""})
      insert_credit!(blank, canonical_movie)

      result = Drift.People.missing_biography()

      assert result.check == :missing_biography
      assert result.blocked_reason == nil
      assert result.affected_count == 2
      assert result.total_population == 3
    end
  end

  describe "missing_known_for_department/0 (regression: schemaless subquery select)" do
    test "returns a real result instead of crashing on Ecto.SubQueryError" do
      insert_person!(%{tmdb_id: 6, name: "No Dept", known_for_department: nil})
      insert_person!(%{tmdb_id: 7, name: "Has Dept", known_for_department: "Acting"})

      result = Drift.People.missing_known_for_department()

      assert result.check == :missing_known_for_department
      assert result.blocked_reason == nil
      assert result.affected_count >= 1
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
