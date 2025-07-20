defmodule Cinegraph.Movies.Movie do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "movies" do
    field :tmdb_id, :integer
    field :imdb_id, :string
    field :title, :string
    field :original_title, :string
    field :release_date, :date
    field :runtime, :integer
    field :overview, :string
    field :tagline, :string
    field :original_language, :string
    field :budget, :integer
    field :revenue, :integer
    field :status, :string
    field :adult, :boolean, default: false
    field :homepage, :string
    
    # Collection/Franchise
    field :collection_id, :integer
    
    # Images
    field :poster_path, :string
    field :backdrop_path, :string
    field :images, :map, default: %{}
    
    # Arrays
    field :genre_ids, {:array, :integer}, default: []
    field :spoken_languages, {:array, :string}, default: []
    field :production_countries, {:array, :string}, default: []
    field :production_company_ids, {:array, :integer}, default: []
    
    # External IDs
    field :external_ids, :map, default: %{}
    
    # Metadata
    field :tmdb_raw_data, :map
    field :tmdb_fetched_at, :utc_datetime
    field :tmdb_last_updated, :utc_datetime
    
    
    # Associations
    has_many :credits, Cinegraph.Movies.Credit, foreign_key: :movie_id
    many_to_many :people, Cinegraph.Movies.Person, join_through: Cinegraph.Movies.Credit
    
    timestamps()
  end

  @doc false
  def changeset(movie, attrs) do
    movie
    |> cast(attrs, [
      :tmdb_id, :imdb_id, :title, :original_title, :release_date,
      :runtime, :overview, :tagline, :original_language, :budget, :revenue, :status,
      :adult, :homepage, :collection_id, :poster_path, :backdrop_path,
      :images, :genre_ids, :spoken_languages, :production_countries,
      :production_company_ids, :external_ids, :tmdb_raw_data, :tmdb_fetched_at, 
      :tmdb_last_updated
    ])
    |> validate_required([:tmdb_id, :title])
    |> unique_constraint(:tmdb_id)
  end

  @doc """
  Creates a changeset from TMDB API response data
  """
  def from_tmdb(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    
    movie_attrs = %{
      tmdb_id: attrs["id"],
      imdb_id: attrs["imdb_id"],
      title: attrs["title"],
      original_title: attrs["original_title"],
      release_date: parse_date(attrs["release_date"]),
      runtime: attrs["runtime"],
      overview: attrs["overview"],
      tagline: attrs["tagline"],
      original_language: attrs["original_language"],
      budget: normalize_money_value(attrs["budget"]),
      revenue: normalize_money_value(attrs["revenue"]),
      status: attrs["status"],
      adult: attrs["adult"],
      homepage: attrs["homepage"],
      collection_id: extract_collection_id(attrs["belongs_to_collection"]),
      poster_path: attrs["poster_path"],
      backdrop_path: attrs["backdrop_path"],
      images: extract_images(attrs["images"]),
      genre_ids: extract_genre_ids(attrs["genres"]),
      spoken_languages: extract_language_codes(attrs["spoken_languages"]),
      production_countries: extract_country_codes(attrs["production_countries"]),
      production_company_ids: extract_company_ids(attrs["production_companies"]),
      external_ids: attrs["external_ids"] || %{},
      tmdb_raw_data: attrs,
      tmdb_fetched_at: now,
      tmdb_last_updated: now
    }
    
    changeset(%__MODULE__{}, movie_attrs)
  end

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil
  defp parse_date(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp extract_genre_ids(nil), do: []
  defp extract_genre_ids(genres) when is_list(genres) do
    Enum.map(genres, & &1["id"])
  end

  defp extract_language_codes(nil), do: []
  defp extract_language_codes(languages) when is_list(languages) do
    Enum.map(languages, & &1["iso_639_1"])
  end

  defp extract_country_codes(nil), do: []
  defp extract_country_codes(countries) when is_list(countries) do
    Enum.map(countries, & &1["iso_3166_1"])
  end

  defp normalize_money_value(nil), do: nil
  defp normalize_money_value(0), do: nil
  defp normalize_money_value(value) when is_integer(value), do: value

  defp extract_collection_id(nil), do: nil
  defp extract_collection_id(%{"id" => id}), do: id

  defp extract_company_ids(nil), do: []
  defp extract_company_ids(companies) when is_list(companies) do
    Enum.map(companies, & &1["id"])
  end

  defp extract_images(nil), do: %{}
  defp extract_images(images_data) when is_map(images_data) do
    %{
      "posters" => images_data["posters"] || [],
      "backdrops" => images_data["backdrops"] || [],
      "logos" => images_data["logos"] || []
    }
  end

  @doc """
  Builds the full URL for an image
  """
  def image_url(path, size \\ "w500")
  def image_url(nil, _size), do: nil
  def image_url(path, size) do
    "https://image.tmdb.org/t/p/#{size}#{path}"
  end

  def poster_url(%__MODULE__{poster_path: path}, size \\ "w500") do
    image_url(path, size)
  end

  def backdrop_url(%__MODULE__{backdrop_path: path}, size \\ "w1280") do
    image_url(path, size)
  end
end