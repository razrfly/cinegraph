defmodule Cinegraph.Festivals.FestivalNomination do
  @moduledoc """
  Schema for festival nominations.
  Replaces the old OscarNomination table.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "festival_nominations" do
    belongs_to :ceremony, Cinegraph.Festivals.FestivalCeremony
    belongs_to :category, Cinegraph.Festivals.FestivalCategory
    belongs_to :movie, Cinegraph.Movies.Movie
    belongs_to :person, Cinegraph.Movies.Person
    
    field :won, :boolean, default: false
    field :details, :map

    timestamps()
  end

  @doc false
  def changeset(nomination, attrs) do
    nomination
    |> cast(attrs, [:ceremony_id, :category_id, :movie_id, :person_id, :won, :details])
    |> validate_required([:ceremony_id, :category_id, :movie_id])
    |> foreign_key_constraint(:ceremony_id)
    |> foreign_key_constraint(:category_id)
    |> foreign_key_constraint(:movie_id)
    |> foreign_key_constraint(:person_id)
  end
end