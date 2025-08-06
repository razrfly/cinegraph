defmodule Cinegraph.Movies.Genre do
  use Ecto.Schema
  import Ecto.Changeset

  schema "genres" do
    field :tmdb_id, :integer
    field :name, :string

    many_to_many :movies, Cinegraph.Movies.Movie, join_through: "movie_genres"

    timestamps()
  end

  @doc false
  def changeset(genre, attrs) do
    genre
    |> cast(attrs, [:tmdb_id, :name])
    |> validate_required([:tmdb_id, :name])
    |> unique_constraint(:tmdb_id)
  end

  @doc """
  Creates a changeset from TMDB data
  """
  def from_tmdb(tmdb_data) do
    attrs = %{
      tmdb_id: tmdb_data["id"],
      name: tmdb_data["name"]
    }

    changeset(%__MODULE__{}, attrs)
  end
end
