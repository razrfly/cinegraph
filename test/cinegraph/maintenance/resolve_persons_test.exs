defmodule Cinegraph.Maintenance.ResolvePersonsTest do
  use Cinegraph.DataCase, async: false

  import Cinegraph.FestivalFixtures

  alias Cinegraph.Maintenance.ResolvePersons

  describe "run/1 (#739 Phase A)" do
    test "dry-run returns count without enqueuing" do
      _nom = plant_nomination!(nominee_name: "Cillian Murphy", person_name: "Cillian Murphy")

      assert {:ok, %{found: 1, enqueued: 0, failed: 0, dry_run: true}} =
               ResolvePersons.run(dry_run: true)

      assert resolver_job_count() == 0
    end

    test "non-dry-run enqueues one job per affected nomination" do
      _nom = plant_nomination!(nominee_name: "Cillian Murphy", person_name: "Cillian Murphy")

      assert {:ok, %{found: 1, enqueued: 1, failed: 0, dry_run: false}} = ResolvePersons.run([])

      assert resolver_job_count() == 1
    end

    test "scopes by :org abbreviation" do
      # Plant two noms under different orgs (plant_nomination! creates a new org each call)
      %{nom: nom_a, org: org_a} = plant_nomination!(nominee_name: "Person A", person_name: "Person A")

      _nom_b = plant_nomination!(nominee_name: "Person B", person_name: "Person B")

      # Set a known abbreviation on org_a
      Cinegraph.Festivals.FestivalOrganization.changeset(org_a, %{abbreviation: "AAA"})
      |> Cinegraph.Repo.update!()

      assert {:ok, %{found: 1, enqueued: 1}} = ResolvePersons.run(org: "AAA")

      jobs = resolver_jobs()
      assert length(jobs) == 1
      assert hd(jobs).args["nomination_id"] == nom_a.id
    end

    test "respects :limit cap" do
      _ = plant_nomination!(nominee_name: "A", person_name: "A")
      _ = plant_nomination!(nominee_name: "B", person_name: "B")
      _ = plant_nomination!(nominee_name: "C", person_name: "C")

      assert {:ok, %{found: 2, enqueued: 2}} = ResolvePersons.run(limit: 2)
    end

    test "raises ArgumentError for non-positive :limit" do
      assert_raise ArgumentError, fn -> ResolvePersons.run(limit: 0) end
      assert_raise ArgumentError, fn -> ResolvePersons.run(limit: -5) end
    end
  end

  defp resolver_jobs do
    import Ecto.Query

    Cinegraph.Repo.all(
      from j in Oban.Job,
        where: j.worker == "Cinegraph.Workers.NominationPersonResolver"
    )
  end

  defp resolver_job_count, do: length(resolver_jobs())
end
