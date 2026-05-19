defmodule Cinegraph.Workers.FestivalDiscoveryWorkerTest do
  use Cinegraph.DataCase, async: false

  import Cinegraph.FestivalFixtures

  alias Cinegraph.Festivals.FestivalNomination
  alias Cinegraph.Workers.FestivalDiscoveryWorker

  describe "extract_nominee_person_data/1 — scraper payload normalization (#873)" do
    test "reads atom-keyed people list (UnifiedFestivalScraper output)" do
      # Scraper emits %{people: [%{imdb_id: ..., name: ...}]} with atom keys
      nominee = %{
        people: [%{imdb_id: "nm0000225", name: "Christian Slater"}],
        winner: true
      }

      {name, ids, people} = FestivalDiscoveryWorker.extract_nominee_person_data(nominee)
      assert name == "Christian Slater"
      assert ids == ["nm0000225"]
      assert people == [%{imdb_id: "nm0000225", name: "Christian Slater"}]
    end

    test "reads string-keyed flat legacy format" do
      nominee = %{
        "name" => "Christian Slater",
        "person_imdb_ids" => ["nm0000225"]
      }

      {name, ids, _people} = FestivalDiscoveryWorker.extract_nominee_person_data(nominee)
      assert name == "Christian Slater"
      assert ids == ["nm0000225"]
    end

    test "reads string-keyed people list" do
      nominee = %{
        "people" => [%{"imdb_id" => "nm0000225", "name" => "Christian Slater"}]
      }

      {name, ids, _people} = FestivalDiscoveryWorker.extract_nominee_person_data(nominee)
      assert name == "Christian Slater"
      assert ids == ["nm0000225"]
    end

    test "collects all imdb_ids from multiple people" do
      nominee = %{
        people: [
          %{imdb_id: "nm0000225", name: "Christian Slater"},
          %{imdb_id: "nm0000001", name: "Other Person"}
        ]
      }

      {name, ids, _} = FestivalDiscoveryWorker.extract_nominee_person_data(nominee)
      assert name == "Christian Slater"
      assert ids == ["nm0000225", "nm0000001"]
    end

    test "returns nil name and empty ids for empty nominee" do
      {name, ids, people} = FestivalDiscoveryWorker.extract_nominee_person_data(%{})
      assert is_nil(name)
      assert ids == []
      assert people == []
    end

    test "flat name takes precedence over people-list fallback" do
      nominee = %{
        name: "Explicit Name",
        people: [%{imdb_id: "nm0000225", name: "People List Name"}]
      }

      {name, _ids, _} = FestivalDiscoveryWorker.extract_nominee_person_data(nominee)
      assert name == "Explicit Name"
    end
  end

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
