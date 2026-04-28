defmodule Cinegraph.Workers.FestivalDiscoveryWorkerTest do
  use Cinegraph.DataCase, async: false

  import Cinegraph.FestivalFixtures

  alias Cinegraph.Festivals.FestivalNomination
  alias Cinegraph.Workers.FestivalDiscoveryWorker

  describe "resolve_for_nomination/1 (#730 Phase 1a)" do
    test "matches by credit-based name similarity when person_imdb_ids is empty" do
      %{nom: nom, person: person} =
        plant_nomination!(
          nominee_name: "Cillian Murphy",
          person_name: "Cillian Murphy",
          person_imdb_ids: []
        )

      assert FestivalDiscoveryWorker.resolve_for_nomination(nom) == person.id
    end

    test "matches by IMDb id when person_imdb_ids is populated" do
      %{nom: nom, person: person} =
        plant_nomination!(
          nominee_name: "Some Other Spelling",
          person_name: "Cillian Murphy",
          person_imdb_id: "nm0614165",
          person_imdb_ids: ["nm0614165"]
        )

      assert FestivalDiscoveryWorker.resolve_for_nomination(nom) == person.id
    end

    test "returns nil when both nominee_name and person_imdb_ids are empty" do
      %{nom: nom} =
        plant_nomination!(
          nominee_name: nil,
          person_name: "Anyone",
          person_imdb_ids: []
        )

      assert FestivalDiscoveryWorker.resolve_for_nomination(nom) == nil
    end

    test "returns nil when category does not track persons" do
      %{nom: nom} =
        plant_nomination!(
          nominee_name: "Cillian Murphy",
          person_name: "Cillian Murphy",
          person_imdb_ids: [],
          tracks_person: false
        )

      assert FestivalDiscoveryWorker.resolve_for_nomination(nom) == nil
    end

    test "returns nil when category or movie are not preloaded" do
      %{nom: nom} =
        plant_nomination!(
          nominee_name: "Cillian Murphy",
          person_name: "Cillian Murphy",
          person_imdb_ids: []
        )

      bare = %FestivalNomination{nom | category: nil, movie: nil}
      assert FestivalDiscoveryWorker.resolve_for_nomination(bare) == nil
    end
  end
end
