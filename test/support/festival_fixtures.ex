defmodule Cinegraph.FestivalFixtures do
  @moduledoc """
  Shared test fixtures for festival nominations and their dependencies.

  `plant_nomination!/1` builds a fully-wired Person → Movie → Credit →
  Organization → Category → Ceremony → Nomination chain so a single call
  yields a nomination ready for resolver tests.
  """

  alias Cinegraph.Festivals.{
    FestivalCategory,
    FestivalCeremony,
    FestivalNomination,
    FestivalOrganization
  }

  alias Cinegraph.Movies.{Credit, Movie, Person}
  alias Cinegraph.Repo

  def plant_nomination!(opts \\ []) do
    nominee_name = Keyword.get(opts, :nominee_name, "Cillian Murphy")
    person_name = Keyword.get(opts, :person_name, nominee_name || "Cillian Murphy")
    person_imdb_ids = Keyword.get(opts, :person_imdb_ids, [])
    person_imdb_id = Keyword.get(opts, :person_imdb_id)
    tracks_person = Keyword.get(opts, :tracks_person, true)

    person_attrs =
      %{tmdb_id: System.unique_integer([:positive]), name: person_name}
      |> maybe_put(:imdb_id, person_imdb_id)

    person =
      %Person{}
      |> Person.changeset(person_attrs)
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

    %{nom: nom, person: person, movie: movie, category: category, org: org}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
