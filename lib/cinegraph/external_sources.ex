defmodule Cinegraph.ExternalSources do
  @moduledoc """
  The ExternalSources context handles all subjective data from external sources
  like TMDB ratings, Rotten Tomatoes scores, recommendations, etc.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo
  alias Cinegraph.ExternalSources.{Source, Rating, Recommendation}
  alias Cinegraph.Movies.Movie

  @doc """
  Lists all external sources.
  """
  def list_sources do
    Repo.all(Source)
  end

  @doc """
  Gets or creates an external source by name.
  """
  def get_or_create_source(name, attrs \\ %{}) do
    case Repo.get_by(Source, name: name) do
      nil ->
        %Source{}
        |> Source.changeset(Map.put(attrs, :name, name))
        |> Repo.insert()

      source ->
        {:ok, source}
    end
  end

  @doc """
  Creates or updates a rating for a movie from an external source.
  """
  def upsert_rating(attrs) do
    %Rating{}
    |> Rating.changeset(attrs)
    |> Repo.insert(
      on_conflict: :replace_all,
      conflict_target: [:movie_id, :source_id, :rating_type]
    )
  end

  @doc """
  Creates or updates a recommendation.
  """
  def upsert_recommendation(attrs) do
    %Recommendation{}
    |> Recommendation.changeset(attrs)
    |> Repo.insert(
      on_conflict: :replace_all,
      conflict_target: [:source_movie_id, :recommended_movie_id, :source_id, :recommendation_type]
    )
  end

  @doc """
  Gets all ratings for a movie, optionally filtered by source.
  """
  def get_movie_ratings(movie_id, source_names \\ nil) do
    query =
      from r in Rating,
        join: s in assoc(r, :source),
        where: r.movie_id == ^movie_id,
        preload: [source: s]

    query =
      if source_names do
        from [r, s] in query, where: s.name in ^source_names
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Gets normalized scores across all sources for a movie.
  """
  def get_normalized_scores(movie_id, rating_type \\ "user") do
    from(r in Rating,
      join: s in assoc(r, :source),
      where: r.movie_id == ^movie_id and r.rating_type == ^rating_type,
      select: %{
        source: s.name,
        normalized_score: fragment("? / ? * 10.0", r.value, r.scale_max),
        weight: s.weight_factor,
        sample_size: r.sample_size,
        raw_value: r.value,
        scale_max: r.scale_max
      }
    )
    |> Repo.all()
  end

  @doc """
  Gets movie recommendations from a source.
  """
  def get_movie_recommendations(movie_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.5)
    source_name = Keyword.get(opts, :source)

    query =
      from(r in Recommendation,
        join: m in assoc(r, :recommended_movie),
        join: s in assoc(r, :source),
        where: r.source_movie_id == ^movie_id and r.score >= ^min_score,
        order_by: [desc: r.score],
        limit: ^limit,
        preload: [recommended_movie: m, source: s]
      )

    query =
      if source_name do
        from [r, m, s] in query, where: s.name == ^source_name
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Calculates weighted average score from multiple sources.
  """
  def calculate_weighted_score(movie_id, rating_type \\ "user") do
    scores = get_normalized_scores(movie_id, rating_type)

    if Enum.empty?(scores) do
      nil
    else
      total_weight = Enum.sum(Enum.map(scores, & &1.weight))
      weighted_sum = Enum.sum(Enum.map(scores, &(&1.normalized_score * &1.weight)))

      weighted_sum / total_weight
    end
  end

  @doc """
  Stores TMDB subjective data (ratings, popularity) as external ratings.
  """
  def store_tmdb_ratings(movie, tmdb_data) do
    with {:ok, source} <-
           get_or_create_source("tmdb", %{
             source_type: "api",
             base_url: "https://api.themoviedb.org/3",
             api_version: "3"
           }) do
      # Store user rating
      if tmdb_data["vote_average"] && tmdb_data["vote_count"] && tmdb_data["vote_count"] > 0 do
        upsert_rating(%{
          movie_id: movie.id,
          source_id: source.id,
          rating_type: "user",
          value: tmdb_data["vote_average"],
          scale_min: 0.0,
          scale_max: 10.0,
          sample_size: tmdb_data["vote_count"],
          fetched_at: DateTime.utc_now()
        })
      end

      # Store popularity score
      if tmdb_data["popularity"] do
        upsert_rating(%{
          movie_id: movie.id,
          source_id: source.id,
          rating_type: "popularity",
          value: tmdb_data["popularity"],
          scale_min: 0.0,
          # TMDB popularity can go very high
          scale_max: 1000.0,
          fetched_at: DateTime.utc_now()
        })
      end

      :ok
    end
  end

  @doc """
  Stores TMDB recommendations.
  """
  def store_tmdb_recommendations(source_movie, recommendations_data, recommendation_type) do
    with {:ok, source} <- get_or_create_source("tmdb") do
      recommendations_data
      |> Enum.with_index(1)
      |> Enum.each(fn {rec_data, _rank} ->
        # First ensure the recommended movie exists
        case Repo.get_by(Movie, tmdb_id: rec_data["id"]) do
          nil ->
            # Skip if movie doesn't exist yet
            :ok

          recommended_movie ->
            upsert_recommendation(%{
              source_movie_id: source_movie.id,
              recommended_movie_id: recommended_movie.id,
              source_id: source.id,
              recommendation_type: recommendation_type,
              score: rec_data["vote_average"] || 0.0,
              metadata: %{
                "popularity" => rec_data["popularity"],
                "vote_count" => rec_data["vote_count"]
              },
              fetched_at: DateTime.utc_now()
            })
        end
      end)
    end
  end
end
