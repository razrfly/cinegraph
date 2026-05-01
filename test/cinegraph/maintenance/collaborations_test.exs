defmodule Cinegraph.Maintenance.CollaborationsTest do
  use Cinegraph.DataCase, async: false
  use Oban.Testing, repo: Cinegraph.Repo

  alias Cinegraph.Collaborations
  alias Cinegraph.Maintenance.Collaborations, as: CollaborationMaintenance
  alias Cinegraph.Movies.{Credit, Movie, Person}
  alias Cinegraph.Workers.{CollaborationRepairSweeper, CollaborationWorker}

  describe "stats/0 and missing_movie_ids/1" do
    test "counts eligible movies without details as missing and covered movies as covered" do
      missing = insert_movie!("Missing Details", ~D[2020-01-01])
      covered = insert_movie!("Covered Details", ~D[2021-01-01])
      single_credit = insert_movie!("Single Credit", ~D[2022-01-01])

      add_actor_pair!(missing)
      add_actor_pair!(covered)
      insert_cast_credit!(single_credit, insert_person!("Solo", 920_001), 0)

      assert {:ok, %{details: 1}} = Collaborations.rebuild_movie_collaborations(covered.id)

      stats = CollaborationMaintenance.stats()

      assert stats.full_movies_with_credits == 2
      assert stats.movies_with_collaboration_details == 1
      assert stats.missing_collaboration_details == 1
      assert stats.coverage_pct == 50.0
      assert CollaborationMaintenance.missing_movie_ids(limit: 10) == [missing.id]
    end
  end

  describe "backfill/1" do
    test "dry run reports found movies without enqueueing jobs" do
      movie = insert_movie!("Dry Run Missing", ~D[2020-01-01])
      add_actor_pair!(movie)

      assert {:ok, %{found: 1, enqueued: 0, failed: 0, dry_run: true}} =
               CollaborationMaintenance.backfill(limit: 10, dry_run: true)

      refute_enqueued(worker: CollaborationWorker, args: %{"movie_id" => movie.id})
    end

    test "enqueues missing movies onto the collaboration queue" do
      movie = insert_movie!("Backfill Missing", ~D[2020-01-01])
      add_actor_pair!(movie)

      assert {:ok, %{found: 1, enqueued: 1, failed: 0, dry_run: false}} =
               CollaborationMaintenance.backfill(limit: 10)

      assert_enqueued(worker: CollaborationWorker, args: %{"movie_id" => movie.id})
    end
  end

  describe "repair_movie/1" do
    test "enqueues exactly the requested movie" do
      movie = insert_movie!("One Repair", ~D[2020-01-01])
      add_actor_pair!(movie)

      assert {:ok, %{movie_id: movie_id, enqueued: 1, failed: 0, has_credits: true}} =
               CollaborationMaintenance.repair_movie(movie.id)

      assert movie_id == movie.id
      assert_enqueued(worker: CollaborationWorker, args: %{"movie_id" => movie.id})
    end
  end

  describe "CollaborationRepairSweeper.perform/1" do
    test "delegates to capped backfill and returns stats" do
      movie = insert_movie!("Sweeper Missing", ~D[2020-01-01])
      add_actor_pair!(movie)

      assert {:ok, %{found: 1, enqueued: 1, failed: 0}} =
               CollaborationRepairSweeper.perform(%Oban.Job{args: %{}})

      assert_enqueued(worker: CollaborationWorker, args: %{"movie_id" => movie.id})
    end
  end

  defp add_actor_pair!(movie) do
    actor_a = insert_person!("Actor A #{movie.id}", 930_000 + movie.id * 2)
    actor_b = insert_person!("Actor B #{movie.id}", 930_001 + movie.id * 2)

    insert_cast_credit!(movie, actor_a, 0)
    insert_cast_credit!(movie, actor_b, 1)
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
      credit_id: "cast-#{movie.id}-#{person.id}-#{order}"
    })
    |> Repo.insert!()
  end
end
