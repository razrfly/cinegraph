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
    field :vote_average, :float
    field :vote_count, :integer
    field :popularity, :float
    
    # Collection/Franchise
    field :collection_id, :integer
    
    # Images
    field :poster_path, :string
    field :backdrop_path, :string
    
    # TMDb raw data storage
    field :tmdb_data, :map
    
    
    # Associations  
    has_many :movie_credits, Cinegraph.Movies.Credit, foreign_key: :movie_id
    many_to_many :people, Cinegraph.Movies.Person, join_through: Cinegraph.Movies.Credit
    
    # Keywords and Production Companies (many-to-many through join tables)
    many_to_many :keywords, Cinegraph.Movies.Keyword, join_through: "movie_keywords", join_keys: [movie_id: :id, keyword_id: :id]
    many_to_many :production_companies, Cinegraph.Movies.ProductionCompany, join_through: "movie_production_companies", join_keys: [movie_id: :id, production_company_id: :id]
    
    # Videos and Release Dates
    has_many :movie_videos, Cinegraph.Movies.MovieVideo, foreign_key: :movie_id
    has_many :movie_release_dates, Cinegraph.Movies.MovieReleaseDate, foreign_key: :movie_id
    
    # Cultural associations
    has_many :movie_list_items, Cinegraph.Cultural.MovieListItem, foreign_key: :movie_id
    has_many :curated_lists, through: [:movie_list_items, :list]
    has_many :cri_scores, Cinegraph.Cultural.CRIScore, foreign_key: :movie_id
    
    # External data associations  
    has_many :external_ratings, Cinegraph.ExternalSources.Rating, foreign_key: :movie_id
    has_many :external_recommendations, Cinegraph.ExternalSources.Recommendation, foreign_key: :source_movie_id
    
    timestamps()
  end

  @doc false
  def changeset(movie, attrs) do
    movie
    |> cast(attrs, [
      :tmdb_id, :imdb_id, :title, :original_title, :release_date,
      :runtime, :overview, :tagline, :original_language, :budget, :revenue, :status,
      :adult, :homepage, :collection_id, :poster_path, :backdrop_path, :vote_average,
      :vote_count, :popularity, :tmdb_data
    ])
    |> validate_required([:tmdb_id, :title])
    |> unique_constraint(:tmdb_id)
  end

  @doc """
  Creates a changeset from TMDB API response data
  """
  def from_tmdb(attrs) do
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
      vote_average: attrs["vote_average"],
      vote_count: attrs["vote_count"],
      popularity: attrs["popularity"],
      collection_id: extract_collection_id(attrs["belongs_to_collection"]),
      poster_path: attrs["poster_path"],
      backdrop_path: attrs["backdrop_path"],
      tmdb_data: attrs
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

  defp normalize_money_value(nil), do: nil
  defp normalize_money_value(0), do: nil
  defp normalize_money_value(value) when is_integer(value), do: value

  defp extract_collection_id(nil), do: nil
  defp extract_collection_id(%{"id" => id}), do: id

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