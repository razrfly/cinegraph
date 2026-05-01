defmodule Cinegraph.Health.Drift.CollaborationsTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Health.Drift.Collaborations
  alias Cinegraph.Health.Facade
  alias Cinegraph.Movies.{Credit, Movie, Person}

  describe "all/1" do
    test "returns canonical drift result maps" do
      movie = insert_movie!("Missing Collaboration Details")
      add_actor_pair!(movie)

      checks = Collaborations.all(limit: 5)

      assert Enum.map(checks, & &1.check) == [
               :missing_details,
               :queue_backlog,
               :recent_failures
             ]

      assert Enum.all?(checks, &(&1.domain == :collaborations))
      assert Enum.any?(checks, &(&1.check == :missing_details and &1.affected_count == 1))
    end
  end

  describe "Facade.compute_full_verdict/1" do
    test "includes the collaborations domain" do
      verdict = Facade.compute_full_verdict(bypass_cache: true)

      assert Map.has_key?(verdict.domains, :collaborations)
    end
  end

  defp add_actor_pair!(movie) do
    actor_a = insert_person!("Drift Actor A", 940_001)
    actor_b = insert_person!("Drift Actor B", 940_002)

    insert_cast_credit!(movie, actor_a, 0)
    insert_cast_credit!(movie, actor_b, 1)
  end

  defp insert_movie!(title) do
    %Movie{}
    |> Movie.changeset(%{
      title: title,
      tmdb_id: System.unique_integer([:positive]),
      release_date: ~D[2020-01-01],
      import_status: "full"
    })
    |> Repo.insert!()
  end

  defp insert_person!(name, tmdb_id) do
    %Person{}
    |> Person.changeset(%{name: name, tmdb_id: tmdb_id})
    |> Repo.insert!()
  end

  defp insert_cast_credit!(movie, person, order) do
    %Credit{}
    |> Credit.changeset(%{
      movie_id: movie.id,
      person_id: person.id,
      credit_type: "cast",
      cast_order: order,
      credit_id: "drift-cast-#{movie.id}-#{person.id}-#{order}"
    })
    |> Repo.insert!()
  end
end
