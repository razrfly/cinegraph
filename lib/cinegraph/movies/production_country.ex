defmodule Cinegraph.Movies.ProductionCountry do
  use Ecto.Schema
  import Ecto.Changeset

  schema "production_countries" do
    field :iso_3166_1, :string
    field :name, :string
    
    many_to_many :movies, Cinegraph.Movies.Movie, join_through: "movie_production_countries"
    
    timestamps()
  end

  @doc false
  def changeset(production_country, attrs) do
    production_country
    |> cast(attrs, [:iso_3166_1, :name])
    |> validate_required([:iso_3166_1, :name])
    |> unique_constraint(:iso_3166_1)
  end
end