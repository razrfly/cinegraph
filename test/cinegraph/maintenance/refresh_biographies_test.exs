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
  end

  describe "ledger-consume — stops churning already-attempted people (#1101 WS1)" do
    test "skips a person with a fresh tmdb_person ledger row; includes past-due and never-attempted" do
      now = DateTime.utc_now()

      %{person: skipped} = plant_canonical_person_missing_bio!()
      ledger_row!(skipped.id, "ok", DateTime.add(now, 86_400, :second))

      %{person: due} = plant_canonical_person_missing_bio!()
      ledger_row!(due.id, "ok", DateTime.add(now, -86_400, :second))

      # never-attempted (no ledger row)
      plant_canonical_person_missing_bio!()

      # 3 planted; the fresh-ledger one is skipped → 2 found (past-due + never-attempted)
      assert {:ok, %{found: 2}} = RefreshBiographies.run(dry_run: true)
    end

    test "skips an ineligible person regardless of stale_after" do
      %{person: inelig} = plant_canonical_person_missing_bio!()
      ledger_row!(inelig.id, "ineligible", nil)

      assert {:ok, %{found: 0}} = RefreshBiographies.run(dry_run: true)
    end

    test "respects error backoff — skips a person still backing off, retries one past backoff" do
      now = DateTime.utc_now()

      %{person: backing_off} = plant_canonical_person_missing_bio!()
      ledger_row!(backing_off.id, "error", DateTime.add(now, 3600, :second))

      %{person: retryable} = plant_canonical_person_missing_bio!()
      ledger_row!(retryable.id, "error", DateTime.add(now, -3600, :second))

      # only the past-backoff error is retried
      assert {:ok, %{found: 1}} = RefreshBiographies.run(dry_run: true)
    end

    test "skips a fresh 'pending' ledger row; retries a past-due one (#1101 WS1)" do
      now = DateTime.utc_now()

      # a backfill reservation still in its window — not yet due, so skip it
      %{person: pending_fresh} = plant_canonical_person_missing_bio!()
      ledger_row!(pending_fresh.id, "pending", DateTime.add(now, 3600, :second))

      # a pending row whose window has elapsed (the backfill marks these due now) → retry
      %{person: pending_due} = plant_canonical_person_missing_bio!()
      ledger_row!(pending_due.id, "pending", DateTime.add(now, -3600, :second))

      assert {:ok, %{found: 1}} = RefreshBiographies.run(dry_run: true)
    end

    test "raises ArgumentError for non-positive :limit" do
      assert_raise ArgumentError, fn -> RefreshBiographies.run(limit: 0) end
    end
  end

  defp ledger_row!(person_id, status, stale_after) do
    stale_after = stale_after && DateTime.truncate(stale_after, :second)
    # keep fetched_at < stale_after to satisfy the temporal validation
    fetched_at = stale_after && DateTime.add(stale_after, -7 * 86_400, :second)

    %Cinegraph.Freshness.DataRefresh{}
    |> Cinegraph.Freshness.DataRefresh.changeset(%{
      entity_type: "person",
      entity_id: person_id,
      source: "tmdb_person",
      status: status,
      stale_after: stale_after,
      fetched_at: fetched_at
    })
    |> Repo.insert!()
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
