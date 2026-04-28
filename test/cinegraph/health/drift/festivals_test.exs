defmodule Cinegraph.Health.Drift.FestivalsTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Festivals.{FestivalCategory, FestivalCeremony, FestivalNomination, FestivalOrganization}
  alias Cinegraph.Health.Drift
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Repo

  setup do
    Cachex.clear(:health_cache)
    :ok
  end

  describe "nominations_below_floor/0 (regression: Decimal.to_float on float)" do
    # Pre-fix, the call raised `FunctionClauseError` in `Decimal.to_float/1`
    # whenever Postgres returned the median as a float (which it does when
    # `percentile_cont` is fed `count(...)::bigint` input). Post-fix, the
    # call returns a real result and `examples[].org_median` is a float.
    test "tolerates a float-typed median (percentile_cont over bigint counts)" do
      org = insert_org!()
      cat = insert_category!(org)

      busy = insert_ceremony!(org, 2020)
      sparse = insert_ceremony!(org, 2021)

      # busy ceremony: 4 nominations (4 distinct movies — unique constraint
      # is on ceremony_id+category_id+movie_id); sparse ceremony: 1 nomination.
      # Per-ceremony counts = [4, 1]; median = 2.5; floor = 0.5 * 2.5 = 1.25.
      # `sparse` (1 nom) is below floor → should appear in examples.
      Enum.each(1..4, fn _ ->
        movie = insert_movie!()
        insert_nomination!(busy, cat, movie)
      end)

      insert_nomination!(sparse, cat, insert_movie!())

      result = Drift.Festivals.nominations_below_floor()

      assert result.check == :nominations_below_floor
      assert result.blocked_reason == nil
      assert result.affected_count >= 1

      Enum.each(result.examples, fn ex ->
        assert is_float(ex.org_median),
               "expected org_median to be a float, got: #{inspect(ex.org_median)}"

        assert is_binary(ex.reason)
      end)
    end
  end

  defp insert_org!() do
    %FestivalOrganization{}
    |> FestivalOrganization.changeset(%{name: "Test Org #{System.unique_integer([:positive])}"})
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
    %FestivalCeremony{
      organization_id: org.id,
      year: year,
      name: "#{org.name} #{year}",
      data_source: "test"
    }
    |> Repo.insert!()
  end

  defp insert_movie!() do
    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      title: "Fixture Movie #{System.unique_integer([:positive])}"
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
