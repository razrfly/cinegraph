defmodule Cinegraph.Movies.MovieRecommendation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "movie_recommendations" do
    belongs_to :source_movie, Cinegraph.Movies.Movie
    belongs_to :recommended_movie, Cinegraph.Movies.Movie
    
    field :source, :string
    field :type, :string
    field :rank, :integer
    field :score, :float
    field :metadata, :map, default: %{}
    field :fetched_at, :utc_datetime

    timestamps()
  end

  @required_fields [:source_movie_id, :recommended_movie_id, :source, :type, :fetched_at]
  @optional_fields [:rank, :score, :metadata]

  @doc false
  def changeset(recommendation, attrs) do
    recommendation
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:source, ["tmdb", "omdb", "imdb", "letterboxd", "mubi"])
    |> validate_inclusion(:type, ["similar", "recommended", "related", "sequel", "prequel", "collection"])
    |> foreign_key_constraint(:source_movie_id)
    |> foreign_key_constraint(:recommended_movie_id)
    |> unique_constraint([:source_movie_id, :recommended_movie_id, :source, :type])
  end

  @doc """
  Create recommendations from TMDb similar movies response
  """
  def from_tmdb_similar(source_movie_id, similar_movies) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    
    similar_movies
    |> Enum.with_index(1)
    |> Enum.map(fn {movie_data, rank} ->
      %{
        source_movie_id: source_movie_id,
        recommended_movie_id: nil, # Will be resolved later
        source: "tmdb",
        type: "similar",
        rank: rank,
        score: movie_data["vote_average"],
        metadata: %{
          "tmdb_id" => movie_data["id"],
          "title" => movie_data["title"],
          "release_date" => movie_data["release_date"]
        },
        fetched_at: now
      }
    end)
  end

  @doc """
  Create recommendations from TMDb recommendations response
  """
  def from_tmdb_recommended(source_movie_id, recommended_movies) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    
    recommended_movies
    |> Enum.with_index(1)
    |> Enum.map(fn {movie_data, rank} ->
      %{
        source_movie_id: source_movie_id,
        recommended_movie_id: nil, # Will be resolved later
        source: "tmdb",
        type: "recommended",
        rank: rank,
        score: movie_data["vote_average"],
        metadata: %{
          "tmdb_id" => movie_data["id"],
          "title" => movie_data["title"],
          "release_date" => movie_data["release_date"]
        },
        fetched_at: now
      }
    end)
  end
end