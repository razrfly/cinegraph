defmodule Cinegraph.Repo.Migrations.DedupMetricValuesView do
  use Ecto.Migration

  # #1082 / #1084 P1 prerequisite: make metric_values_view emit EXACTLY ONE row per
  # (movie_id, metric_code). Measured on dev (2026-06-07): the prior body emitted one
  # person_quality_score row PER CREDITED PERSON (172 rows / 71 distinct values on one
  # movie) and DataPointFeatures.load's map-fold took an arbitrary plan-dependent
  # last-row-wins value — live nondeterminism in a feature all 6 served models weight.
  # Festival codes duplicated too (one 1.0 row per nomination), value-identically.
  #
  # Deliberate aggregation (decision recorded on #1082):
  #   * person_quality_score → AVG of the credited people's raw scores, normalized on
  #     the aggregate (normalization is linear 0–100, so aggregate-then-normalize is
  #     exact). SCORE-AFFECTING: was an arbitrary person's score, now deterministic AVG
  #     → calc_version bump + served-model retrain doctrine (follow-up session).
  #   * festival codes → GROUP BY per (movie, code); values provably identical (1.0
  #     presence), so this is pure de-bloat with byte-identical output.
  #   * outer GROUP BY (movie_id, metric_code) with MAX() representatives wraps the
  #     whole union as a uniqueness GUARD, so the matview's unique index
  #     (20260607200100) stays provably safe against any future branch regression.
  def up do
    execute "DROP VIEW IF EXISTS metric_values_view"

    execute """
    CREATE VIEW metric_values_view AS
    SELECT
      movie_id,
      metric_code,
      MAX(raw_value_numeric) AS raw_value_numeric,
      MAX(raw_value_text) AS raw_value_text,
      MAX(normalized_value) AS normalized_value,
      MAX(source_type) AS source_type,
      MAX(source_key) AS source_key,
      MAX(observed_at) AS observed_at,
      MAX(source_table) AS source_table
    FROM (

    -- External metrics (IMDb, TMDb, Metacritic, RT, OMDb) — joined on (source_type, source_field).
    -- Emits numeric rows, plus CATALOGUED text rows (e.g. content_rating) whose value is NULL.
    -- Unique per (movie, code) by the external_metrics (movie_id, source, metric_type) key.
    SELECT
      em.movie_id,
      COALESCE(md.code, CONCAT(em.source, '_', em.metric_type)) AS metric_code,
      em.value::float AS raw_value_numeric,
      em.text_value AS raw_value_text,
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
       OR (em.text_value IS NOT NULL AND md.id IS NOT NULL)

    UNION ALL

    -- Festival nominations (Oscars, Cannes, etc.) — grouped per (movie, code): a movie
    -- with N same-code nominations previously emitted N identical 1.0 rows.
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
      MAX(fc.date) AS observed_at,
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
    GROUP BY fn.movie_id, fcode.metric_code, fn.won, fo.abbreviation,
             md.id, md.normalization_type, md.normalization_params,
             md.raw_scale_min, md.raw_scale_max

    UNION ALL

    -- Canonical sources (1001 Movies, AFI 100, etc.) from movies.canonical_sources JSONB
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

    -- Person quality scores — AVG of the credited people's scores, ONE row per movie.
    -- (Was one row per credited person; the served value was last-row-wins roulette.)
    SELECT
      movie_credits.movie_id,
      'person_quality_score' AS metric_code,
      AVG(pm.score::float) AS raw_value_numeric,
      'quality_score' AS raw_value_text,
      CASE
        WHEN md.id IS NOT NULL
        THEN normalize_metric_value(AVG(pm.score::float), md.normalization_type,
               md.normalization_params, md.raw_scale_min, md.raw_scale_max)
      END AS normalized_value,
      'person_metrics' AS source_type,
      'quality_score' AS source_key,
      MAX(pm.calculated_at) AS observed_at,
      'person_metrics' AS source_table
    FROM person_metrics pm
    -- dedup: a person with several credits on one movie must count once, not N times
    JOIN (
      SELECT DISTINCT movie_id, person_id
      FROM movie_credits
      WHERE movie_id IS NOT NULL
    ) movie_credits ON pm.person_id = movie_credits.person_id
    LEFT JOIN metric_definitions md ON md.code = 'person_quality_score' AND md.active = true
    WHERE pm.metric_type = 'quality_score'
      AND pm.score IS NOT NULL
    GROUP BY movie_credits.movie_id,
             md.id, md.normalization_type, md.normalization_params,
             md.raw_scale_min, md.raw_scale_max

    UNION ALL

    -- Movie attributes (scalar columns on the movies table), unpivoted to one row per metric
    SELECT
      m.id AS movie_id,
      attr.code AS metric_code,
      attr.num AS raw_value_numeric,
      attr.txt AS raw_value_text,
      CASE
        WHEN md.id IS NOT NULL
        THEN normalize_metric_value(attr.num, md.normalization_type,
               md.normalization_params, md.raw_scale_min, md.raw_scale_max)
      END AS normalized_value,
      'movies' AS source_type,
      'movies' AS source_key,
      m.updated_at AS observed_at,
      'movie_attributes' AS source_table
    FROM movies m
    CROSS JOIN LATERAL (
      VALUES
        ('runtime', m.runtime::float, NULL::text),
        ('release_year', EXTRACT(YEAR FROM m.release_date)::float, NULL::text),
        ('original_language', NULL::float, m.original_language),
        ('collection_membership',
          (CASE WHEN m.collection_id IS NOT NULL THEN 1 ELSE 0 END)::float, NULL::text)
    ) AS attr(code, num, txt)
    LEFT JOIN metric_definitions md ON md.code = attr.code AND md.active = true
    WHERE attr.num IS NOT NULL OR attr.txt IS NOT NULL

    UNION ALL

    -- Junction counts (genres, keywords, production countries) — one row per movie
    SELECT
      j.movie_id,
      j.code AS metric_code,
      j.cnt AS raw_value_numeric,
      NULL::text AS raw_value_text,
      CASE
        WHEN md.id IS NOT NULL
        THEN normalize_metric_value(j.cnt, md.normalization_type,
               md.normalization_params, md.raw_scale_min, md.raw_scale_max)
      END AS normalized_value,
      'junction' AS source_type,
      'junction' AS source_key,
      NULL::timestamp AS observed_at,
      'movie_attributes' AS source_table
    FROM (
      SELECT movie_id, 'genre_ids' AS code, COUNT(*)::float AS cnt
        FROM movie_genres GROUP BY movie_id
      UNION ALL
      SELECT movie_id, 'keyword_ids' AS code, COUNT(*)::float AS cnt
        FROM movie_keywords GROUP BY movie_id
      UNION ALL
      SELECT movie_id, 'production_country_count' AS code, COUNT(*)::float AS cnt
        FROM movie_production_countries GROUP BY movie_id
    ) j
    LEFT JOIN metric_definitions md ON md.code = j.code AND md.active = true

    UNION ALL

    -- Official trailer presence (movie_videos.official)
    SELECT
      v.movie_id,
      'has_official_trailer' AS metric_code,
      v.flag AS raw_value_numeric,
      NULL::text AS raw_value_text,
      CASE
        WHEN md.id IS NOT NULL
        THEN normalize_metric_value(v.flag, md.normalization_type,
               md.normalization_params, md.raw_scale_min, md.raw_scale_max)
      END AS normalized_value,
      'movie_videos' AS source_type,
      'movie_videos' AS source_key,
      NULL::timestamp AS observed_at,
      'movie_attributes' AS source_table
    FROM (
      SELECT movie_id,
        (CASE WHEN bool_or(official AND type = 'Trailer') THEN 1 ELSE 0 END)::float AS flag
      FROM movie_videos GROUP BY movie_id
    ) v
    LEFT JOIN metric_definitions md ON md.code = 'has_official_trailer' AND md.active = true

    ) all_rows
    GROUP BY movie_id, metric_code
    """
  end

  # Restore the 20260602120700 (pre-dedup) view body verbatim.
  def down do
    execute "DROP VIEW IF EXISTS metric_values_view"

    execute """
    CREATE VIEW metric_values_view AS

    SELECT
      em.movie_id,
      COALESCE(md.code, CONCAT(em.source, '_', em.metric_type)) AS metric_code,
      em.value::float AS raw_value_numeric,
      em.text_value AS raw_value_text,
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
       OR (em.text_value IS NOT NULL AND md.id IS NOT NULL)

    UNION ALL

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
    JOIN (
      SELECT DISTINCT movie_id, person_id
      FROM movie_credits
      WHERE movie_id IS NOT NULL
    ) movie_credits ON pm.person_id = movie_credits.person_id
    LEFT JOIN metric_definitions md ON md.code = 'person_quality_score' AND md.active = true
    WHERE pm.metric_type = 'quality_score'
      AND pm.score IS NOT NULL

    UNION ALL

    SELECT
      m.id AS movie_id,
      attr.code AS metric_code,
      attr.num AS raw_value_numeric,
      attr.txt AS raw_value_text,
      CASE
        WHEN md.id IS NOT NULL
        THEN normalize_metric_value(attr.num, md.normalization_type,
               md.normalization_params, md.raw_scale_min, md.raw_scale_max)
      END AS normalized_value,
      'movies' AS source_type,
      'movies' AS source_key,
      m.updated_at AS observed_at,
      'movie_attributes' AS source_table
    FROM movies m
    CROSS JOIN LATERAL (
      VALUES
        ('runtime', m.runtime::float, NULL::text),
        ('release_year', EXTRACT(YEAR FROM m.release_date)::float, NULL::text),
        ('original_language', NULL::float, m.original_language),
        ('collection_membership',
          (CASE WHEN m.collection_id IS NOT NULL THEN 1 ELSE 0 END)::float, NULL::text)
    ) AS attr(code, num, txt)
    LEFT JOIN metric_definitions md ON md.code = attr.code AND md.active = true
    WHERE attr.num IS NOT NULL OR attr.txt IS NOT NULL

    UNION ALL

    SELECT
      j.movie_id,
      j.code AS metric_code,
      j.cnt AS raw_value_numeric,
      NULL::text AS raw_value_text,
      CASE
        WHEN md.id IS NOT NULL
        THEN normalize_metric_value(j.cnt, md.normalization_type,
               md.normalization_params, md.raw_scale_min, md.raw_scale_max)
      END AS normalized_value,
      'junction' AS source_type,
      'junction' AS source_key,
      NULL::timestamp AS observed_at,
      'movie_attributes' AS source_table
    FROM (
      SELECT movie_id, 'genre_ids' AS code, COUNT(*)::float AS cnt
        FROM movie_genres GROUP BY movie_id
      UNION ALL
      SELECT movie_id, 'keyword_ids' AS code, COUNT(*)::float AS cnt
        FROM movie_keywords GROUP BY movie_id
      UNION ALL
      SELECT movie_id, 'production_country_count' AS code, COUNT(*)::float AS cnt
        FROM movie_production_countries GROUP BY movie_id
    ) j
    LEFT JOIN metric_definitions md ON md.code = j.code AND md.active = true

    UNION ALL

    SELECT
      v.movie_id,
      'has_official_trailer' AS metric_code,
      v.flag AS raw_value_numeric,
      NULL::text AS raw_value_text,
      CASE
        WHEN md.id IS NOT NULL
        THEN normalize_metric_value(v.flag, md.normalization_type,
               md.normalization_params, md.raw_scale_min, md.raw_scale_max)
      END AS normalized_value,
      'movie_videos' AS source_type,
      'movie_videos' AS source_key,
      NULL::timestamp AS observed_at,
      'movie_attributes' AS source_table
    FROM (
      SELECT movie_id,
        (CASE WHEN bool_or(official AND type = 'Trailer') THEN 1 ELSE 0 END)::float AS flag
      FROM movie_videos GROUP BY movie_id
    ) v
    LEFT JOIN metric_definitions md ON md.code = 'has_official_trailer' AND md.active = true
    """
  end
end
