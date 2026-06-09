defmodule Cinegraph.People.LatestCreditTest do
  @moduledoc "#1096 Phase B — the age-tier base_date for the tmdb_person strategy."
  use Cinegraph.DataCase, async: true

  alias Cinegraph.People
  alias Cinegraph.Movies.{Credit, Movie, Person}
  alias Cinegraph.Repo

  defp movie!(date) do
    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      title: "M",
      release_date: date
    })
    |> Repo.insert!()
  end

  defp person! do
    %Person{}
    |> Person.changeset(%{tmdb_id: System.unique_integer([:positive]), name: "P"})
    |> Repo.insert!()
  end

  defp credit!(m, p) do
    %Credit{}
    |> Credit.changeset(%{
      movie_id: m.id,
      person_id: p.id,
      credit_type: "cast",
      credit_id: "c#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  test "returns the most recent dated credit, ignoring undated movies" do
    p = person!()
    credit!(movie!(~D[2001-01-01]), p)
    credit!(movie!(~D[2019-06-01]), p)
    credit!(movie!(nil), p)

    assert People.latest_credit_date(p.id) == ~D[2019-06-01]
  end

  test "returns nil for a person with no dated credits" do
    p = person!()
    credit!(movie!(nil), p)
    assert is_nil(People.latest_credit_date(p.id))
  end
end
