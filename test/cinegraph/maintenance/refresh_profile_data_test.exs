defmodule Cinegraph.Maintenance.RefreshProfileDataTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Maintenance.RefreshProfileData
  alias Cinegraph.Movies.{Credit, Movie, Person}
  alias Cinegraph.Repo

  describe "run/1 (#745 Phase 1.3 + 1.6)" do
    test "counts canonical-list people missing profile_path" do
      plant!(canonical: true, profile_path: nil, known_for: "Acting")

      assert {:ok, %{found: 1}} = RefreshProfileData.run(dry_run: true)
    end

    test "counts canonical-list people missing known_for_department" do
      plant!(canonical: true, profile_path: "/abc.jpg", known_for: nil)

      assert {:ok, %{found: 1}} = RefreshProfileData.run(dry_run: true)
    end

    test "ignores non-canonical people regardless of missing fields" do
      plant!(canonical: false, profile_path: nil, known_for: nil)

      assert {:ok, %{found: 0}} = RefreshProfileData.run(dry_run: true)
    end

    test "ignores canonical people with both fields populated" do
      plant!(canonical: true, profile_path: "/x.jpg", known_for: "Acting")

      assert {:ok, %{found: 0}} = RefreshProfileData.run(dry_run: true)
    end

    test "non-dry-run enqueues one PersonTmdbRefreshWorker per affected person" do
      plant!(canonical: true, profile_path: nil, known_for: "Acting")
      plant!(canonical: true, profile_path: nil, known_for: nil)

      assert {:ok, %{found: 2, enqueued: 2}} = RefreshProfileData.run([])
      assert person_refresh_job_count() == 2
    end

    test "respects :limit cap" do
      Enum.each(1..3, fn _ -> plant!(canonical: true, profile_path: nil, known_for: "Acting") end)

      assert {:ok, %{found: 2}} = RefreshProfileData.run(limit: 2, dry_run: true)
    end

    test "raises ArgumentError for non-positive :limit" do
      assert_raise ArgumentError, fn -> RefreshProfileData.run(limit: 0) end
    end
  end

  defp plant!(opts) do
    canonical = Keyword.fetch!(opts, :canonical)
    profile_path = Keyword.fetch!(opts, :profile_path)
    known_for = Keyword.fetch!(opts, :known_for)

    person =
      %Person{}
      |> Person.changeset(%{
        tmdb_id: System.unique_integer([:positive]),
        name: "Person #{System.unique_integer([:positive])}",
        profile_path: profile_path,
        known_for_department: known_for
      })
      |> Repo.insert!()

    movie =
      %Movie{}
      |> Movie.changeset(%{
        tmdb_id: System.unique_integer([:positive]),
        title: "Movie #{System.unique_integer([:positive])}",
        canonical_sources: if(canonical, do: %{"1001_movies" => %{"included" => true}}, else: %{})
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

  defp person_refresh_job_count do
    import Ecto.Query

    Repo.aggregate(
      from(j in Oban.Job, where: j.worker == "Cinegraph.Workers.PersonTmdbRefreshWorker"),
      :count,
      :id
    )
  end
end
