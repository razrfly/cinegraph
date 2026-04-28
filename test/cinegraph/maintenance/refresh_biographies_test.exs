defmodule Cinegraph.Maintenance.RefreshBiographiesTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Maintenance.RefreshBiographies
  alias Cinegraph.Movies.{Credit, Movie, Person}
  alias Cinegraph.Repo

  describe "run/1 (#739 Phase A)" do
    test "dry-run returns count without enqueuing" do
      plant_canonical_person_missing_bio!()

      assert {:ok, %{found: 1, enqueued: 0, failed: 0, dry_run: true}} =
               RefreshBiographies.run(dry_run: true)

      assert refresh_job_count() == 0
    end

    test "non-dry-run enqueues one job per affected canonical person" do
      plant_canonical_person_missing_bio!()
      plant_canonical_person_missing_bio!()

      assert {:ok, %{found: 2, enqueued: 2, failed: 0, dry_run: false}} =
               RefreshBiographies.run([])

      assert refresh_job_count() == 2
    end

    test "ignores people on non-canonical movies" do
      # Canonical: should be picked up
      plant_canonical_person_missing_bio!()

      # Non-canonical: should NOT be picked up
      person_excluded =
        %Person{}
        |> Person.changeset(%{
          tmdb_id: System.unique_integer([:positive]),
          name: "Non-Canonical Person",
          biography: nil
        })
        |> Repo.insert!()

      movie_excluded =
        %Movie{}
        |> Movie.changeset(%{
          tmdb_id: System.unique_integer([:positive]),
          title: "Non-Canonical Movie",
          canonical_sources: %{}
        })
        |> Repo.insert!()

      %Credit{}
      |> Credit.changeset(%{
        movie_id: movie_excluded.id,
        person_id: person_excluded.id,
        credit_type: "cast",
        credit_id: "credit-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

      assert {:ok, %{found: 1}} = RefreshBiographies.run(dry_run: true)
    end

    test "ignores canonical people whose biography is populated" do
      # Canonical, populated bio: should NOT be picked up
      person_done =
        %Person{}
        |> Person.changeset(%{
          tmdb_id: System.unique_integer([:positive]),
          name: "Already Has Bio",
          biography: "Hello world"
        })
        |> Repo.insert!()

      movie_canonical =
        %Movie{}
        |> Movie.changeset(%{
          tmdb_id: System.unique_integer([:positive]),
          title: "Canon",
          canonical_sources: %{"1001_movies" => %{"included" => true}}
        })
        |> Repo.insert!()

      %Credit{}
      |> Credit.changeset(%{
        movie_id: movie_canonical.id,
        person_id: person_done.id,
        credit_type: "cast",
        credit_id: "credit-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

      # And one canonical person missing bio (should be picked up)
      plant_canonical_person_missing_bio!()

      assert {:ok, %{found: 1}} = RefreshBiographies.run(dry_run: true)
    end

    test "respects :limit cap" do
      Enum.each(1..3, fn _ -> plant_canonical_person_missing_bio!() end)

      assert {:ok, %{found: 2, enqueued: 2}} = RefreshBiographies.run(limit: 2)
    end

    test "raises ArgumentError for non-positive :limit" do
      assert_raise ArgumentError, fn -> RefreshBiographies.run(limit: 0) end
    end
  end

  defp refresh_job_count do
    import Ecto.Query

    Repo.aggregate(
      from(j in Oban.Job, where: j.worker == "Cinegraph.Workers.PersonTmdbRefreshWorker"),
      :count,
      :id
    )
  end

  defp plant_canonical_person_missing_bio!() do
    person =
      %Person{}
      |> Person.changeset(%{
        tmdb_id: System.unique_integer([:positive]),
        name: "Canonical NoBio #{System.unique_integer([:positive])}",
        biography: nil
      })
      |> Repo.insert!()

    movie =
      %Movie{}
      |> Movie.changeset(%{
        tmdb_id: System.unique_integer([:positive]),
        title: "Canonical Movie #{System.unique_integer([:positive])}",
        canonical_sources: %{"1001_movies" => %{"included" => true}}
      })
      |> Repo.insert!()

    %Credit{}
    |> Credit.changeset(%{
      movie_id: movie.id,
      person_id: person.id,
      credit_type: "cast",
      credit_id: "credit-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()

    %{person: person, movie: movie}
  end
end
