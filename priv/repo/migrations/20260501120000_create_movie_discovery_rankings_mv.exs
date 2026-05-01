defmodule Cinegraph.Repo.Migrations.CreateMovieDiscoveryRankingsMv do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute """
    CREATE MATERIALIZED VIEW IF NOT EXISTS movie_discovery_rankings_mv AS
    WITH latest_tmdb_metrics AS (
      SELECT DISTINCT ON (movie_id, metric_type)
        movie_id,
        metric_type,
        value
      FROM external_metrics
      WHERE source = 'tmdb'
        AND metric_type IN ('popularity_score', 'rating_votes', 'rating_average')
      ORDER BY movie_id, metric_type, fetched_at DESC NULLS LAST, id DESC
    ),
    metric_pivot AS (
      SELECT
        movie_id,
        MAX(value) FILTER (WHERE metric_type = 'popularity_score') AS popularity_score,
        MAX(value) FILTER (WHERE metric_type = 'rating_votes') AS rating_votes,
        MAX(value) FILTER (WHERE metric_type = 'rating_average') AS rating_average
      FROM latest_tmdb_metrics
      GROUP BY movie_id
    ),
    scored AS (
      SELECT
        m.id AS movie_id,
        m.release_date,
        m.import_status,
        m.poster_path,
        m.poster_path IS NOT NULL AND m.poster_path <> '' AS has_poster,
        COALESCE(m.release_date <= CURRENT_DATE, false) AS is_released,
        mp.popularity_score,
        mp.rating_average,
        mp.rating_votes,
        COALESCE(
          EXP(-1.0 * 0.01::float * GREATEST(0.0, (CURRENT_DATE - COALESCE(m.release_date, CURRENT_DATE))::float)),
          0.5
        ) AS recency_component,
        COALESCE(
          LN(GREATEST(mp.popularity_score::float, 1.0) + 1.0) / LN(1000.0),
          0.0
        ) AS popularity_component,
        COALESCE(
          LN(GREATEST(mp.rating_votes::float, 1.0) + 1.0) / LN(100000.0),
          0.0
        ) AS votes_component,
        COALESCE(
          CASE
            WHEN mp.rating_votes IS NOT NULL
             AND mp.rating_average IS NOT NULL
             AND mp.rating_votes >= 10::float THEN mp.rating_average::float / 10.0
            WHEN mp.rating_votes IS NOT NULL
             AND mp.rating_average IS NOT NULL THEN 0.5
            ELSE NULL
          END,
          0.5
        ) AS rating_component,
        CURRENT_DATE AS calculated_for_date,
        NOW()::timestamp without time zone AS refreshed_at
      FROM movies m
      LEFT JOIN metric_pivot mp ON mp.movie_id = m.id
    )
    SELECT
      movie_id,
      release_date,
      import_status,
      poster_path,
      has_poster,
      is_released,
      popularity_score,
      rating_average,
      rating_votes,
      recency_component,
      popularity_component,
      votes_component,
      rating_component,
      (
        0.35::float * recency_component +
        0.35::float * popularity_component +
        0.20::float * votes_component +
        0.10::float * rating_component
      ) AS default_discovery_score,
      CASE
        WHEN rating_votes >= 1000 AND rating_average >= 7.0 THEN 'strong_signal'
        WHEN rating_votes >= 10 THEN 'rated'
        WHEN popularity_score IS NOT NULL THEN 'popular'
        ELSE 'limited_signal'
      END AS quality_bucket,
      calculated_for_date,
      refreshed_at
    FROM scored
    """

    execute """
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS movie_discovery_rankings_mv_movie_id_idx
    ON movie_discovery_rankings_mv (movie_id)
    """

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS movie_discovery_rankings_mv_default_rank_idx
    ON movie_discovery_rankings_mv (
      default_discovery_score DESC NULLS LAST,
      release_date DESC NULLS LAST,
      movie_id
    )
    WHERE import_status = 'full'
      AND is_released = true
    """

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS movie_discovery_rankings_mv_poster_rank_idx
    ON movie_discovery_rankings_mv (
      has_poster,
      default_discovery_score DESC NULLS LAST,
      release_date DESC NULLS LAST,
      movie_id
    )
    WHERE import_status = 'full'
      AND is_released = true
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS movie_discovery_rankings_mv_poster_rank_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS movie_discovery_rankings_mv_default_rank_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS movie_discovery_rankings_mv_movie_id_idx"
    execute "DROP MATERIALIZED VIEW IF EXISTS movie_discovery_rankings_mv"
  end
end
