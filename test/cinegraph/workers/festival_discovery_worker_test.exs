defmodule Cinegraph.Workers.FestivalDiscoveryWorkerTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Festivals.{
    FestivalCategory,
    FestivalCeremony,
    FestivalNomination,
    FestivalOrganization
  }

  alias Cinegraph.Movies.{Credit, Movie, Person}
  alias Cinegraph.Repo
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

  # ===== fixture builder =====

  defp plant_nomination!(opts) do
    nominee_name = Keyword.fetch!(opts, :nominee_name)
    person_name = Keyword.fetch!(opts, :person_name)
    person_imdb_ids = Keyword.get(opts, :person_imdb_ids, [])
    person_imdb_id = Keyword.get(opts, :person_imdb_id)
    tracks_person = Keyword.get(opts, :tracks_person, true)

    person =
      %Person{}
      |> Person.changeset(
        Map.merge(
          %{
            tmdb_id: System.unique_integer([:positive]),
            name: person_name
          },
          if(person_imdb_id, do: %{imdb_id: person_imdb_id}, else: %{})
        )
      )
      |> Repo.insert!()

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
      character: "Self",
      cast_order: 0,
      credit_id: "credit-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()

    org =
      %FestivalOrganization{}
      |> FestivalOrganization.changeset(%{
        name: "Test Org #{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    category =
      %FestivalCategory{}
      |> FestivalCategory.changeset(%{
        organization_id: org.id,
        name: "Best Test #{System.unique_integer([:positive])}",
        tracks_person: tracks_person
      })
      |> Repo.insert!()

    ceremony =
      %FestivalCeremony{
        organization_id: org.id,
        year: 2024,
        name: "#{org.name} 2024",
        data_source: "test"
      }
      |> Repo.insert!()

    nom =
      %FestivalNomination{}
      |> FestivalNomination.changeset(%{
        ceremony_id: ceremony.id,
        category_id: category.id,
        movie_id: movie.id,
        details: %{
          "nominee_names" => nominee_name,
          "person_imdb_ids" => person_imdb_ids
        }
      })
      |> Repo.insert!()
      |> Repo.preload([:category, :movie])

    %{nom: nom, person: person, movie: movie, category: category}
  end
end
