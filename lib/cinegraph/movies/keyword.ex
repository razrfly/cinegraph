defmodule Cinegraph.Movies.Keyword do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "keywords" do
    field :tmdb_id, :integer
    field :name, :string
    
    many_to_many :movies, Cinegraph.Movies.Movie, join_through: "movie_keywords"
    
    timestamps()
  end

  @doc false
  def changeset(keyword, attrs) do
    keyword
    |> cast(attrs, [:tmdb_id, :name])
    |> validate_required([:tmdb_id, :name])
    |> unique_constraint(:tmdb_id)
  end

  @doc """
  Creates a changeset from TMDB API response data
  """
  def from_tmdb(attrs) do
    keyword_attrs = %{
      tmdb_id: attrs["id"],
      name: attrs["name"]
    }
    
    changeset(%__MODULE__{}, keyword_attrs)
  end
end