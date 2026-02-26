defmodule Cinegraph.Movies.ProductionCompany do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "production_companies" do
    field :tmdb_id, :integer
    field :name, :string
    field :logo_path, :string
    field :origin_country, :string

    many_to_many :movies, Cinegraph.Movies.Movie, join_through: "movie_production_companies"

    timestamps()
  end

  @doc false
  def changeset(company, attrs) do
    company
    |> cast(attrs, [
      :tmdb_id,
      :name,
      :logo_path,
      :origin_country
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
      name: truncate(attrs["name"], 255),
      logo_path: truncate(attrs["logo_path"], 255),
      origin_country: truncate(attrs["origin_country"], 255)
    }

    changeset(%__MODULE__{}, company_attrs)
  end

  defp truncate(nil, _max), do: nil
  defp truncate(str, max) when is_binary(str) and byte_size(str) > max, do: String.slice(str, 0, max)
  defp truncate(str, _max), do: str
end
