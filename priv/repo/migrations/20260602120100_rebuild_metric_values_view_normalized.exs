defmodule Cinegraph.Repo.Migrations.RebuildMetricValuesViewNormalized do
  use Ecto.Migration

  # Issue #1036 Session 1, Layer 0: make metric_values_view the canonical, NORMALIZED
  # feed and align its metric_code to the metric_definitions catalog.
  #
  # Changes vs the prior view:
  #   * adds normalized_value (via the existing normalize_metric_value/5 plpgsql fn)
  #   * adds source_key (both already referenced by movie_metrics_live/show.ex, which is
  #     currently BROKEN because the view never emitted them)
  #   * LEFT JOINs each branch to metric_definitions so catalogued rows get their canonical
  #     `code` + normalized value; uncatalogued external rows are preserved (null normalized).
  #
  # LEFT JOINs preserve every prior row, so the admin dashboards keep working.
  def up do
    execute "DROP VIEW IF EXISTS metric_values_view"

    execute """
    CREATE VIEW metric_values_view AS

    -- External metrics (IMDb, TMDb, Metacritic, RT) — joined on (source_type, source_field)
    SELECT
      em.movie_id,
      COALESCE(md.code, CONCAT(em.source, '_', em.metric_type)) AS metric_code,
      em.value::float AS raw_value_numeric,
      NULL::text AS raw_value_text,
      CASE
        WHEN md.id IS NOT NULL
        THEN normalize_metric_value(em.value::float, md.normalization_type,
               md.normalization_params, md.raw_scale_min, md.raw_scale_max)
      END AS normalized_value,
      em.source AS source_type,
      em.source AS source_key,
      em.fetched_at AS observed_at,
      'external_metrics' AS source_table
    FROM external_metrics em
    LEFT JOIN metric_definitions md
      ON md.source_table = 'external_metrics'
     AND md.source_type = em.source
     AND md.source_field = em.metric_type
     AND md.active = true
    WHERE em.value IS NOT NULL

    UNION ALL

    -- Festival nominations (Oscars, Cannes, etc.)
    SELECT
      fn.movie_id,
      fcode.metric_code,
      1::float AS raw_value_numeric,
      CASE WHEN fn.won THEN 'true' ELSE 'false' END AS raw_value_text,
      CASE
        WHEN md.id IS NOT NULL
        THEN normalize_metric_value(1::float, md.normalization_type,
               md.normalization_params, md.raw_scale_min, md.raw_scale_max)
      END AS normalized_value,
      fo.abbreviation AS source_type,
      fo.abbreviation AS source_key,
      fc.date AS observed_at,
      'festival_nominations' AS source_table
    FROM festival_nominations fn
    JOIN festival_ceremonies fc ON fn.ceremony_id = fc.id
    JOIN festival_organizations fo ON fc.organization_id = fo.id
    CROSS JOIN LATERAL (
      SELECT (CASE
        WHEN fo.abbreviation = 'AMPAS' AND fn.won = true THEN 'oscar_wins'
        WHEN fo.abbreviation = 'AMPAS' AND fn.won = false THEN 'oscar_nominations'
        WHEN fo.abbreviation = 'CANNES' AND fn.won = true THEN 'cannes_palme_dor'
        WHEN fo.abbreviation = 'VIFF' AND fn.won = true THEN 'venice_golden_lion'
        WHEN fo.abbreviation = 'BERLINALE' AND fn.won = true THEN 'berlin_golden_bear'
        ELSE CONCAT(LOWER(fo.abbreviation), '_', CASE WHEN fn.won THEN 'win' ELSE 'nom' END)
      END) AS metric_code
    ) fcode
    LEFT JOIN metric_definitions md ON md.code = fcode.metric_code AND md.active = true
    WHERE fn.movie_id IS NOT NULL

    UNION ALL

    -- Canonical sources (1001 Movies, AFI Top 100, etc.) from movies.canonical_sources JSONB
    SELECT
      m.id AS movie_id,
      sources.key AS metric_code,
      cv.num AS raw_value_numeric,
      sources.value::text AS raw_value_text,
      CASE
        WHEN md.id IS NOT NULL
        THEN normalize_metric_value(cv.num, md.normalization_type,
               md.normalization_params, md.raw_scale_min, md.raw_scale_max)
      END AS normalized_value,
      sources.key AS source_type,
      sources.key AS source_key,
      m.updated_at AS observed_at,
      'canonical_sources' AS source_table
    FROM movies m
    CROSS JOIN LATERAL jsonb_each(m.canonical_sources) AS sources(key, value)
    CROSS JOIN LATERAL (
      SELECT (CASE
        WHEN sources.value::text = 'true' THEN 1
        WHEN sources.value::text ~ '^[0-9]+$' THEN sources.value::text::integer
        ELSE NULL
      END)::float AS num
    ) cv
    LEFT JOIN metric_definitions md ON md.code = sources.key AND md.active = true
    WHERE m.canonical_sources IS NOT NULL

    UNION ALL

    -- Person quality scores
    SELECT
      movie_credits.movie_id,
      'person_quality_score' AS metric_code,
      pm.score::float AS raw_value_numeric,
      pm.metric_type AS raw_value_text,
      CASE
        WHEN md.id IS NOT NULL
        THEN normalize_metric_value(pm.score::float, md.normalization_type,
               md.normalization_params, md.raw_scale_min, md.raw_scale_max)
      END AS normalized_value,
      'person_metrics' AS source_type,
      'quality_score' AS source_key,
      pm.calculated_at AS observed_at,
      'person_metrics' AS source_table
    FROM person_metrics pm
    -- dedup: a person with several credits on one movie must emit one row, not N
    JOIN (
      SELECT DISTINCT movie_id, person_id
      FROM movie_credits
      WHERE movie_id IS NOT NULL
    ) movie_credits ON pm.person_id = movie_credits.person_id
    LEFT JOIN metric_definitions md ON md.code = 'person_quality_score' AND md.active = true
    WHERE pm.metric_type = 'quality_score'
      AND pm.score IS NOT NULL
    """
  end

  # Restore the prior (un-normalized) view body from 20250814105800.
  def down do
    execute "DROP VIEW IF EXISTS metric_values_view"

    execute """
    CREATE VIEW metric_values_view AS
    SELECT
      em.movie_id,
      CONCAT(em.source, '_', em.metric_type) as metric_code,
      em.value as raw_value_numeric,
      NULL as raw_value_text,
      em.source as source_type,
      em.fetched_at as observed_at,
      'external_metrics' as source_table
    FROM external_metrics em
    WHERE em.value IS NOT NULL
    UNION ALL
    SELECT
      fn.movie_id,
      CASE
        WHEN fo.abbreviation = 'AMPAS' AND fn.won = true THEN 'oscar_wins'
        WHEN fo.abbreviation = 'AMPAS' AND fn.won = false THEN 'oscar_nominations'
        WHEN fo.abbreviation = 'CANNES' AND fn.won = true THEN 'cannes_palme_dor'
        WHEN fo.abbreviation = 'VIFF' AND fn.won = true THEN 'venice_golden_lion'
        WHEN fo.abbreviation = 'BERLINALE' AND fn.won = true THEN 'berlin_golden_bear'
        ELSE CONCAT(LOWER(fo.abbreviation), '_', CASE WHEN fn.won THEN 'win' ELSE 'nom' END)
      END as metric_code,
      1 as raw_value_numeric,
      CASE WHEN fn.won THEN 'true' ELSE 'false' END as raw_value_text,
      fo.abbreviation as source_type,
      fc.date as observed_at,
      'festival_nominations' as source_table
    FROM festival_nominations fn
    JOIN festival_ceremonies fc ON fn.ceremony_id = fc.id
    JOIN festival_organizations fo ON fc.organization_id = fo.id
    WHERE fn.movie_id IS NOT NULL
    UNION ALL
    SELECT
      m.id as movie_id,
      key as metric_code,
      CASE
        WHEN value::text = 'true' THEN 1
        WHEN value::text ~ '^[0-9]+$' THEN value::text::integer
        ELSE NULL
      END as raw_value_numeric,
      value::text as raw_value_text,
      key as source_type,
      m.updated_at as observed_at,
      'canonical_sources' as source_table
    FROM movies m,
    LATERAL jsonb_each(m.canonical_sources) as sources(key, value)
    WHERE m.canonical_sources IS NOT NULL
    UNION ALL
    SELECT
      movie_credits.movie_id,
      'person_quality_score' as metric_code,
      pm.score as raw_value_numeric,
      pm.metric_type as raw_value_text,
      'person_metrics' as source_type,
      pm.calculated_at as observed_at,
      'person_metrics' as source_table
    FROM person_metrics pm
    JOIN movie_credits ON pm.person_id = movie_credits.person_id
    WHERE pm.metric_type = 'quality_score'
      AND pm.score IS NOT NULL
      AND movie_credits.movie_id IS NOT NULL
    """
  end
end
