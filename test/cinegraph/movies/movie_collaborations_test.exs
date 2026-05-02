defmodule Cinegraph.Movies.MovieCollaborationsTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Collaborations.{Collaboration, CollaborationDetail}
  alias Cinegraph.Movies.{Credit, Movie, MovieCollaborations, Person}

  setup do
    assert {:ok, _} = Cachex.clear(:movies_cache)
    :ok
  end

  describe "get_key_collaborations/2" do
    test "actor partnerships use linked movie search count instead of stale aggregate count" do
      actor_a = insert_person!("Linked Count Actor A")
      actor_b = insert_person!("Linked Count Actor B")

      current = insert_movie!("Linked Count Current", ~D[2024-01-01])
      other = insert_movie!("Linked Count Other", ~D[2023-01-01])

      current_a = insert_cast_credit!(current, actor_a, 0)
      current_b = insert_cast_credit!(current, actor_b, 1)
      insert_cast_credit!(other, actor_a, 0)
      insert_cast_credit!(other, actor_b, 1)

      insert_collaboration!(actor_a, actor_b, %{collaboration_count: 5})

      assert %{
               actor_partnerships: [%{collaboration_count: 2}],
               notable_collaborations: [%{films_together: 2, movies: movies}]
             } =
               MovieCollaborations.get_key_collaborations(
                 preload_people([current_a, current_b]),
                 []
               )

      assert length(movies) == 2
    end

    test "actor partnerships include full movies missing from collaboration details" do
      actor_a = insert_person!("Credit Count Actor A")
      actor_b = insert_person!("Credit Count Actor B")

      current = insert_movie!("Credit Count Current", ~D[2024-01-01])
      detail_backed = insert_movie!("Credit Count Detail Backed", ~D[2023-01-01])
      credit_only = insert_movie!("Credit Count Credit Only", ~D[2022-01-01])
      unreleased = insert_movie!("Credit Count Future", ~D[2999-01-01])

      current_a = insert_cast_credit!(current, actor_a, 0)
      current_b = insert_cast_credit!(current, actor_b, 1)

      for movie <- [detail_backed, credit_only, unreleased] do
        insert_cast_credit!(movie, actor_a, 0)
        insert_cast_credit!(movie, actor_b, 1)
      end

      collaboration = insert_collaboration!(actor_a, actor_b, %{collaboration_count: 2})
      insert_detail!(collaboration, current, "actor-actor")
      insert_detail!(collaboration, detail_backed, "actor-actor")

      # get_key_collaborations/2 uses search results, which intentionally skip
      # the unreleased movie above.
      assert %{
               actor_partnerships: [%{collaboration_count: 3}],
               notable_collaborations: [%{films_together: 3, movies: movies}]
             } =
               MovieCollaborations.get_key_collaborations(
                 preload_people([current_a, current_b]),
                 []
               )

      assert Enum.map(movies, & &1.title) |> Enum.sort() == [
               "Credit Count Credit Only",
               "Credit Count Current",
               "Credit Count Detail Backed"
             ]
    end

    test "director actor reunions use the same count as their generated movie search link" do
      actor = insert_person!("Director Count Actor")
      director = insert_person!("Director Count Director")

      current = insert_movie!("Director Count Current", ~D[2024-01-01])
      detail_backed = insert_movie!("Director Count Detail Backed", ~D[2023-01-01])
      credit_only = insert_movie!("Director Count Credit Only", ~D[2022-01-01])

      current_actor_credit = insert_cast_credit!(current, actor, 0)
      current_director_credit = insert_director_credit!(current, director)

      for movie <- [detail_backed, credit_only] do
        insert_cast_credit!(movie, actor, 0)
        insert_director_credit!(movie, director)
      end

      collaboration = insert_collaboration!(actor, director, %{collaboration_count: 2})
      insert_detail!(collaboration, current, "actor-director")
      insert_detail!(collaboration, detail_backed, "actor-director")

      assert %{
               director_actor_reunions: [%{collaboration_count: 3}],
               notable_collaborations: [%{films_together: 3, movies: movies}]
             } =
               MovieCollaborations.get_key_collaborations(
                 preload_people([current_actor_credit]),
                 preload_people([current_director_credit])
               )

      assert length(movies) == 3
    end

    test "director actor reunions only count movies where each person held the expected role" do
      actor = insert_person!("Role Constrained Actor")
      director = insert_person!("Role Constrained Director")

      current = insert_movie!("Role Constrained Current", ~D[2024-01-01])
      correct = insert_movie!("Role Constrained Correct", ~D[2023-01-01])
      wrong_roles = insert_movie!("Role Constrained Wrong Roles", ~D[2022-01-01])

      current_actor_credit = insert_cast_credit!(current, actor, 0)
      current_director_credit = insert_director_credit!(current, director)
      insert_cast_credit!(correct, actor, 0)
      insert_director_credit!(correct, director)
      insert_cast_credit!(wrong_roles, actor, 0)
      insert_cast_credit!(wrong_roles, director, 1)

      assert %{
               director_actor_reunions: [%{collaboration_count: 2}],
               notable_collaborations: [%{films_together: 2, movies: movies}]
             } =
               MovieCollaborations.get_key_collaborations(
                 preload_people([current_actor_credit]),
                 preload_people([current_director_credit])
               )

      refute Enum.any?(movies, &(&1.title == "Role Constrained Wrong Roles"))
    end

    test "generic crew-crew collaborations are not promoted by default" do
      editor = insert_person!("Crew Hidden Editor")
      composer = insert_person!("Crew Hidden Composer")

      current = insert_movie!("Crew Hidden Current", ~D[2024-01-01])
      other = insert_movie!("Crew Hidden Other", ~D[2023-01-01])

      current_editor_credit = insert_crew_credit!(current, editor, "Editor")
      current_composer_credit = insert_crew_credit!(current, composer, "Original Music Composer")

      for movie <- [other] do
        insert_crew_credit!(movie, editor, "Editor")
        insert_crew_credit!(movie, composer, "Original Music Composer")
      end

      collaboration = insert_collaboration!(editor, composer, %{collaboration_count: 2})
      insert_detail!(collaboration, current, "crew-crew")
      insert_detail!(collaboration, other, "crew-crew")

      assert %{notable_collaborations: []} =
               MovieCollaborations.get_key_collaborations(
                 [],
                 preload_people([current_editor_credit, current_composer_credit])
               )
    end
  end

  defp insert_person!(name) do
    %Person{}
    |> Person.changeset(%{
      name: name,
      tmdb_id: System.unique_integer([:positive])
    })
    |> Repo.insert!()
  end

  defp insert_movie!(title, release_date) do
    %Movie{}
    |> Movie.changeset(%{
      title: title,
      tmdb_id: System.unique_integer([:positive]),
      release_date: release_date,
      import_status: "full"
    })
    |> Repo.insert!()
  end

  defp insert_cast_credit!(movie, person, order) do
    insert_credit!(movie, person, %{
      credit_type: "cast",
      cast_order: order
    })
  end

  defp insert_director_credit!(movie, person) do
    insert_credit!(movie, person, %{
      credit_type: "crew",
      department: "Directing",
      job: "Director"
    })
  end

  defp insert_crew_credit!(movie, person, job) do
    insert_credit!(movie, person, %{
      credit_type: "crew",
      department: "Crew",
      job: job
    })
  end

  defp insert_credit!(movie, person, attrs) do
    defaults = %{
      movie_id: movie.id,
      person_id: person.id,
      credit_id:
        "movie-collab-credit-#{movie.id}-#{person.id}-#{System.unique_integer([:positive])}"
    }

    %Credit{}
    |> Credit.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_collaboration!(person_a, person_b, attrs) do
    {person_a_id, person_b_id} = ordered_ids(person_a, person_b)

    %Collaboration{}
    |> Collaboration.changeset(
      Map.merge(
        %{
          person_a_id: person_a_id,
          person_b_id: person_b_id,
          collaboration_count: 2
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp insert_detail!(collaboration, movie, type) do
    %CollaborationDetail{}
    |> CollaborationDetail.changeset(%{
      collaboration_id: collaboration.id,
      movie_id: movie.id,
      collaboration_type: type,
      year: movie.release_date.year
    })
    |> Repo.insert!()
  end

  defp preload_people(credits), do: Repo.preload(credits, :person)

  defp ordered_ids(person_a, person_b) do
    {min(person_a.id, person_b.id), max(person_a.id, person_b.id)}
  end
end
