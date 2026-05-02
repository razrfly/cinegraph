defmodule Cinegraph.Repo.Migrations.CreateMovieScoreabilityView do
  use Ecto.Migration

  def up do
    execute """
    CREATE OR REPLACE VIEW movie_scoreability_view AS
    WITH score_base AS (
      SELECT
        m.id AS movie_id,
        m.title,
        m.slug,
        m.release_date,
        msc.overall_score AS raw_cinegraph_score,
        msc.score_confidence AS legacy_score_confidence,
        msc.mob_score,
        msc.critics_score,
        msc.festival_recognition_score,
        msc.time_machine_score,
        msc.auteurs_score,
        msc.box_office_score,
        msc.calculated_at,
        msc.updated_at,
        ARRAY_REMOVE(ARRAY[
          CASE WHEN COALESCE(msc.mob_score, 0) > 0 THEN 'mob' END,
          CASE WHEN COALESCE(msc.critics_score, 0) > 0 THEN 'critics' END,
          CASE WHEN COALESCE(msc.festival_recognition_score, 0) > 0 THEN 'festival_recognition' END,
          CASE WHEN COALESCE(msc.time_machine_score, 0) > 0 THEN 'time_machine' END,
          CASE WHEN COALESCE(msc.auteurs_score, 0) > 0 THEN 'auteurs' END,
          CASE WHEN COALESCE(msc.box_office_score, 0) > 0 THEN 'box_office' END
        ], NULL) AS present_lens_labels,
        ARRAY_REMOVE(ARRAY[
          CASE WHEN COALESCE(msc.mob_score, 0) <= 0 THEN 'mob' END,
          CASE WHEN COALESCE(msc.critics_score, 0) <= 0 THEN 'critics' END,
          CASE WHEN COALESCE(msc.festival_recognition_score, 0) <= 0 THEN 'festival_recognition' END,
          CASE WHEN COALESCE(msc.time_machine_score, 0) <= 0 THEN 'time_machine' END,
          CASE WHEN COALESCE(msc.auteurs_score, 0) <= 0 THEN 'auteurs' END,
          CASE WHEN COALESCE(msc.box_office_score, 0) <= 0 THEN 'box_office' END
        ], NULL) AS missing_lens_labels
      FROM movies m
      LEFT JOIN movie_score_caches msc ON msc.movie_id = m.id
    ),
    scored AS (
      SELECT
        *,
        CARDINALITY(present_lens_labels) AS present_lens_count,
        CARDINALITY(missing_lens_labels) AS missing_lens_count,
        ROUND((CARDINALITY(present_lens_labels)::numeric / 6.0), 3)::double precision AS evidence_confidence,
        NULL::double precision AS cohort_percentile
      FROM score_base
    )
    SELECT
      *,
      CASE
        WHEN raw_cinegraph_score IS NULL THEN 'insufficient_evidence'
        WHEN present_lens_count >= 4 THEN 'scoreable'
        WHEN present_lens_count >= 2 THEN 'limited'
        ELSE 'insufficient_evidence'
      END AS scoreability_state,
      CASE
        WHEN raw_cinegraph_score IS NULL OR present_lens_count <= 1 THEN 'insufficient'
        WHEN evidence_confidence >= 0.70 OR present_lens_count >= 5 THEN 'high'
        WHEN evidence_confidence >= 0.35 OR present_lens_count >= 3 THEN 'medium'
        ELSE 'low'
      END AS score_confidence_label,
      CASE
        WHEN raw_cinegraph_score IS NOT NULL AND present_lens_count >= 2 THEN raw_cinegraph_score
        ELSE NULL
      END AS cinegraph_display_score,
      CASE
        WHEN raw_cinegraph_score IS NOT NULL AND present_lens_count >= 2 THEN raw_cinegraph_score * evidence_confidence
        ELSE NULL
      END AS cinegraph_sort_score,
      CASE
        WHEN raw_cinegraph_score IS NULL THEN 'no_score_cache'
        WHEN present_lens_count <= 1 THEN 'not_enough_evidence'
        ELSE 'none'
      END AS score_hidden_reason,
      CASE
        WHEN raw_cinegraph_score IS NULL OR present_lens_count <= 1 THEN 'Not enough evidence yet'
        WHEN present_lens_count BETWEEN 2 AND 3 THEN 'Limited confidence'
        WHEN evidence_confidence >= 0.70 OR present_lens_count >= 5 THEN 'High confidence'
        ELSE 'Medium confidence'
      END AS score_explanation_short,
      CASE
        WHEN raw_cinegraph_score IS NULL THEN 'No CineGraph score cache is available for this movie yet.'
        WHEN present_lens_count <= 1 THEN 'CineGraph needs at least 2 independent evidence lenses before showing a fair numeric score.'
        WHEN present_lens_count BETWEEN 2 AND 3 THEN 'This score is based on limited evidence and may move as more lenses become available.'
        ELSE 'This movie has enough independent evidence for a CineGraph score.'
      END AS score_explanation_detail
    FROM scored
    """
  end

  def down do
    execute "DROP VIEW IF EXISTS movie_scoreability_view"
  end
end
