defmodule Cinegraph.Festivals.FestivalNomination do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "festival_nominations" do
    field :won, :boolean, default: false
    field :prize_name, :string
    field :details, :map, default: %{}

    belongs_to :ceremony, Cinegraph.Festivals.FestivalCeremony
    belongs_to :category, Cinegraph.Festivals.FestivalCategory
    belongs_to :movie, Cinegraph.Movies.Movie
    belongs_to :person, Cinegraph.Movies.Person

    timestamps()
  end

  @doc false
  def changeset(festival_nomination, attrs) do
    festival_nomination
    |> cast(attrs, [:ceremony_id, :category_id, :movie_id, :person_id, :won, :prize_name, :details])
    |> validate_required([:ceremony_id, :category_id, :movie_id])
    |> foreign_key_constraint(:ceremony_id)
    |> foreign_key_constraint(:category_id)
    |> foreign_key_constraint(:movie_id)
    |> foreign_key_constraint(:person_id)
    |> check_constraint(:movie_id, name: :must_have_nominee)
  end
end