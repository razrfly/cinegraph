defmodule Cinegraph.Movies.ProductionCompany do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "production_companies" do
    field :tmdb_id, :integer
    field :name, :string
    field :slug, :string
    field :description, :string
    field :website, :string
    field :logo_path, :string
    field :logo_url, :string
    field :hero_image_url, :string
    field :origin_country, :string
    field :metadata, :map, default: %{}

    many_to_many :movies, Cinegraph.Movies.Movie, join_through: "movie_production_companies"

    timestamps()
  end

  @doc false
  def changeset(company, attrs) do
    company
    |> cast(attrs, [
      :tmdb_id,
      :name,
      :slug,
      :description,
      :website,
      :logo_path,
      :logo_url,
      :hero_image_url,
      :origin_country,
      :metadata
    ])
    |> validate_required([:tmdb_id, :name])
    |> validate_optional_url(:website)
    |> validate_optional_url(:logo_url)
    |> validate_optional_url(:hero_image_url)
    |> maybe_generate_slug()
    |> unique_constraint(:tmdb_id)
    |> unique_constraint(:slug)
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

  defp truncate(str, max) when is_binary(str) and byte_size(str) > max,
    do: String.slice(str, 0, max)

  defp truncate(str, _max), do: str

  defp validate_optional_url(changeset, field) do
    validate_change(changeset, field, fn
      _, value when value in [nil, ""] -> []
      _, value -> url_errors(field, value)
    end)
  end

  defp url_errors(field, url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and not is_nil(host) ->
        []

      _ ->
        [{field, "must be a valid HTTP(S) URL"}]
    end
  end

  defp url_errors(field, _url), do: [{field, "must be a valid HTTP(S) URL"}]

  defp maybe_generate_slug(changeset) do
    case get_field(changeset, :slug) do
      slug when is_binary(slug) and slug != "" ->
        put_change(changeset, :slug, slugify(slug))

      _ ->
        case get_field(changeset, :name) do
          name when is_binary(name) -> put_change(changeset, :slug, slugify(name))
          _ -> changeset
        end
    end
  end

  def slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
  end

  @doc """
  Builds the full TMDb URL for the company logo at the requested size.
  Returns nil when the company has no logo_path stored.
  """
  def logo_url(struct_or_path, size \\ "w92")
  def logo_url(%__MODULE__{logo_path: path}, size), do: logo_url(path, size)
  def logo_url(nil, _size), do: nil
  def logo_url(path, size) when is_binary(path), do: "https://image.tmdb.org/t/p/#{size}#{path}"
end
