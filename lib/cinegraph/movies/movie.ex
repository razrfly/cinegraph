defmodule Cinegraph.Movies.Movie do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @primary_key {:id, :id, autogenerate: true}
  schema "movies" do
    # Core Identity (Never Changes)
    field :tmdb_id, :integer
    field :imdb_id, :string

    # Core Facts (Rarely Change)
    field :title, :string
    field :original_title, :string
    field :release_date, :date
    field :runtime, :integer
    field :overview, :string
    field :tagline, :string
    field :original_language, :string
    field :status, :string
    field :adult, :boolean, default: false
    field :homepage, :string
    field :origin_country, {:array, :string}, default: []

    # Media & Collections
    field :poster_path, :string
    field :backdrop_path, :string
    field :collection_id, :integer

    # System Fields
    field :tmdb_data, :map
    field :omdb_data, :map
    field :import_status, :string, default: "full"
    field :canonical_sources, :map, default: %{}

    # Associations  
    has_many :movie_credits, Cinegraph.Movies.Credit, foreign_key: :movie_id
    many_to_many :people, Cinegraph.Movies.Person, join_through: Cinegraph.Movies.Credit

    # New associations for genres, countries, and languages
    many_to_many :genres, Cinegraph.Movies.Genre,
      join_through: "movie_genres",
      join_keys: [movie_id: :id, genre_id: :id]

    many_to_many :production_countries, Cinegraph.Movies.ProductionCountry,
      join_through: "movie_production_countries",
      join_keys: [movie_id: :id, production_country_id: :id]

    many_to_many :spoken_languages, Cinegraph.Movies.SpokenLanguage,
      join_through: "movie_spoken_languages",
      join_keys: [movie_id: :id, spoken_language_id: :id]

    # Keywords and Production Companies (many-to-many through join tables)
    many_to_many :keywords, Cinegraph.Movies.Keyword,
      join_through: "movie_keywords",
      join_keys: [movie_id: :id, keyword_id: :id]

    many_to_many :production_companies, Cinegraph.Movies.ProductionCompany,
      join_through: "movie_production_companies",
      join_keys: [movie_id: :id, production_company_id: :id]

    # Videos and Release Dates
    has_many :movie_videos, Cinegraph.Movies.MovieVideo, foreign_key: :movie_id
    has_many :movie_release_dates, Cinegraph.Movies.MovieReleaseDate, foreign_key: :movie_id

    # External data associations  
    has_many :external_metrics, Cinegraph.Movies.ExternalMetric, foreign_key: :movie_id

    has_many :external_recommendations, Cinegraph.Movies.MovieRecommendation,
      foreign_key: :source_movie_id

    # Virtual fields for discovery scoring
    field :discovery_score, :float, virtual: true
    field :score_components, :map, virtual: true

    timestamps()
  end

  @doc false
  def changeset(movie, attrs) do
    movie
    |> cast(attrs, [
      :tmdb_id,
      :imdb_id,
      :title,
      :original_title,
      :release_date,
      :runtime,
      :overview,
      :tagline,
      :original_language,
      :status,
      :adult,
      :homepage,
      :collection_id,
      :poster_path,
      :backdrop_path,
      :tmdb_data,
      :omdb_data,
      :origin_country,
      :import_status,
      :canonical_sources
    ])
    |> validate_required([:title])
    |> unique_constraint(:tmdb_id)
    |> unique_constraint(:imdb_id)
  end

  @doc """
  Creates a changeset from TMDB API response data
  Note: Volatile metrics (vote_average, popularity, budget, etc.) are now stored in external_metrics table
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
      status: attrs["status"],
      adult: attrs["adult"],
      homepage: attrs["homepage"],
      collection_id: extract_collection_id(attrs["belongs_to_collection"]),
      poster_path: attrs["poster_path"],
      backdrop_path: attrs["backdrop_path"],
      origin_country: attrs["origin_country"] || [],
      tmdb_data: attrs
    }

    movie_attrs
  end

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

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

  @doc """
  Gets the release year from release_date
  """
  def release_year(%__MODULE__{release_date: nil}), do: nil
  def release_year(%__MODULE__{release_date: date}), do: date.year

  @doc """
  Checks if a movie is in a canonical source. source_key is required.
  """
  def is_canonical?(%__MODULE__{canonical_sources: sources}, source_key) do
    case Map.get(sources || %{}, source_key) do
      %{"included" => true} -> true
      _ -> false
    end
  end

  @doc """
  Gets canonical metadata for a specific source
  """
  def canonical_metadata(%__MODULE__{canonical_sources: sources}, source_key) do
    Map.get(sources || %{}, source_key, %{})
  end

  @doc """
  Checks if movie is canonical in any source
  """
  def is_canonical_any?(%__MODULE__{canonical_sources: sources}) do
    sources != %{} && sources != nil
  end

  @doc """
  Lists all canonical sources for this movie
  """
  def canonical_source_keys(%__MODULE__{canonical_sources: sources}) do
    Map.keys(sources || %{})
  end

  @doc """
  Gets the current vote average from external metrics.
  Returns nil if no rating is available.
  """
  def vote_average(%__MODULE__{id: id}) do
    case Cinegraph.Repo.one(
           from em in Cinegraph.Movies.ExternalMetric,
             where:
               em.movie_id == ^id and em.source == "tmdb" and em.metric_type == "rating_average",
             order_by: [desc: em.fetched_at],
             limit: 1,
             select: em.value
         ) do
      nil -> nil
      value -> value
    end
  end

  @doc """
  Gets the current popularity score from external metrics.
  Returns nil if no popularity score is available.
  """
  def popularity(%__MODULE__{id: id}) do
    case Cinegraph.Repo.one(
           from em in Cinegraph.Movies.ExternalMetric,
             where:
               em.movie_id == ^id and em.source == "tmdb" and em.metric_type == "popularity_score",
             order_by: [desc: em.fetched_at],
             limit: 1,
             select: em.value
         ) do
      nil -> nil
      value -> value
    end
  end
end
