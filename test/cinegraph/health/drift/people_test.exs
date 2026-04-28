defmodule Cinegraph.Health.Drift.PeopleTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.Drift
  alias Cinegraph.Movies.Person
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

  describe "missing_biography/0 (regression: schemaless subquery select)" do
    test "returns a real result instead of crashing on Ecto.SubQueryError" do
      insert_person!(%{tmdb_id: 3, name: "Empty Bio", biography: ""})
      insert_person!(%{tmdb_id: 4, name: "No Bio", biography: nil})
      insert_person!(%{tmdb_id: 5, name: "Has Bio", biography: "Hello world"})

      result = Drift.People.missing_biography()

      assert result.check == :missing_biography
      assert result.blocked_reason == nil
      assert result.affected_count >= 2
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
end
