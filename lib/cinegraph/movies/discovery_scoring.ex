defmodule Cinegraph.Movies.DiscoveryScoring do
  @moduledoc """
  Tunable Movie Discovery System

  Allows users to adjust how different scoring criteria are weighted 
  in their movie search and browsing experience.

  Scoring Dimensions:
  - Popular Opinion (TMDb/IMDb ratings and votes)
  - Critical Acclaim (Metacritic, Rotten Tomatoes)
  - Industry Recognition (Festival awards, Oscar nominations)
  - Cultural Impact (Canonical lists, popularity metrics)
  """

  import Ecto.Query, warn: false
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Movies.DiscoveryCommon

  @default_weights DiscoveryCommon.default_weights()

  @doc """
  Applies discovery scoring to a movie query with user-defined weights.

  ## Parameters
    - query: Base Ecto query for movies
    - weights: Map of scoring dimension weights (0.0 to 1.0)
    - options: Additional options like min_score threshold

  ## Example
      iex> weights = %{popular_opinion: 0.4, critical_acclaim: 0.3, industry_recognition: 0.2, cultural_impact: 0.1}
      iex> DiscoveryScoring.apply_scoring(Movie, weights)
  """
  def apply_scoring(query, weights \\ @default_weights, options \\ %{}) do
    normalized_weights = normalize_weights(weights)
    min_score = Map.get(options, :min_score, 0.0)

    query
    |> add_scoring_subqueries(normalized_weights)
    |> filter_by_min_score(min_score)
    |> order_by_discovery_score()
  end

  @doc """
  Calculates individual scoring components for a movie.
  Useful for displaying score breakdown in UI.
  """
  def calculate_movie_scores(movie_id) do
    %{
      popular_opinion: calculate_popular_opinion(movie_id),
      critical_acclaim: calculate_critical_acclaim(movie_id),
      industry_recognition: calculate_industry_recognition(movie_id),
      cultural_impact: calculate_cultural_impact(movie_id)
    }
  end

  @doc """
  Returns scoring presets for common use cases.
  """
  def get_presets do
    DiscoveryCommon.get_presets()
  end

  # Private functions

  defp normalize_weights(weights) do
    DiscoveryCommon.normalize_weights(weights)
  end

  defp add_scoring_subqueries(query, weights) do
    from(m in query,
      left_lateral_join:
        scores in fragment(
          """
            SELECT 
              -- Popular Opinion Score (TMDb + IMDb ratings)
              COALESCE(
                (
                  SELECT 
                    (COALESCE(tmdb.value, 0) / 10.0 * 0.5) +
                    (COALESCE(imdb.value, 0) / 10.0 * 0.5)
                  FROM movies m2
                  LEFT JOIN LATERAL (
                    SELECT value FROM external_metrics 
                    WHERE movie_id = m2.id AND source = 'tmdb' AND metric_type = 'rating_average'
                    ORDER BY fetched_at DESC LIMIT 1
                  ) tmdb ON true
                  LEFT JOIN LATERAL (
                    SELECT value FROM external_metrics 
                    WHERE movie_id = m2.id AND source = 'imdb' AND metric_type = 'rating_average'
                    ORDER BY fetched_at DESC LIMIT 1
                  ) imdb ON true
                  WHERE m2.id = ?
                ), 0
              ) * ? AS popular_opinion,
              
              -- Critical Acclaim Score (Metacritic + Rotten Tomatoes)
              COALESCE(
                (
                  SELECT 
                    (COALESCE(mc.value, 0) / 100.0 * 0.5) +
                    (COALESCE(rt.value, 0) / 100.0 * 0.5)
                  FROM movies m2
                  LEFT JOIN LATERAL (
                    SELECT value FROM external_metrics 
                    WHERE movie_id = m2.id AND source = 'metacritic' AND metric_type = 'metascore'
                    ORDER BY fetched_at DESC LIMIT 1
                  ) mc ON true
                  LEFT JOIN LATERAL (
                    SELECT value FROM external_metrics 
                    WHERE movie_id = m2.id AND source = 'rotten_tomatoes' AND metric_type = 'tomatometer'
                    ORDER BY fetched_at DESC LIMIT 1
                  ) rt ON true
                  WHERE m2.id = ?
                ), 0
              ) * ? AS critical_acclaim,
              
              -- Industry Recognition Score (Festival awards + nominations)
              COALESCE(
                (
                  SELECT 
                    LEAST(1.0, 
                      (COUNT(CASE WHEN fn.won = true THEN 1 END) * 0.2) +
                      (COUNT(fn.id) * 0.05)
                    )
                  FROM festival_nominations fn
                  WHERE fn.movie_id = ?
                ), 0
              ) * ? AS industry_recognition,
              
              -- Cultural Impact Score (Canonical lists + popularity)
              COALESCE(
                (
                  SELECT 
                    LEAST(1.0,
                      -- Canonical lists presence
                      (CASE 
                        WHEN m2.canonical_sources IS NOT NULL AND m2.canonical_sources != '{}' 
                        THEN (SELECT count(*) FROM jsonb_object_keys(m2.canonical_sources)) * 0.1
                        ELSE 0
                      END) +
                      -- Popularity score normalized
                      (COALESCE(pop.value, 0) / 1000.0)
                    )
                  FROM movies m2
                  LEFT JOIN LATERAL (
                    SELECT value FROM external_metrics 
                    WHERE movie_id = m2.id AND source = 'tmdb' AND metric_type = 'popularity_score'
                    ORDER BY fetched_at DESC LIMIT 1
                  ) pop ON true
                  WHERE m2.id = ?
                ), 0
              ) * ? AS cultural_impact,
              
              -- Total weighted score
              (
                COALESCE(
                  (
                    SELECT 
                      (COALESCE(tmdb.value, 0) / 10.0 * 0.5) +
                      (COALESCE(imdb.value, 0) / 10.0 * 0.5)
                    FROM movies m2
                    LEFT JOIN LATERAL (
                      SELECT value FROM external_metrics 
                      WHERE movie_id = m2.id AND source = 'tmdb' AND metric_type = 'rating_average'
                      ORDER BY fetched_at DESC LIMIT 1
                    ) tmdb ON true
                    LEFT JOIN LATERAL (
                      SELECT value FROM external_metrics 
                      WHERE movie_id = m2.id AND source = 'imdb' AND metric_type = 'rating_average'
                      ORDER BY fetched_at DESC LIMIT 1
                    ) imdb ON true
                    WHERE m2.id = ?
                  ), 0
                ) * ?
              ) +
              (
                COALESCE(
                  (
                    SELECT 
                      (COALESCE(mc.value, 0) / 100.0 * 0.5) +
                      (COALESCE(rt.value, 0) / 100.0 * 0.5)
                    FROM movies m2
                    LEFT JOIN LATERAL (
                      SELECT value FROM external_metrics 
                      WHERE movie_id = m2.id AND source = 'metacritic' AND metric_type = 'metascore'
                      ORDER BY fetched_at DESC LIMIT 1
                    ) mc ON true
                    LEFT JOIN LATERAL (
                      SELECT value FROM external_metrics 
                      WHERE movie_id = m2.id AND source = 'rotten_tomatoes' AND metric_type = 'tomatometer'
                      ORDER BY fetched_at DESC LIMIT 1
                    ) rt ON true
                    WHERE m2.id = ?
                  ), 0
                ) * ?
              ) +
              (
                COALESCE(
                  (
                    SELECT 
                      LEAST(1.0, 
                        (COUNT(CASE WHEN fn.won = true THEN 1 END) * 0.2) +
                        (COUNT(fn.id) * 0.05)
                      )
                    FROM festival_nominations fn
                    WHERE fn.movie_id = ?
                  ), 0
                ) * ?
              ) +
              (
                COALESCE(
                  (
                    SELECT 
                      LEAST(1.0,
                        (CASE 
                          WHEN m2.canonical_sources IS NOT NULL AND m2.canonical_sources != '{}' 
                          THEN (SELECT count(*) FROM jsonb_object_keys(m2.canonical_sources)) * 0.1
                          ELSE 0
                        END) +
                        (COALESCE(pop.value, 0) / 1000.0)
                      )
                    FROM movies m2
                    LEFT JOIN LATERAL (
                      SELECT value FROM external_metrics 
                      WHERE movie_id = m2.id AND source = 'tmdb' AND metric_type = 'popularity_score'
                      ORDER BY fetched_at DESC LIMIT 1
                    ) pop ON true
                    WHERE m2.id = ?
                  ), 0
                ) * ?
              ) AS total_score
          """,
          m.id,
          ^weights.popular_opinion,
          m.id,
          ^weights.critical_acclaim,
          m.id,
          ^weights.industry_recognition,
          m.id,
          ^weights.cultural_impact,
          m.id,
          ^weights.popular_opinion,
          m.id,
          ^weights.critical_acclaim,
          m.id,
          ^weights.industry_recognition,
          m.id,
          ^weights.cultural_impact
        ),
      on: true,
      select_merge: %{
        discovery_score: scores.total_score,
        score_components: %{
          popular_opinion: scores.popular_opinion,
          critical_acclaim: scores.critical_acclaim,
          industry_recognition: scores.industry_recognition,
          cultural_impact: scores.cultural_impact
        }
      }
    )
  end

  defp filter_by_min_score(query, 0.0), do: query

  defp filter_by_min_score(query, min_score) do
    from([m, scores] in query,
      where: scores.total_score >= ^min_score
    )
  end

  defp order_by_discovery_score(query) do
    from([m, scores] in query,
      order_by: [desc: scores.total_score]
    )
  end

  defp calculate_popular_opinion(movie_id) do
    query = """
    SELECT 
      (COALESCE(tmdb.value, 0) / 10.0 * 0.5) +
      (COALESCE(imdb.value, 0) / 10.0 * 0.5) as score
    FROM movies m
    LEFT JOIN LATERAL (
      SELECT value FROM external_metrics 
      WHERE movie_id = m.id AND source = 'tmdb' AND metric_type = 'rating_average'
      ORDER BY fetched_at DESC LIMIT 1
    ) tmdb ON true
    LEFT JOIN LATERAL (
      SELECT value FROM external_metrics 
      WHERE movie_id = m.id AND source = 'imdb' AND metric_type = 'rating_average'
      ORDER BY fetched_at DESC LIMIT 1
    ) imdb ON true
    WHERE m.id = $1
    """

    case Repo.query(query, [movie_id]) do
      {:ok, %{rows: [[score]]}} when not is_nil(score) -> score
      _ -> 0.0
    end
  end

  defp calculate_critical_acclaim(movie_id) do
    query = """
    SELECT 
      (COALESCE(mc.value, 0) / 100.0 * 0.5) +
      (COALESCE(rt.value, 0) / 100.0 * 0.5) as score
    FROM movies m
    LEFT JOIN LATERAL (
      SELECT value FROM external_metrics 
      WHERE movie_id = m.id AND source = 'metacritic' AND metric_type = 'metascore'
      ORDER BY fetched_at DESC LIMIT 1
    ) mc ON true
    LEFT JOIN LATERAL (
      SELECT value FROM external_metrics 
      WHERE movie_id = m.id AND source = 'rotten_tomatoes' AND metric_type = 'tomatometer'
      ORDER BY fetched_at DESC LIMIT 1
    ) rt ON true
    WHERE m.id = $1
    """

    case Repo.query(query, [movie_id]) do
      {:ok, %{rows: [[score]]}} when not is_nil(score) -> score
      _ -> 0.0
    end
  end

  defp calculate_industry_recognition(movie_id) do
    query = """
    SELECT 
      LEAST(1.0, 
        (COUNT(CASE WHEN fn.won = true THEN 1 END) * 0.2) +
        (COUNT(fn.id) * 0.05)
      ) as score
    FROM festival_nominations fn
    WHERE fn.movie_id = $1
    """

    case Repo.query(query, [movie_id]) do
      {:ok, %{rows: [[score]]}} when not is_nil(score) -> score
      _ -> 0.0
    end
  end

  defp calculate_cultural_impact(movie_id) do
    query = """
    SELECT 
      LEAST(1.0,
        (CASE 
          WHEN m.canonical_sources IS NOT NULL AND m.canonical_sources != '{}' 
          THEN (SELECT count(*) FROM jsonb_object_keys(m.canonical_sources)) * 0.1
          ELSE 0
        END) +
        (COALESCE(pop.value, 0) / 1000.0)
      ) as score
    FROM movies m
    LEFT JOIN LATERAL (
      SELECT value FROM external_metrics 
      WHERE movie_id = m.id AND source = 'tmdb' AND metric_type = 'popularity_score'
      ORDER BY fetched_at DESC LIMIT 1
    ) pop ON true
    WHERE m.id = $1
    """

    case Repo.query(query, [movie_id]) do
      {:ok, %{rows: [[score]]}} when not is_nil(score) -> score
      _ -> 0.0
    end
  end
end
