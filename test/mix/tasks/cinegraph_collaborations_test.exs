defmodule Mix.Tasks.Cinegraph.CollaborationsTest do
  use Cinegraph.DataCase, async: false
  use Oban.Testing, repo: Cinegraph.Repo

  import ExUnit.CaptureIO

  alias Cinegraph.Movies.{Credit, Movie, Person}
  alias Cinegraph.Workers.CollaborationWorker

  describe "run/1" do
    test "--health --json emits JSON stats" do
      Mix.Task.reenable("cinegraph.collaborations")

      output =
        capture_io(fn ->
          Mix.Tasks.Cinegraph.Collaborations.run(["--health", "--json"])
        end)

      assert %{"coverage_pct" => _, "missing_collaboration_details" => _} =
               Jason.decode!(output)
    end

    test "--backfill --dry-run does not enqueue jobs" do
      movie = insert_movie!()
      add_actor_pair!(movie)
      Mix.Task.reenable("cinegraph.collaborations")

      output =
        capture_io(fn ->
          Mix.Tasks.Cinegraph.Collaborations.run(["--backfill", "--dry-run", "--json"])
        end)

      assert %{"dry_run" => true, "found" => 1, "enqueued" => 0} = Jason.decode!(output)
      refute_enqueued(worker: CollaborationWorker, args: %{"movie_id" => movie.id})
    end
  end

  defp add_actor_pair!(movie) do
    actor_a = insert_person!("Task Actor A", 950_001)
    actor_b = insert_person!("Task Actor B", 950_002)

    insert_cast_credit!(movie, actor_a, 0)
    insert_cast_credit!(movie, actor_b, 1)
  end

  defp insert_movie! do
    %Movie{}
    |> Movie.changeset(%{
      title: "Task Movie",
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
      credit_id: "task-cast-#{movie.id}-#{person.id}-#{order}"
    })
    |> Repo.insert!()
  end
end
