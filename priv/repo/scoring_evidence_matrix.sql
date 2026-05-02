-- Research-only CineGraph scoring evidence matrix.
--
-- This file is intentionally not an Ecto migration. It creates a local
-- materialized view for scoring research/model evaluation against a restored
-- production database.

DROP MATERIALIZED VIEW IF EXISTS scoring_evidence_matrix;

CREATE MATERIALIZED VIEW scoring_evidence_matrix AS
WITH metric_agg AS (
  SELECT
    movie_id,
    MAX(value) FILTER (WHERE source = 'imdb' AND metric_type = 'rating_average') AS imdb_rating,
    MAX(value) FILTER (WHERE source = 'imdb' AND metric_type = 'rating_votes') AS imdb_votes,
    MAX(value) FILTER (WHERE source = 'tmdb' AND metric_type = 'rating_average') AS tmdb_rating,
    MAX(value) FILTER (WHERE source = 'tmdb' AND metric_type = 'rating_votes') AS tmdb_votes,
    MAX(value) FILTER (WHERE source = 'rotten_tomatoes' AND metric_type = 'tomatometer') AS rt_tomatometer,
    MAX(value) FILTER (WHERE source = 'metacritic' AND metric_type = 'metascore') AS metacritic,
    MAX(value) FILTER (WHERE source = 'tmdb' AND metric_type = 'popularity_score') AS tmdb_popularity_metric,
    MAX(value) FILTER (WHERE source = 'tmdb' AND metric_type = 'budget') AS budget_metric,
    MAX(value) FILTER (WHERE source = 'tmdb' AND metric_type = 'revenue_worldwide') AS revenue_worldwide_metric,
    MAX(value) FILTER (WHERE source = 'omdb' AND metric_type = 'revenue_domestic') AS revenue_domestic_metric
  FROM external_metrics
  GROUP BY movie_id
),
festival_agg AS (
  SELECT
    fn.movie_id,
    COUNT(*) AS festival_nomination_count,
    COUNT(*) FILTER (WHERE fn.won = true) AS festival_win_count,
    COUNT(DISTINCT fcer.organization_id) AS festival_org_count,
    COUNT(*) FILTER (WHERE COALESCE(fo.prestige_tier, 99) <= 3) AS festival_major_nomination_count,
    COUNT(*) FILTER (WHERE fn.won = true AND COALESCE(fo.prestige_tier, 99) <= 3) AS festival_major_win_count,
    ARRAY_AGG(DISTINCT fo.abbreviation ORDER BY fo.abbreviation) FILTER (WHERE fo.abbreviation IS NOT NULL) AS festival_org_keys
  FROM festival_nominations fn
  JOIN festival_ceremonies fcer ON fcer.id = fn.ceremony_id
  JOIN festival_organizations fo ON fo.id = fcer.organization_id
  GROUP BY fn.movie_id
),
canonical_agg AS (
  SELECT
    m.id AS movie_id,
    COUNT(*) AS canonical_list_count,
    ARRAY_AGG(src.key ORDER BY src.key) AS canonical_list_keys,
    BOOL_OR(src.key = '1001_movies') AS has_1001_movies,
    BOOL_OR(src.key = 'sight_sound_critics_2022') AS has_sight_and_sound,
    BOOL_OR(src.key = 'criterion') AS has_criterion_or_janus,
    BOOL_OR(src.key = 'national_film_registry') AS has_national_film_registry,
    BOOL_OR(src.key = 'afi') AS has_afi,
    BOOL_OR(src.key NOT IN ('1001_movies', 'sight_sound_critics_2022', 'criterion', 'national_film_registry', 'afi')) AS has_other_canonical_source
  FROM movies m
  CROSS JOIN LATERAL jsonb_object_keys(COALESCE(m.canonical_sources, '{}'::jsonb)) AS src(key)
  WHERE COALESCE(m.canonical_sources, '{}'::jsonb) <> '{}'::jsonb
  GROUP BY m.id
),
credit_agg AS (
  SELECT
    mc.movie_id,
    COUNT(*) AS credited_people_count,
    COUNT(*) FILTER (WHERE pm.person_id IS NOT NULL) AS credited_people_with_pqs_count,
    COUNT(*) FILTER (
      WHERE mc.department IN ('Directing', 'Writing')
         OR mc.job IN ('Director', 'Writer', 'Screenplay', 'Original Music Composer', 'Director of Photography')
         OR COALESCE(mc.cast_order, 999999) <= 10
    ) AS important_credited_people_count,
    COUNT(*) FILTER (
      WHERE pm.person_id IS NOT NULL
        AND (
          mc.department IN ('Directing', 'Writing')
          OR mc.job IN ('Director', 'Writer', 'Screenplay', 'Original Music Composer', 'Director of Photography')
          OR COALESCE(mc.cast_order, 999999) <= 10
        )
    ) AS important_credited_people_with_pqs_count,
    ROUND(AVG(pm.score)::numeric, 3) AS avg_person_quality_score,
    ROUND(MAX(pm.score)::numeric, 3) AS max_person_quality_score
  FROM movie_credits mc
  LEFT JOIN person_metrics pm
    ON pm.person_id = mc.person_id
   AND pm.metric_type = 'quality_score'
  GROUP BY mc.movie_id
),
country_agg AS (
  SELECT
    mpc.movie_id,
    ARRAY_AGG(DISTINCT pc.iso_3166_1 ORDER BY pc.iso_3166_1) AS production_country_codes,
    ARRAY_AGG(DISTINCT pc.name ORDER BY pc.name) AS production_country_names
  FROM movie_production_countries mpc
  JOIN production_countries pc ON pc.id = mpc.production_country_id
  GROUP BY mpc.movie_id
),
base AS (
  SELECT
    m.id AS movie_id,
    m.title,
    m.slug,
    m.tmdb_id,
    m.imdb_id,
    m.release_date,
    EXTRACT(YEAR FROM m.release_date)::int AS release_year,
    (FLOOR(EXTRACT(YEAR FROM m.release_date) / 10) * 10)::int AS release_decade,
    m.runtime,
    m.status,
    m.import_status,
    m.original_language,
    m.origin_country,
    COALESCE(countries.production_country_codes, m.origin_country, ARRAY[]::varchar[]) AS production_country_codes,
    countries.production_country_names,
    m.canonical_sources AS canonical_sources_json,

    metrics.imdb_rating,
    metrics.imdb_votes,
    metrics.tmdb_rating,
    metrics.tmdb_votes,
    metrics.rt_tomatometer,
    metrics.metacritic,
    COALESCE(NULLIF(m.tmdb_data ->> 'popularity', '')::double precision, metrics.tmdb_popularity_metric) AS tmdb_popularity,
    COALESCE(metrics.budget_metric, NULLIF(m.tmdb_data ->> 'budget', '')::double precision) AS budget,
    COALESCE(metrics.revenue_worldwide_metric, NULLIF(m.tmdb_data ->> 'revenue', '')::double precision) AS revenue_worldwide,
    metrics.revenue_domestic_metric,

    scores.mob_score,
    scores.critics_score,
    scores.festival_recognition_score,
    scores.time_machine_score,
    scores.auteurs_score,
    scores.box_office_score,
    scores.overall_score AS legacy_overall_score,
    scores.score_confidence AS legacy_score_confidence,
    scores.calculated_at AS score_calculated_at,
    scores.calculation_version AS score_calculation_version,

    COALESCE(festivals.festival_nomination_count, 0) AS festival_nomination_count,
    COALESCE(festivals.festival_win_count, 0) AS festival_win_count,
    COALESCE(festivals.festival_org_count, 0) AS festival_org_count,
    COALESCE(festivals.festival_major_nomination_count, 0) AS festival_major_nomination_count,
    COALESCE(festivals.festival_major_win_count, 0) AS festival_major_win_count,
    COALESCE(festivals.festival_org_keys, ARRAY[]::varchar[]) AS festival_org_keys,

    COALESCE(canonical.canonical_list_count, 0) AS canonical_list_count,
    COALESCE(canonical.canonical_list_keys, ARRAY[]::text[]) AS canonical_list_keys,
    COALESCE(canonical.has_1001_movies, false) AS has_1001_movies,
    COALESCE(canonical.has_sight_and_sound, false) AS has_sight_and_sound,
    COALESCE(canonical.has_criterion_or_janus, false) AS has_criterion_or_janus,
    COALESCE(canonical.has_national_film_registry, false) AS has_national_film_registry,
    COALESCE(canonical.has_afi, false) AS has_afi,
    COALESCE(canonical.has_other_canonical_source, false) AS has_other_canonical_source,

    COALESCE(credits.credited_people_count, 0) AS credited_people_count,
    COALESCE(credits.credited_people_with_pqs_count, 0) AS credited_people_with_pqs_count,
    COALESCE(credits.important_credited_people_count, 0) AS important_credited_people_count,
    COALESCE(credits.important_credited_people_with_pqs_count, 0) AS important_credited_people_with_pqs_count,
    credits.avg_person_quality_score,
    credits.max_person_quality_score
  FROM movies m
  LEFT JOIN metric_agg metrics ON metrics.movie_id = m.id
  LEFT JOIN movie_score_caches scores ON scores.movie_id = m.id
  LEFT JOIN festival_agg festivals ON festivals.movie_id = m.id
  LEFT JOIN canonical_agg canonical ON canonical.movie_id = m.id
  LEFT JOIN credit_agg credits ON credits.movie_id = m.id
  LEFT JOIN country_agg countries ON countries.movie_id = m.id
)
SELECT
  base.*,

  CASE
    WHEN release_year IS NULL THEN 'unknown'
    WHEN release_year < 1950 THEN 'pre-1950'
    WHEN release_year >= 2020 THEN '2020s'
    ELSE (release_decade::text || 's')
  END AS release_era_bucket,

  CASE
    WHEN release_year IS NULL THEN 'unknown'
    WHEN release_year >= EXTRACT(YEAR FROM CURRENT_DATE)::int THEN 'new_or_unreleased'
    WHEN release_year >= EXTRACT(YEAR FROM CURRENT_DATE)::int - 5 THEN 'recent'
    WHEN release_year >= 1980 THEN 'mature'
    ELSE 'classic'
  END AS release_age_bucket,

  CASE
    WHEN runtime IS NULL OR runtime <= 0 THEN 'unknown'
    WHEN runtime < 40 THEN 'short'
    WHEN runtime <= 180 THEN 'feature'
    ELSE 'long_feature'
  END AS runtime_bucket,

  CASE
    WHEN original_language IS NULL OR original_language = '' THEN 'unknown'
    WHEN original_language = 'en' THEN 'english'
    ELSE 'non_english'
  END AS language_bucket,

  CASE
    WHEN COALESCE(array_length(production_country_codes, 1), 0) = 0 THEN 'unknown'
    WHEN production_country_codes && ARRAY['US']::varchar[] THEN 'us'
    WHEN COALESCE(array_length(production_country_codes, 1), 0) > 1 THEN 'multi_country_non_us'
    ELSE 'single_country_non_us'
  END AS country_bucket,

  CASE
    WHEN tmdb_popularity >= 100 THEN '100+'
    WHEN tmdb_popularity >= 50 THEN '50-100'
    WHEN tmdb_popularity >= 10 THEN '10-50'
    WHEN tmdb_popularity >= 1 THEN '1-10'
    ELSE '<1_or_unknown'
  END AS tmdb_popularity_bucket,

  CASE
    WHEN budget IS NULL OR budget <= 0 THEN 'unknown'
    WHEN budget < 1000000 THEN '<1m'
    WHEN budget < 10000000 THEN '1m-10m'
    WHEN budget < 50000000 THEN '10m-50m'
    WHEN budget < 100000000 THEN '50m-100m'
    ELSE '100m+'
  END AS budget_bucket,

  CASE
    WHEN revenue_worldwide IS NULL OR revenue_worldwide <= 0 THEN 'unknown'
    WHEN revenue_worldwide < 1000000 THEN '<1m'
    WHEN revenue_worldwide < 10000000 THEN '1m-10m'
    WHEN revenue_worldwide < 50000000 THEN '10m-50m'
    WHEN revenue_worldwide < 100000000 THEN '50m-100m'
    ELSE '100m+'
  END AS revenue_bucket,

  (imdb_rating IS NOT NULL AND imdb_rating > 0) AS has_imdb_rating,
  (imdb_votes IS NOT NULL AND imdb_votes > 0) AS has_imdb_votes,
  (tmdb_rating IS NOT NULL AND tmdb_rating > 0) AS has_tmdb_rating,
  (tmdb_votes IS NOT NULL AND tmdb_votes > 0) AS has_tmdb_votes,
  (rt_tomatometer IS NOT NULL AND rt_tomatometer > 0) AS has_rt_tomatometer,
  (metacritic IS NOT NULL AND metacritic > 0) AS has_metacritic,
  (festival_nomination_count > 0) AS has_festival_data,
  (canonical_list_count > 0) AS has_canonical_list_data,
  (credited_people_with_pqs_count > 0) AS has_people_quality_data,
  (budget IS NOT NULL AND budget > 0) AS has_budget,
  (revenue_worldwide IS NOT NULL AND revenue_worldwide > 0) AS has_revenue,
  ((budget IS NOT NULL AND budget > 0) OR (revenue_worldwide IS NOT NULL AND revenue_worldwide > 0)) AS has_box_office_data,

  CASE
    WHEN festival_major_nomination_count > 0 THEN 'major_festival_data'
    WHEN festival_nomination_count > 0 THEN 'festival_data'
    ELSE 'none'
  END AS festival_coverage_bucket,

  CASE
    WHEN important_credited_people_count = 0 THEN NULL
    ELSE ROUND((important_credited_people_with_pqs_count::numeric / important_credited_people_count), 3)
  END AS people_quality_coverage,

  (
    (COALESCE(mob_score, 0) > 0)::int +
    (COALESCE(critics_score, 0) > 0)::int +
    (COALESCE(festival_recognition_score, 0) > 0)::int +
    (COALESCE(time_machine_score, 0) > 0)::int +
    (COALESCE(auteurs_score, 0) > 0)::int +
    (COALESCE(box_office_score, 0) > 0)::int
  ) AS present_lens_count,

  6 - (
    (COALESCE(mob_score, 0) > 0)::int +
    (COALESCE(critics_score, 0) > 0)::int +
    (COALESCE(festival_recognition_score, 0) > 0)::int +
    (COALESCE(time_machine_score, 0) > 0)::int +
    (COALESCE(auteurs_score, 0) > 0)::int +
    (COALESCE(box_office_score, 0) > 0)::int
  ) AS missing_lens_count,

  ARRAY_REMOVE(ARRAY[
    CASE WHEN COALESCE(mob_score, 0) > 0 THEN 'mob' END,
    CASE WHEN COALESCE(critics_score, 0) > 0 THEN 'critics' END,
    CASE WHEN COALESCE(festival_recognition_score, 0) > 0 THEN 'festival_recognition' END,
    CASE WHEN COALESCE(time_machine_score, 0) > 0 THEN 'time_machine' END,
    CASE WHEN COALESCE(auteurs_score, 0) > 0 THEN 'auteurs' END,
    CASE WHEN COALESCE(box_office_score, 0) > 0 THEN 'box_office' END
  ], NULL) AS present_lenses,

  ARRAY_REMOVE(ARRAY[
    CASE WHEN COALESCE(mob_score, 0) <= 0 THEN 'mob' END,
    CASE WHEN COALESCE(critics_score, 0) <= 0 THEN 'critics' END,
    CASE WHEN COALESCE(festival_recognition_score, 0) <= 0 THEN 'festival_recognition' END,
    CASE WHEN COALESCE(time_machine_score, 0) <= 0 THEN 'time_machine' END,
    CASE WHEN COALESCE(auteurs_score, 0) <= 0 THEN 'auteurs' END,
    CASE WHEN COALESCE(box_office_score, 0) <= 0 THEN 'box_office' END
  ], NULL) AS missing_lenses,

  COALESCE(legacy_score_confidence, 0.0) AS rating_confidence,

  -- evidence_confidence_baseline intentionally keeps rt_tomatometer only in the
  -- critics LEAST(...) component; the audience/rating component is limited to
  -- IMDb and TMDb so critic evidence is not counted twice.
  ROUND((
    0.20 * LEAST(1.0, (
      (
        (imdb_rating IS NOT NULL AND imdb_rating > 0)::int +
        (tmdb_rating IS NOT NULL AND tmdb_rating > 0)::int
      )::numeric / 2.0
    )) +
    0.15 * LEAST(1.0, (
      (
        (metacritic IS NOT NULL AND metacritic > 0)::int +
        (rt_tomatometer IS NOT NULL AND rt_tomatometer > 0)::int
      )::numeric / 2.0
    )) +
    0.15 * CASE WHEN festival_nomination_count > 0 THEN 1.0 ELSE 0.0 END +
    0.15 * CASE WHEN canonical_list_count > 0 THEN 1.0 ELSE 0.0 END +
    0.20 * COALESCE(
      CASE
        WHEN important_credited_people_count = 0 THEN NULL
        ELSE important_credited_people_with_pqs_count::numeric / important_credited_people_count
      END,
      0.0
    ) +
    0.15 * CASE WHEN (budget IS NOT NULL AND budget > 0) OR (revenue_worldwide IS NOT NULL AND revenue_worldwide > 0) THEN 1.0 ELSE 0.0 END
  )::numeric, 3) AS evidence_confidence_baseline,

  CASE
    WHEN (
      (COALESCE(mob_score, 0) > 0)::int +
      (COALESCE(critics_score, 0) > 0)::int +
      (COALESCE(festival_recognition_score, 0) > 0)::int +
      (COALESCE(time_machine_score, 0) > 0)::int +
      (COALESCE(auteurs_score, 0) > 0)::int +
      (COALESCE(box_office_score, 0) > 0)::int
    ) >= 4 THEN 'high_evidence'
    WHEN (
      (COALESCE(mob_score, 0) > 0)::int +
      (COALESCE(critics_score, 0) > 0)::int +
      (COALESCE(festival_recognition_score, 0) > 0)::int +
      (COALESCE(time_machine_score, 0) > 0)::int +
      (COALESCE(auteurs_score, 0) > 0)::int +
      (COALESCE(box_office_score, 0) > 0)::int
    ) >= 2 THEN 'medium_evidence'
    WHEN (
      (COALESCE(mob_score, 0) > 0)::int +
      (COALESCE(critics_score, 0) > 0)::int +
      (COALESCE(festival_recognition_score, 0) > 0)::int +
      (COALESCE(time_machine_score, 0) > 0)::int +
      (COALESCE(auteurs_score, 0) > 0)::int +
      (COALESCE(box_office_score, 0) > 0)::int
    ) = 1 THEN 'low_evidence'
    ELSE 'no_evidence'
  END AS evidence_regime,

  (canonical_list_count > 0) AS validation_target_canonical_any,
  (canonical_list_count > 0 AND COALESCE(time_machine_score, 0) <= 0) AS validation_target_canonical_without_time_machine,
  (festival_nomination_count > 0 OR festival_win_count > 0) AS validation_target_award_any,
  (
    (festival_nomination_count > 0 OR festival_win_count > 0) AND
    COALESCE(festival_recognition_score, 0) <= 0
  ) AS validation_target_award_without_festival,

  true AS feature_mask_full,
  true AS feature_mask_without_canonical,
  true AS feature_mask_without_festival,
  true AS feature_mask_without_critics,
  true AS feature_mask_without_audience
FROM base
WITH DATA;

CREATE UNIQUE INDEX scoring_evidence_matrix_movie_id_idx
  ON scoring_evidence_matrix (movie_id);

CREATE INDEX scoring_evidence_matrix_release_decade_idx
  ON scoring_evidence_matrix (release_decade);

CREATE INDEX scoring_evidence_matrix_popularity_bucket_idx
  ON scoring_evidence_matrix (tmdb_popularity_bucket);

CREATE INDEX scoring_evidence_matrix_evidence_regime_idx
  ON scoring_evidence_matrix (evidence_regime);
