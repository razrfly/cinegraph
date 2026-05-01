defmodule Cinegraph.CollaborationsTest do
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Collaborations
  alias Cinegraph.Collaborations.{Collaboration, CollaborationDetail}
  alias Cinegraph.Movies.{Credit, Movie, Person}
  alias Cinegraph.Workers.CollaborationWorker

  describe "rebuild_movie_collaborations/1" do
    test "creates a detail and aggregate for two top-billed actors in a released movie" do
      movie = insert_movie!("Pair Movie", ~D[2001-01-01])
      actor_a = insert_person!("Actor A", 901_001)
      actor_b = insert_person!("Actor B", 901_002)
      insert_cast_credit!(movie, actor_a, 0)
      insert_cast_credit!(movie, actor_b, 1)

      assert {:ok, %{movie_id: movie_id, details: 1, affected_pairs: 1}} =
               Collaborations.rebuild_movie_collaborations(movie.id)

      assert movie_id == movie.id

      collaboration = Repo.one!(Collaboration)
      assert collaboration.person_a_id == min(actor_a.id, actor_b.id)
      assert collaboration.person_b_id == max(actor_a.id, actor_b.id)
      assert collaboration.collaboration_count == 1
      assert collaboration.first_collaboration_date == ~D[2001-01-01]
      assert collaboration.latest_collaboration_date == ~D[2001-01-01]
      assert collaboration.years_active == [2001]

      detail = Repo.one!(CollaborationDetail)
      assert detail.collaboration_id == collaboration.id
      assert detail.movie_id == movie.id
      assert detail.collaboration_type == "actor-actor"
      assert detail.year == 2001
    end

    test "running rebuild twice does not inflate aggregate counts" do
      movie = insert_movie!("Repeatable Movie", ~D[2002-01-01])
      actor_a = insert_person!("Repeat Actor A", 901_003)
      actor_b = insert_person!("Repeat Actor B", 901_004)
      insert_cast_credit!(movie, actor_a, 0)
      insert_cast_credit!(movie, actor_b, 1)

      assert {:ok, %{details: 1}} = Collaborations.rebuild_movie_collaborations(movie.id)
      assert {:ok, %{details: 1}} = Collaborations.rebuild_movie_collaborations(movie.id)

      assert Repo.aggregate(CollaborationDetail, :count, :id) == 1
      assert Repo.one!(Collaboration).collaboration_count == 1
    end

    test "recomputes aggregate counts across multiple movies for the same pair" do
      actor_a = insert_person!("Multi Actor A", 901_005)
      actor_b = insert_person!("Multi Actor B", 901_006)
      movie_a = insert_movie!("First Pair Movie", ~D[2003-01-01])
      movie_b = insert_movie!("Second Pair Movie", ~D[2005-01-01])

      insert_cast_credit!(movie_a, actor_a, 0)
      insert_cast_credit!(movie_a, actor_b, 1)
      insert_cast_credit!(movie_b, actor_a, 0)
      insert_cast_credit!(movie_b, actor_b, 1)

      assert {:ok, %{details: 1}} = Collaborations.rebuild_movie_collaborations(movie_a.id)
      assert {:ok, %{details: 1}} = Collaborations.rebuild_movie_collaborations(movie_b.id)

      collaboration = Repo.one!(Collaboration)
      assert collaboration.collaboration_count == 2
      assert collaboration.first_collaboration_date == ~D[2003-01-01]
      assert collaboration.latest_collaboration_date == ~D[2005-01-01]
      assert collaboration.years_active == [2003, 2005]
    end

    test "removes stale details and aggregate rows when credits no longer produce a pair" do
      movie = insert_movie!("Stale Pair Movie", ~D[2006-01-01])
      actor_a = insert_person!("Stale Actor A", 901_007)
      actor_b = insert_person!("Stale Actor B", 901_008)
      insert_cast_credit!(movie, actor_a, 0)
      stale_credit = insert_cast_credit!(movie, actor_b, 1)

      assert {:ok, %{details: 1}} = Collaborations.rebuild_movie_collaborations(movie.id)
      assert Repo.aggregate(Collaboration, :count, :id) == 1

      Repo.delete!(stale_credit)

      assert {:ok, %{details: 0, affected_pairs: 1}} =
               Collaborations.rebuild_movie_collaborations(movie.id)

      assert Repo.aggregate(CollaborationDetail, :count, :id) == 0
      assert Repo.aggregate(Collaboration, :count, :id) == 0
    end

    test "accepts director-crew and crew-crew collaboration types emitted by the builder" do
      movie = insert_movie!("Crew Pair Movie", ~D[2007-01-01])
      director = insert_person!("Director Person", 901_009)
      writer = insert_person!("Writer Person", 901_010)
      editor = insert_person!("Editor Person", 901_011)

      insert_crew_credit!(movie, director, "Director")
      insert_crew_credit!(movie, writer, "Writer")
      insert_crew_credit!(movie, editor, "Editor")

      assert {:ok, %{details: 3}} = Collaborations.rebuild_movie_collaborations(movie.id)

      types =
        CollaborationDetail
        |> select([cd], cd.collaboration_type)
        |> Repo.all()
        |> Enum.sort()

      assert "director-crew" in types
      assert "crew-crew" in types
    end

    test "movies without release dates produce no collaboration details" do
      movie = insert_movie!("Undated Pair Movie", nil)
      actor_a = insert_person!("Undated Actor A", 901_012)
      actor_b = insert_person!("Undated Actor B", 901_013)
      insert_cast_credit!(movie, actor_a, 0)
      insert_cast_credit!(movie, actor_b, 1)

      assert {:ok, %{details: 0, affected_pairs: 0}} =
               Collaborations.rebuild_movie_collaborations(movie.id)

      assert Repo.aggregate(CollaborationDetail, :count, :id) == 0
      assert Repo.aggregate(Collaboration, :count, :id) == 0
    end
  end

  describe "CollaborationWorker.perform/1" do
    test "uses the idempotent rebuild path for movie jobs" do
      movie = insert_movie!("Worker Pair Movie", ~D[2008-01-01])
      actor_a = insert_person!("Worker Actor A", 901_014)
      actor_b = insert_person!("Worker Actor B", 901_015)
      insert_cast_credit!(movie, actor_a, 0)
      insert_cast_credit!(movie, actor_b, 1)

      assert :ok = CollaborationWorker.perform(%Oban.Job{args: %{"movie_id" => movie.id}})
      assert :ok = CollaborationWorker.perform(%Oban.Job{args: %{"movie_id" => movie.id}})

      assert Repo.aggregate(CollaborationDetail, :count, :id) == 1
      assert Repo.one!(Collaboration).collaboration_count == 1
    end
  end

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

  defp insert_movie!(title, release_date) do
    tmdb_id = System.unique_integer([:positive])

    %Movie{}
    |> Movie.changeset(%{
      title: title,
      tmdb_id: tmdb_id,
      release_date: release_date,
      import_status: "full"
    })
    |> Repo.insert!()
  end

  defp insert_cast_credit!(movie, person, order) do
    %Credit{}
    |> Credit.changeset(%{
      movie_id: movie.id,
      person_id: person.id,
      credit_type: "cast",
      cast_order: order,
      credit_id: "cast-#{movie.id}-#{person.id}-#{order}"
    })
    |> Repo.insert!()
  end

  defp insert_crew_credit!(movie, person, job) do
    %Credit{}
    |> Credit.changeset(%{
      movie_id: movie.id,
      person_id: person.id,
      credit_type: "crew",
      department: "Crew",
      job: job,
      credit_id: "crew-#{movie.id}-#{person.id}-#{job}"
    })
    |> Repo.insert!()
  end
end
