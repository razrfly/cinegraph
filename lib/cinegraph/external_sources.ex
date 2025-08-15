defmodule Cinegraph.ExternalSources do
  @moduledoc """
  The ExternalSources context handles all subjective data from external sources
  like TMDB ratings, Rotten Tomatoes scores, recommendations, etc.
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo
  alias Cinegraph.Movies.{Movie, ExternalMetric, MovieRecommendation}

  @doc """
  Lists all external sources from external_metrics table.
  """
  def list_sources do
    import Ecto.Query
    alias Cinegraph.Movies.ExternalMetric

    # Get unique sources from external_metrics
    query =
      from em in ExternalMetric,
        distinct: em.source,
        select: %{
          id: nil,
          name: em.source,
          source_type: "metric",
          active: true
        }

    Repo.all(query)
  end

  @doc """
  Gets or creates an external source by name (legacy function for compatibility).
  Since sources are now implicit in external_metrics, this returns a mock source.
  """
  def get_or_create_source(name, attrs \\ %{}) do
    # Return a mock source for compatibility
    {:ok,
     %{
       id: nil,
       name: name,
       source_type: Map.get(attrs, :source_type, "metric"),
       active: true
     }}
  end

  @doc """
  Upserts an external metric, replacing any existing metric with the same 
  movie_id, source, and metric_type combination.

  This function overwrites the entire record (latest-value-only strategy).
  Use `Metrics.upsert_metric/1` if you need to preserve historical values 
  with different fetched_at timestamps.

  ## Examples

      iex> upsert_external_metric(%{
      ...>   movie_id: 1,
      ...>   source: "tmdb",
      ...>   metric_type: "popularity",
      ...>   value: 8.5
      ...> })
      {:ok, %ExternalMetric{}}
  """
  def upsert_external_metric(attrs) do
    case %ExternalMetric{}
         |> ExternalMetric.changeset(attrs)
         |> Repo.insert(
           on_conflict: :replace_all_except_primary_key,
           conflict_target: [:movie_id, :source, :metric_type]
         ) do
      {:ok, metric} = result ->
        # Trigger PQS recalculation for external metrics updates
        if metric.movie_id do
          Cinegraph.Metrics.PQSTriggerStrategy.trigger_external_metrics_update(metric.movie_id)
        end
        result
      error ->
        error
    end
  end

  @doc """
  Creates or updates a rating for a movie from an external source (legacy function).
  This now creates external metrics instead of ratings.
  """
  def upsert_rating(attrs) do
    # Convert old rating attrs to external metric format
    metric_attrs = %{
      movie_id: attrs[:movie_id],
      source: attrs[:source_name] || "unknown",
      metric_type: attrs[:rating_type] || "rating_average",
      value: attrs[:value],
      metadata: Map.take(attrs, [:scale_min, :scale_max, :sample_size]),
      fetched_at: attrs[:fetched_at] || DateTime.utc_now()
    }

    upsert_external_metric(metric_attrs)
  end

  @doc """
  Creates or updates a recommendation.
  """
  def upsert_recommendation(attrs) do
    %MovieRecommendation{}
    |> MovieRecommendation.changeset(attrs)
    |> Repo.insert(
      on_conflict: :replace_all,
      conflict_target: [:source_movie_id, :recommended_movie_id, :source, :type]
    )
  end

  @doc """
  Gets all ratings for a movie from external_metrics table.
  """
  def get_movie_ratings(movie_id, source_names \\ nil) do
    import Ecto.Query
    alias Cinegraph.Movies.ExternalMetric

    # Get rating-related metrics for this movie
    query =
      from em in ExternalMetric,
        where: em.movie_id == ^movie_id,
        where: em.metric_type in ["rating_average", "tomatometer", "metascore", "audience_score"],
        order_by: [desc: em.fetched_at]

    query =
      if source_names do
        from em in query, where: em.source in ^source_names
      else
        query
      end

    metrics = Repo.all(query)

    # Convert metrics to a format compatible with the old ratings structure
    Enum.map(metrics, fn metric ->
      %{
        id: metric.id,
        movie_id: metric.movie_id,
        rating_type: metric.metric_type,
        value: metric.value,
        metadata: metric.metadata,
        fetched_at: metric.fetched_at,
        source: %{
          name: metric.source,
          # No longer have separate source table
          id: nil
        }
      }
    end)
  end

  @doc """
  Gets normalized scores across all sources for a movie from external_metrics.
  """
  def get_normalized_scores(movie_id, rating_type \\ "rating_average") do
    from(em in ExternalMetric,
      where: em.movie_id == ^movie_id and em.metric_type == ^rating_type,
      select: %{
        source: em.source,
        # Assume already normalized or handle in app layer
        normalized_score: em.value,
        # Default weight since no source table
        weight: 1.0,
        sample_size: fragment("(?->>'sample_size')::integer", em.metadata),
        raw_value: em.value,
        scale_max: fragment("(?->>'scale_max')::numeric", em.metadata)
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
      from(r in MovieRecommendation,
        join: m in assoc(r, :recommended_movie),
        where: r.source_movie_id == ^movie_id and r.score >= ^min_score,
        order_by: [desc: r.score],
        limit: ^limit,
        preload: [recommended_movie: m]
      )

    query =
      if source_name do
        from [r, m] in query, where: r.source == ^source_name
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
  Stores TMDB subjective data (ratings, popularity) as external metrics.
  """
  def store_tmdb_ratings(movie, tmdb_data) do
    # Use the ExternalMetric.from_tmdb function to create metrics
    metrics = ExternalMetric.from_tmdb(movie.id, tmdb_data)

    # Insert each metric using the centralized function
    results =
      Enum.map(metrics, fn metric_attrs ->
        upsert_external_metric(metric_attrs)
      end)

    # Check if all succeeded
    case Enum.all?(results, fn {status, _} -> status == :ok end) do
      true -> :ok
      false -> {:error, "Failed to store some metrics"}
    end
  end

  @doc """
  Stores TMDB recommendations.
  """
  def store_tmdb_recommendations(source_movie, recommendations_data, recommendation_type) do
    recommendations_data
    |> Enum.with_index(1)
    |> Enum.each(fn {rec_data, rank} ->
      # First ensure the recommended movie exists
      case Repo.get_by(Movie, tmdb_id: rec_data["id"]) do
        nil ->
          # Skip if movie doesn't exist yet
          :ok

        recommended_movie ->
          upsert_recommendation(%{
            source_movie_id: source_movie.id,
            recommended_movie_id: recommended_movie.id,
            source: "tmdb",
            type: recommendation_type,
            rank: rank,
            score: rec_data["vote_average"] || 0.0,
            metadata: %{
              "popularity" => rec_data["popularity"],
              "vote_count" => rec_data["vote_count"]
            },
            fetched_at: DateTime.utc_now()
          })
      end
    end)

    :ok
  end
end
