defmodule Cinegraph.Predictions.ListFrontierTest do
  @moduledoc "Frontier warnings, esp. the frozen-edition disagreement suppression (#1049 A0)."
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Movies.{Movie, MovieList}
  alias Cinegraph.Predictions.ListFrontier
  alias Cinegraph.Repo

  defp list!(source_key, metadata) do
    %MovieList{}
    |> MovieList.changeset(%{
      source_key: source_key,
      name: source_key,
      source_type: "imdb",
      source_url: "https://example.com/#{source_key}",
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp member!(source_key, year) do
    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      title: "M#{System.unique_integer([:positive])}",
      canonical_sources: %{source_key => 1},
      release_date: Date.new!(year, 1, 1)
    })
    |> Repo.insert!()
  end

  defp disagrees?(frontier), do: Enum.any?(frontier.warnings, &(&1 =~ "disagrees"))

  describe "edition-disagreement warning" do
    test "frozen list whose edition postdates its newest film → NO disagreement warning" do
      list!("frozen_ok", %{"edition" => "1998", "accretes" => false})
      member!("frozen_ok", 1996)

      f = ListFrontier.resolve("frozen_ok")
      assert f.edition_year == 1998 and f.newest_member_year == 1996
      refute disagrees?(f), "frozen edition>newest must not warn (the AFI 100 false-positive)"
    end

    test "accreting list with the same gap → KEEPS the disagreement warning" do
      list!("accrete_x", %{"edition" => "2025"})
      member!("accrete_x", 2021)

      f = ListFrontier.resolve("accrete_x")
      assert disagrees?(f), "accreting lists keep the honest stale-import flag (the tspdt case)"
    end

    test "frozen list but a member is NEWER than the edition → still warns (real data issue)" do
      list!("frozen_bad", %{"edition" => "1998", "accretes" => false})
      member!("frozen_bad", 2005)

      f = ListFrontier.resolve("frozen_bad")
      assert disagrees?(f), "newest > edition is a genuine problem even for a frozen list"
    end

    test "edition within tolerance → no warning regardless of accretion" do
      list!("aligned", %{"edition" => "2024"})
      member!("aligned", 2024)

      refute disagrees?(ListFrontier.resolve("aligned"))
    end
  end
end
