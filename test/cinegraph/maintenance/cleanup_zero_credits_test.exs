defmodule Cinegraph.Maintenance.CleanupZeroCreditsTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Maintenance.CleanupZeroCredits
  alias Cinegraph.Movies.{Credit, Movie, Person}
  alias Cinegraph.Repo

  describe "enqueue_refetch/1 (#745 Phase 1.5 — phase 1)" do
    test "dry-run finds orphan people with a tmdb_id" do
      _orphan = plant_orphan!(tmdb_id: 999_001)
      _has_credit = plant_with_credit!()

      assert {:ok, %{found: 1, dry_run: true, phase: :enqueue}} =
               CleanupZeroCredits.enqueue_refetch(dry_run: true)
    end

    test "non-dry-run enqueues TMDbDetailsWorker per orphan" do
      plant_orphan!(tmdb_id: 999_002)
      plant_orphan!(tmdb_id: 999_003)

      assert {:ok, %{found: 2, enqueued: 2}} = CleanupZeroCredits.enqueue_refetch([])
      assert tmdb_details_job_count() == 2
    end

    test "respects :limit cap" do
      Enum.each(1..3, fn _ -> plant_orphan!() end)

      assert {:ok, %{found: 2}} = CleanupZeroCredits.enqueue_refetch(limit: 2, dry_run: true)
    end
  end

  describe "delete_still_orphaned/1 (#745 Phase 1.5 — phase 2)" do
    test "deletes orphan rows whose tmdb_id is set" do
      orphan = plant_orphan!(tmdb_id: 999_004)

      assert {:ok, %{found: 1, deleted: 1, phase: :delete}} =
               CleanupZeroCredits.delete_still_orphaned([])

      refute Repo.get(Person, orphan.id)
    end

    # Note: `delete_each/1` re-checks credits inside its transaction so that
    # a credit landing between the candidate-set query and the delete itself
    # is honoured (skipped, not deleted). That race is hard to test
    # deterministically without mocking time, so we don't cover it here —
    # but the implementation has the safety re-check.

    test "dry-run reports counts but does not delete" do
      orphan = plant_orphan!(tmdb_id: 999_007)

      assert {:ok, %{found: 1, deleted: 0, dry_run: true}} =
               CleanupZeroCredits.delete_still_orphaned(dry_run: true)

      assert Repo.get(Person, orphan.id)
    end

    test "respects :limit cap" do
      Enum.each(1..3, fn _ -> plant_orphan!() end)

      assert {:ok, %{found: 2}} =
               CleanupZeroCredits.delete_still_orphaned(limit: 2, dry_run: true)
    end
  end

  describe "run/1 default phase" do
    test "is the enqueue phase" do
      plant_orphan!(tmdb_id: 999_008)

      assert {:ok, %{phase: :enqueue}} = CleanupZeroCredits.run(dry_run: true)
    end
  end

  defp plant_orphan!(opts \\ []) do
    %Person{}
    |> Person.changeset(%{
      tmdb_id: Keyword.get(opts, :tmdb_id, System.unique_integer([:positive])),
      name: "Orphan #{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp plant_with_credit!() do
    person = plant_orphan!()

    movie =
      %Movie{}
      |> Movie.changeset(%{
        tmdb_id: System.unique_integer([:positive]),
        title: "Movie #{System.unique_integer([:positive])}"
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

    person
  end

  defp tmdb_details_job_count do
    import Ecto.Query

    Repo.aggregate(
      from(j in Oban.Job, where: j.worker == "Cinegraph.Workers.TMDbDetailsWorker"),
      :count,
      :id
    )
  end
end
