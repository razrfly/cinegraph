defmodule Cinegraph.Repo.Migrations.ClampDiscoveryRankingsRecency do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # #1088: `movie_discovery_rankings_mv`'s recency term was `EXP(-0.01 * days_since_release)`.
  # PostgreSQL `exp(float8)` RAISES `22003 numeric_value_out_of_range: underflow` (it does NOT
  # return 0) once the argument drops below ≈ -745 — i.e. any film >~204y old or with a garbage
  # sentinel release_date (year 1 → EXP(-7390)). The `COALESCE(..., 0.5)` can't catch a raised
  # error, so a single such row aborted every REFRESH — the daily sweeper discarded for days and
  # NO public matview refreshed. Clamp the exponent to >= -700 (exp(-700) ≈ 1e-304, in range;
  # ancient films → recency ≈ 0, which is the intended semantics). Postgres has no
  # CREATE OR REPLACE MATERIALIZED VIEW, so we DROP + CREATE and recreate all three indexes.
  #
  # Body is identical to 20260501120000 except the clamped recency_component line.

  def up do
    execute "DROP MATERIALIZED VIEW IF EXISTS movie_discovery_rankings_mv"
    execute(create_sql(clamped_recency()))
    execute(create_indexes())
  end

  def down do
    # DROP MATERIALIZED VIEW cascades its indexes, so no separate index drops needed.
    execute "DROP MATERIALIZED VIEW IF EXISTS movie_discovery_rankings_mv"
    execute(create_sql(unclamped_recency()))
    execute(create_indexes())
  end

  # exp can never underflow: argument floored at -700.
  defp clamped_recency do
    "EXP(GREATEST(-700.0, -1.0 * 0.01::float * GREATEST(0.0, (CURRENT_DATE - COALESCE(m.release_date, CURRENT_DATE))::float)))"
  end

  # original (raises on ancient/sentinel dates) — used only by `down`.
  defp unclamped_recency do
    "EXP(-1.0 * 0.01::float * GREATEST(0.0, (CURRENT_DATE - COALESCE(m.release_date, CURRENT_DATE))::float))"
  end

  defp create_sql(recency_expr) do
    """
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
          #{recency_expr},
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
  end

  defp create_indexes do
    """
    DO $$
    BEGIN
      CREATE UNIQUE INDEX IF NOT EXISTS movie_discovery_rankings_mv_movie_id_idx
        ON movie_discovery_rankings_mv (movie_id);
      CREATE INDEX IF NOT EXISTS movie_discovery_rankings_mv_default_rank_idx
        ON movie_discovery_rankings_mv (
          default_discovery_score DESC NULLS LAST,
          release_date DESC NULLS LAST,
          movie_id
        )
        WHERE import_status = 'full' AND is_released = true;
      CREATE INDEX IF NOT EXISTS movie_discovery_rankings_mv_poster_rank_idx
        ON movie_discovery_rankings_mv (
          has_poster,
          default_discovery_score DESC NULLS LAST,
          release_date DESC NULLS LAST,
          movie_id
        )
        WHERE import_status = 'full' AND is_released = true;
    END $$;
    """
  end
end
