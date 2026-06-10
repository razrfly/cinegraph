defmodule Cinegraph.Workers.FestivalDiscoveryWorkerTest do
  use Cinegraph.DataCase, async: false

  import Cinegraph.FestivalFixtures

  alias Cinegraph.Festivals.{FestivalCeremony, FestivalNomination}
  alias Cinegraph.Repo
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

  describe "create_nomination/4 — re-import repopulates empty details (#1101 WS3)" do
    test "patches an existing empty-payload row's details from a fresh scrape even when person_id is unresolved" do
      # An OLD empty-payload row (written before the #873 shape fix): person_id nil,
      # details blank. tracks_person: false → resolution is skipped (no network), so
      # person_id stays nil and the fresh-payload backfill branch is what runs.
      %{nom: nom, movie: movie, category: category} =
        plant_nomination!(nominee_name: nil, person_imdb_ids: [], tracks_person: false)

      assert is_nil(nom.person_id)
      assert is_nil(nom.details["nominee_names"])

      ceremony = Repo.get!(FestivalCeremony, nom.ceremony_id)

      fresh_nominee = %{
        people: [%{imdb_id: "nm0000225", name: "Christian Slater"}],
        winner: false
      }

      FestivalDiscoveryWorker.create_nomination(movie, fresh_nominee, category, ceremony)

      updated = Repo.get!(FestivalNomination, nom.id)
      assert updated.details["nominee_names"] == "Christian Slater"
      assert updated.details["person_imdb_ids"] == ["nm0000225"]
      # JSONB round-trips atom keys to strings
      assert updated.details["people"] == [
               %{"imdb_id" => "nm0000225", "name" => "Christian Slater"}
             ]

      # still unresolved (it's a film-only category here) — but the payload is now
      # present for a later resolver pass on the real person-tracked rows.
      assert is_nil(updated.person_id)
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
