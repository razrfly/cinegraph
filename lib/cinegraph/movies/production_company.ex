defmodule Cinegraph.Movies.ProductionCompany do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "production_companies" do
    field :tmdb_id, :integer
    field :name, :string
    field :description, :string
    field :headquarters, :string
    field :homepage, :string
    field :logo_path, :string
    field :origin_country, :string
    field :parent_company_id, :integer
    
    many_to_many :movies, Cinegraph.Movies.Movie, join_through: "movie_production_companies"
    
    timestamps()
  end

  @doc false
  def changeset(company, attrs) do
    company
    |> cast(attrs, [
      :tmdb_id, :name, :description, :headquarters, 
      :homepage, :logo_path, :origin_country, :parent_company_id
    ])
    |> validate_required([:tmdb_id, :name])
    |> unique_constraint(:tmdb_id)
  end

  @doc """
  Creates a changeset from TMDB API response data
  """
  def from_tmdb(attrs) do
    company_attrs = %{
      tmdb_id: attrs["id"],
      name: attrs["name"],
      description: attrs["description"],
      headquarters: attrs["headquarters"],
      homepage: attrs["homepage"],
      logo_path: attrs["logo_path"],
      origin_country: attrs["origin_country"],
      parent_company_id: attrs["parent_company"] && attrs["parent_company"]["id"]
    }
    
    changeset(%__MODULE__{}, company_attrs)
  end
end