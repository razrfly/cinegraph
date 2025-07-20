defmodule Cinegraph.Movies.Genre do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "genres" do
    field :tmdb_id, :integer
    field :name, :string
    
    timestamps()
  end

  @doc false
  def changeset(genre, attrs) do
    genre
    |> cast(attrs, [:tmdb_id, :name])
    |> validate_required([:tmdb_id, :name])
    |> unique_constraint(:tmdb_id)
    |> unique_constraint(:name)
  end

  @doc """
  Creates a changeset from TMDB API response data
  """
  def from_tmdb(attrs) do
    genre_attrs = %{
      tmdb_id: attrs["id"],
      name: attrs["name"]
    }
    
    changeset(%__MODULE__{}, genre_attrs)
  end
end