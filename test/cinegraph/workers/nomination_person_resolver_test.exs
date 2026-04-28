defmodule Cinegraph.Workers.NominationPersonResolverTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Festivals.{
    FestivalCategory,
    FestivalCeremony,
    FestivalNomination,
    FestivalOrganization
  }

  alias Cinegraph.Movies.{Credit, Movie, Person}
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

  # Small helper — mimics Oban.Testing.perform_job/2 for projects that don't
  # use it in `data_case`. Builds a job struct and dispatches.
  defp perform_job(worker_module, args) do
    job = %Oban.Job{args: args, attempt: 1, max_attempts: 3}
    worker_module.perform(job)
  end

  defp plant_nomination!(opts \\ []) do
    nominee_name = Keyword.get(opts, :nominee_name, "Cillian Murphy")
    person_imdb_ids = Keyword.get(opts, :person_imdb_ids, [])

    person =
      %Person{}
      |> Person.changeset(%{
        tmdb_id: System.unique_integer([:positive]),
        name: "Cillian Murphy"
      })
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
        tracks_person: true
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

    %{nom: nom, person: person, movie: movie}
  end
end
