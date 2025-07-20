defmodule Cinegraph.Movies.Collection do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "collections" do
    field :tmdb_id, :integer
    field :name, :string
    field :overview, :string
    field :poster_path, :string
    field :backdrop_path, :string
    field :images, :map, default: %{}
    
    timestamps()
  end

  @doc false
  def changeset(collection, attrs) do
    collection
    |> cast(attrs, [:tmdb_id, :name, :overview, :poster_path, :backdrop_path, :images])
    |> validate_required([:tmdb_id, :name])
    |> unique_constraint(:tmdb_id)
  end

  @doc """
  Creates a changeset from TMDB API response data
  """
  def from_tmdb(attrs) do
    collection_attrs = %{
      tmdb_id: attrs["id"],
      name: attrs["name"],
      overview: attrs["overview"],
      poster_path: attrs["poster_path"],
      backdrop_path: attrs["backdrop_path"],
      images: extract_images(attrs["images"])
    }
    
    changeset(%__MODULE__{}, collection_attrs)
  end

  defp extract_images(nil), do: %{}
  defp extract_images(images_data) when is_map(images_data) do
    %{
      "posters" => images_data["posters"] || [],
      "backdrops" => images_data["backdrops"] || []
    }
  end
end