defmodule Cinegraph.Cultural.OscarNomination do
  use Ecto.Schema
  import Ecto.Changeset

  schema "oscar_nominations" do
    belongs_to :ceremony, Cinegraph.Cultural.OscarCeremony
    belongs_to :category, Cinegraph.Cultural.OscarCategory
    belongs_to :movie, Cinegraph.Movies.Movie
    belongs_to :person, Cinegraph.Movies.Person
    
    field :won, :boolean, default: false
    field :details, :map, default: %{}
    
    timestamps()
  end

  @doc false
  def changeset(oscar_nomination, attrs) do
    oscar_nomination
    |> cast(attrs, [:ceremony_id, :category_id, :movie_id, :person_id, :won, :details])
    |> validate_required([:ceremony_id, :category_id, :won])
    |> foreign_key_constraint(:ceremony_id)
    |> foreign_key_constraint(:category_id)
    |> foreign_key_constraint(:movie_id)
    |> foreign_key_constraint(:person_id)
    |> check_constraint(:oscar_nominations, name: :must_have_movie_or_person,
        message: "must have either a movie or person")
  end
end