defmodule Cinegraph.Health.FestivalFloorAuditTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Festivals.{
    FestivalCategory,
    FestivalCeremony,
    FestivalNomination,
    FestivalOrganization
  }

  alias Cinegraph.Health.FestivalFloorAudit
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  setup do
    Cachex.clear(:health_cache)
    :ok
  end

  describe "audit/1" do
    test "groups below-floor ceremonies by organization with deltas" do
      org = insert_org!("AMPAS-test")
      cat = insert_category!(org)

      # Per-ceremony counts: [4, 4, 1]. Median = 4. Floor = 2.
      # The 1-nom ceremony is below floor.
      busy_a = insert_ceremony!(org, 2020)
      busy_b = insert_ceremony!(org, 2021)
      sparse = insert_ceremony!(org, 2022)

      Enum.each(1..4, fn _ -> insert_nomination!(busy_a, cat, insert_movie!()) end)
      Enum.each(1..4, fn _ -> insert_nomination!(busy_b, cat, insert_movie!()) end)
      insert_nomination!(sparse, cat, insert_movie!())

      [%{organization: %{name: name}, ceremonies: ceremonies, below_floor_count: count}] =
        FestivalFloorAudit.audit()

      assert name == "AMPAS-test"
      assert count == 1
      assert [%{year: 2022, nominations: 1, delta_pct: -75.0}] = ceremonies
    end

    test "sorts organizations by below_floor_count descending" do
      heavy_org = insert_org!("Heavy")
      light_org = insert_org!("Light")
      heavy_cat = insert_category!(heavy_org)
      light_cat = insert_category!(light_org)

      # Heavy: 5 ceremonies with 4 noms + 3 ceremonies with 1 nom.
      # Per-ceremony counts: [4,4,4,4,4,1,1,1]; median = 4; floor = 2.
      # → 3 ceremonies below floor.
      Enum.each(1..5, fn _ ->
        c = insert_ceremony!(heavy_org, 2020 + System.unique_integer([:positive]))
        Enum.each(1..4, fn _ -> insert_nomination!(c, heavy_cat, insert_movie!()) end)
      end)

      Enum.each(1..3, fn i ->
        c = insert_ceremony!(heavy_org, 2030 + i)
        insert_nomination!(c, heavy_cat, insert_movie!())
      end)

      # Light: 2 ceremonies with 6 noms + 1 ceremony with 1 nom.
      # Per-ceremony counts: [6,6,1]; median = 6; floor = 3.
      # → 1 ceremony below floor.
      Enum.each(1..2, fn _ ->
        c = insert_ceremony!(light_org, 2020 + System.unique_integer([:positive]))
        Enum.each(1..6, fn _ -> insert_nomination!(c, light_cat, insert_movie!()) end)
      end)

      thin = insert_ceremony!(light_org, 2042)
      insert_nomination!(thin, light_cat, insert_movie!())

      result = FestivalFloorAudit.audit()

      assert [
               %{organization: %{name: "Heavy"}, below_floor_count: 3},
               %{organization: %{name: "Light"}, below_floor_count: 1}
             ] = result
    end

    test "returns empty list when no ceremonies are below floor" do
      org = insert_org!("Even")
      cat = insert_category!(org)

      Enum.each(1..3, fn _ ->
        c = insert_ceremony!(org, 2020 + System.unique_integer([:positive]))
        Enum.each(1..4, fn _ -> insert_nomination!(c, cat, insert_movie!()) end)
      end)

      assert [] = FestivalFloorAudit.audit()
    end
  end

  defp insert_org!(name) do
    %FestivalOrganization{}
    |> FestivalOrganization.changeset(%{
      name: name,
      abbreviation: String.upcase(String.slice(name, 0, 4))
    })
    |> Repo.insert!()
  end

  defp insert_category!(org) do
    %FestivalCategory{}
    |> FestivalCategory.changeset(%{
      organization_id: org.id,
      name: "Best Test #{System.unique_integer([:positive])}",
      tracks_person: false
    })
    |> Repo.insert!()
  end

  defp insert_ceremony!(org, year) do
    %FestivalCeremony{}
    |> FestivalCeremony.changeset(%{
      organization_id: org.id,
      year: year,
      name: "#{org.name} #{year}",
      data_source: "test"
    })
    |> Repo.insert!()
  end

  defp insert_movie!() do
    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      title: "Fixture #{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp insert_nomination!(ceremony, category, movie) do
    %FestivalNomination{}
    |> FestivalNomination.changeset(%{
      ceremony_id: ceremony.id,
      category_id: category.id,
      movie_id: movie.id
    })
    |> Repo.insert!()
  end
end
