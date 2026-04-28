defmodule Cinegraph.Workers.NominationPersonResolverTest do
  use Cinegraph.DataCase, async: false
  use Oban.Testing, repo: Cinegraph.Repo

  import Cinegraph.FestivalFixtures

  alias Cinegraph.Festivals.FestivalNomination
  alias Cinegraph.Repo
  alias Cinegraph.Workers.NominationPersonResolver

  describe "perform/1 (#730 Phase 1a)" do
    test "resolves and persists person_id for a nomination missing it" do
      %{nom: nom, person: person} = plant_nomination!()

      assert {:ok, %{action: :resolved, person_id: person_id}} =
               perform_job(NominationPersonResolver, %{"nomination_id" => nom.id})

      assert person_id == person.id
      assert Repo.get!(FestivalNomination, nom.id).person_id == person.id
    end

    test "no-ops when nomination already has a person_id" do
      %{nom: nom, person: person} = plant_nomination!()

      nom
      |> FestivalNomination.changeset(%{person_id: person.id})
      |> Repo.update!()

      assert {:ok, %{action: :already_resolved, person_id: pid}} =
               perform_job(NominationPersonResolver, %{"nomination_id" => nom.id})

      assert pid == person.id
    end

    test "cancels when the nomination row no longer exists" do
      assert {:cancel, :nomination_not_found} =
               perform_job(NominationPersonResolver, %{"nomination_id" => -1})
    end

    test "succeeds with action: :no_match when resolver returns nil" do
      %{nom: nom} = plant_nomination!(nominee_name: nil, person_imdb_ids: [])

      assert {:ok, %{action: :no_match}} =
               perform_job(NominationPersonResolver, %{"nomination_id" => nom.id})

      assert Repo.get!(FestivalNomination, nom.id).person_id == nil
    end
  end
end
