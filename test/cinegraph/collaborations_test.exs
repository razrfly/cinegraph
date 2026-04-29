defmodule Cinegraph.CollaborationsTest do
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Collaborations
  alias Cinegraph.Collaborations.Collaboration
  alias Cinegraph.Movies.Person

  describe "get_frequent_collaborators/1" do
    test "returns collaboration summaries for either side of the relationship" do
      person = insert_person!("Jane Filmmaker", 900_001)
      collaborator = insert_person!("Frequent Partner", 900_002)

      %Collaboration{}
      |> Collaboration.changeset(%{
        person_a_id: person.id,
        person_b_id: collaborator.id,
        collaboration_count: 6,
        first_collaboration_date: ~D[2001-01-01],
        latest_collaboration_date: ~D[2020-01-01],
        avg_movie_rating: Decimal.new("7.5"),
        total_revenue: 12_000_000
      })
      |> Repo.insert!()

      assert [
               %{
                 person: %{id: collaborator_id, name: "Frequent Partner"},
                 collaboration_count: 6,
                 first_date: ~D[2001-01-01],
                 latest_date: ~D[2020-01-01],
                 avg_rating: %Decimal{},
                 total_revenue: 12_000_000,
                 strength: :strong
               }
             ] = Collaborations.get_frequent_collaborators(person)

      assert collaborator_id == collaborator.id
    end

    test "ignores collaborations below the frequent threshold" do
      person = insert_person!("Solo Artist", 900_003)
      collaborator = insert_person!("One-Off Partner", 900_004)

      %Collaboration{}
      |> Collaboration.changeset(%{
        person_a_id: person.id,
        person_b_id: collaborator.id,
        collaboration_count: 1
      })
      |> Repo.insert!()

      assert Collaborations.get_frequent_collaborators(person.id) == []
    end
  end

  defp insert_person!(name, tmdb_id) do
    %Person{}
    |> Person.changeset(%{name: name, tmdb_id: tmdb_id})
    |> Repo.insert!()
  end
end
