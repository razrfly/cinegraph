defmodule Cinegraph.Movies.SpokenLanguage do
  use Ecto.Schema
  import Ecto.Changeset

  schema "spoken_languages" do
    field :iso_639_1, :string
    field :name, :string
    field :english_name, :string
    
    many_to_many :movies, Cinegraph.Movies.Movie, join_through: "movie_spoken_languages"
    
    timestamps()
  end

  @doc false
  def changeset(spoken_language, attrs) do
    spoken_language
    |> cast(attrs, [:iso_639_1, :name, :english_name])
    |> validate_required([:iso_639_1, :name])
    |> unique_constraint(:iso_639_1)
  end
end