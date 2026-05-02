# Phase 3 CineGraph candidate score bake-off.
#
# Run with:
#   mix run priv/scripts/scoring_phase3_bakeoff.exs
#
# This is a research-only script. It reads from the Phase 1
# scoring_evidence_matrix materialized view and writes a markdown report.

alias Cinegraph.Repo
require Logger

Logger.configure(level: :warning)

report_path = "docs/scoring/reports/scoring_phase3_bakeoff_2026_05_02.md"
matrix = "scoring_evidence_matrix"

required_columns = ~w[
  movie_id title release_year release_era_bucket runtime_bucket language_bucket
  country_bucket tmdb_popularity_bucket legacy_overall_score mob_score
  critics_score festival_recognition_score time_machine_score auteurs_score
  box_office_score evidence_confidence_baseline evidence_regime present_lens_count
  validation_target_canonical_without_time_machine validation_target_award_without_festival canonical_list_count
  festival_nomination_count festival_win_count canonical_list_keys
  has_canonical_list_data has_festival_data
]

target_sets = [
  %{
    key: "canonical_any",
    label: "Canonical target",
    condition: "validation_target_canonical_without_time_machine"
  },
  %{
    key: "award_any",
    label: "Award/festival target",
    condition: "validation_target_award_without_festival"
  },
  %{
    key: "canonical_and_festival",
    label: "Canonical + festival intersection",
    condition: "validation_target_canonical_without_time_machine AND validation_target_award_without_festival"
  },
  %{
    key: "sparse_positive",
    label: "Sparse-evidence known positives",
    condition:
      "(validation_target_canonical_without_time_machine OR validation_target_award_without_festival) AND present_lens_count BETWEEN 1 AND 3"
  }
]

cohort_fields = [
  {"evidence_regime", "Evidence regime"},
  {"tmdb_popularity_bucket", "TMDb popularity"},
  {"release_era_bucket", "Release era"},
  {"language_bucket", "Language"},
  {"country_bucket", "Country"},
  {"runtime_bucket", "Runtime"},
  {"has_canonical_list_data::text", "Canonical status"},
  {"has_festival_data::text", "Festival status"}
]

high_risk_filters = [
  {"Evidence: no evidence", "evidence_regime = 'no_evidence'"},
  {"Evidence: low evidence", "evidence_regime = 'low_evidence'"},
  {"Popularity: <1 or unknown", "tmdb_popularity_bucket = '<1_or_unknown'"},
  {"Runtime: short", "runtime_bucket = 'short'"},
  {"Runtime: unknown", "runtime_bucket = 'unknown'"},
  {"Language: non-English", "language_bucket = 'non_english'"},
  {"Country: single-country non-US", "country_bucket = 'single_country_non_us'"},
  {"Release era: 2020s", "release_era_bucket = '2020s'"},
  {"Release era: unknown", "release_era_bucket = 'unknown'"}
]

candidate_select_sql = """
WITH base AS (
  SELECT
    *,
    CASE
      WHEN present_lens_count > 0 THEN (
        COALESCE(mob_score, 0) +
        COALESCE(critics_score, 0) +
        COALESCE(festival_recognition_score, 0) +
        COALESCE(time_machine_score, 0) +
        COALESCE(auteurs_score, 0) +
        COALESCE(box_office_score, 0)
      ) / present_lens_count
    END AS present_lens_average_score,
    CASE
      WHEN (
        (COALESCE(mob_score, 0) > 0)::int +
        (COALESCE(critics_score, 0) > 0)::int +
        (COALESCE(auteurs_score, 0) > 0)::int +
        (COALESCE(box_office_score, 0) > 0)::int
      ) > 0 THEN (
        COALESCE(mob_score, 0) +
        COALESCE(critics_score, 0) +
        COALESCE(auteurs_score, 0) +
        COALESCE(box_office_score, 0)
      ) / (
        (COALESCE(mob_score, 0) > 0)::int +
        (COALESCE(critics_score, 0) > 0)::int +
        (COALESCE(auteurs_score, 0) > 0)::int +
        (COALESCE(box_office_score, 0) > 0)::int
      )
    END AS leakage_safe_average_score,
    AVG(legacy_overall_score) OVER (
      PARTITION BY release_era_bucket, tmdb_popularity_bucket, language_bucket, evidence_regime
    ) AS cohort_mean_score,
    PERCENT_RANK() OVER (
      PARTITION BY release_era_bucket, tmdb_popularity_bucket, language_bucket, evidence_regime
      ORDER BY COALESCE(legacy_overall_score, 0)
    ) AS cohort_percentile_raw
  FROM scoring_evidence_matrix
),
candidates AS (
  SELECT
    base.*,
    'current_score' AS candidate_key,
    'Current score' AS candidate_label,
    legacy_overall_score::double precision AS candidate_score,
    legacy_overall_score::double precision AS sort_score,
    CASE
      WHEN legacy_overall_score IS NULL THEN 'insufficient_evidence'
      WHEN present_lens_count >= 4 THEN 'scoreable'
      WHEN present_lens_count >= 2 THEN 'limited'
      ELSE 'insufficient_evidence'
    END AS scoreability_state,
    CASE
      WHEN legacy_overall_score IS NULL OR present_lens_count <= 1 THEN 'insufficient'
      WHEN evidence_confidence_baseline >= 0.70 OR present_lens_count >= 5 THEN 'high'
      WHEN evidence_confidence_baseline >= 0.35 OR present_lens_count >= 3 THEN 'medium'
      ELSE 'low'
    END AS confidence_label
  FROM base

  UNION ALL
  SELECT
    base.*,
    'current_gated_2',
    'Current score, 2+ lenses',
    CASE WHEN present_lens_count >= 2 THEN legacy_overall_score END::double precision,
    CASE WHEN present_lens_count >= 2 THEN legacy_overall_score END::double precision,
    CASE
      WHEN present_lens_count >= 4 THEN 'scoreable'
      WHEN present_lens_count >= 2 THEN 'limited'
      ELSE 'insufficient_evidence'
    END,
    CASE
      WHEN present_lens_count < 2 THEN 'insufficient'
      WHEN evidence_confidence_baseline >= 0.70 OR present_lens_count >= 5 THEN 'high'
      WHEN evidence_confidence_baseline >= 0.35 OR present_lens_count >= 3 THEN 'medium'
      ELSE 'low'
    END
  FROM base

  UNION ALL
  SELECT
    base.*,
    'current_gated_3',
    'Current score, 3+ lenses',
    CASE WHEN present_lens_count >= 3 THEN legacy_overall_score END::double precision,
    CASE WHEN present_lens_count >= 3 THEN legacy_overall_score END::double precision,
    CASE
      WHEN present_lens_count >= 4 THEN 'scoreable'
      WHEN present_lens_count >= 3 THEN 'limited'
      ELSE 'insufficient_evidence'
    END,
    CASE
      WHEN present_lens_count < 3 THEN 'insufficient'
      WHEN evidence_confidence_baseline >= 0.70 OR present_lens_count >= 5 THEN 'high'
      WHEN evidence_confidence_baseline >= 0.35 OR present_lens_count >= 3 THEN 'medium'
      ELSE 'low'
    END
  FROM base

  UNION ALL
  SELECT
    base.*,
    'confidence_adjusted',
    'Confidence-adjusted current score',
    CASE
      WHEN legacy_overall_score IS NOT NULL THEN legacy_overall_score * evidence_confidence_baseline
    END::double precision,
    CASE
      WHEN legacy_overall_score IS NOT NULL THEN legacy_overall_score * evidence_confidence_baseline
    END::double precision,
    CASE
      WHEN legacy_overall_score IS NULL OR present_lens_count <= 1 THEN 'insufficient_evidence'
      WHEN present_lens_count >= 4 THEN 'scoreable'
      ELSE 'limited'
    END,
    CASE
      WHEN legacy_overall_score IS NULL OR present_lens_count <= 1 THEN 'insufficient'
      WHEN evidence_confidence_baseline >= 0.70 OR present_lens_count >= 5 THEN 'high'
      WHEN evidence_confidence_baseline >= 0.35 OR present_lens_count >= 3 THEN 'medium'
      ELSE 'low'
    END
  FROM base

  UNION ALL
  SELECT
    base.*,
    'bayesian_shrinkage',
    'Bayesian cohort shrinkage',
    CASE
      WHEN legacy_overall_score IS NOT NULL THEN
        COALESCE(cohort_mean_score, legacy_overall_score) +
        LEAST(1.0, GREATEST(0.0, evidence_confidence_baseline::double precision)) *
        (legacy_overall_score - COALESCE(cohort_mean_score, legacy_overall_score))
    END::double precision,
    CASE
      WHEN legacy_overall_score IS NOT NULL THEN
        COALESCE(cohort_mean_score, legacy_overall_score) +
        LEAST(1.0, GREATEST(0.0, evidence_confidence_baseline::double precision)) *
        (legacy_overall_score - COALESCE(cohort_mean_score, legacy_overall_score))
    END::double precision,
    CASE
      WHEN legacy_overall_score IS NULL OR present_lens_count <= 1 THEN 'insufficient_evidence'
      WHEN present_lens_count >= 4 THEN 'scoreable'
      ELSE 'limited'
    END,
    CASE
      WHEN legacy_overall_score IS NULL OR present_lens_count <= 1 THEN 'insufficient'
      WHEN evidence_confidence_baseline >= 0.70 OR present_lens_count >= 5 THEN 'high'
      WHEN evidence_confidence_baseline >= 0.35 OR present_lens_count >= 3 THEN 'medium'
      ELSE 'low'
    END
  FROM base

  UNION ALL
  SELECT
    base.*,
    'present_lens_average',
    'Present-lens average',
    present_lens_average_score::double precision,
    present_lens_average_score::double precision,
    CASE
      WHEN present_lens_count <= 1 THEN 'insufficient_evidence'
      WHEN present_lens_count >= 4 THEN 'scoreable'
      ELSE 'limited'
    END,
    CASE
      WHEN present_lens_count <= 1 THEN 'insufficient'
      WHEN evidence_confidence_baseline >= 0.70 OR present_lens_count >= 5 THEN 'high'
      WHEN evidence_confidence_baseline >= 0.35 OR present_lens_count >= 3 THEN 'medium'
      ELSE 'low'
    END
  FROM base

  UNION ALL
  SELECT
    base.*,
    'leakage_safe_average',
    'Leakage-safe lens average',
    leakage_safe_average_score::double precision,
    leakage_safe_average_score::double precision,
    CASE
      WHEN leakage_safe_average_score IS NULL OR present_lens_count <= 1 THEN 'insufficient_evidence'
      WHEN present_lens_count >= 4 THEN 'scoreable'
      ELSE 'limited'
    END,
    CASE
      WHEN leakage_safe_average_score IS NULL OR present_lens_count <= 1 THEN 'insufficient'
      WHEN evidence_confidence_baseline >= 0.70 OR present_lens_count >= 5 THEN 'high'
      WHEN evidence_confidence_baseline >= 0.35 OR present_lens_count >= 3 THEN 'medium'
      ELSE 'low'
    END
  FROM base

  UNION ALL
  SELECT
    base.*,
    'cohort_percentile',
    'Cohort percentile',
    (cohort_percentile_raw * 10.0)::double precision,
    (cohort_percentile_raw * 10.0)::double precision,
    CASE
      WHEN present_lens_count <= 1 THEN 'insufficient_evidence'
      WHEN present_lens_count >= 4 THEN 'scoreable'
      ELSE 'limited'
    END,
    CASE
      WHEN present_lens_count <= 1 THEN 'insufficient'
      WHEN evidence_confidence_baseline >= 0.70 OR present_lens_count >= 5 THEN 'high'
      WHEN evidence_confidence_baseline >= 0.35 OR present_lens_count >= 3 THEN 'medium'
      ELSE 'low'
    END
  FROM base

  UNION ALL
  SELECT
    base.*,
    'hybrid_recommended',
    'Hybrid: 2+ lens display + confidence sort',
    CASE WHEN present_lens_count >= 2 THEN legacy_overall_score END::double precision,
    CASE
      WHEN present_lens_count >= 2 AND legacy_overall_score IS NOT NULL THEN
        (legacy_overall_score * evidence_confidence_baseline) + (cohort_percentile_raw * 0.01)
    END::double precision,
    CASE
      WHEN present_lens_count >= 4 THEN 'scoreable'
      WHEN present_lens_count >= 2 THEN 'limited'
      ELSE 'insufficient_evidence'
    END,
    CASE
      WHEN present_lens_count < 2 THEN 'insufficient'
      WHEN evidence_confidence_baseline >= 0.70 OR present_lens_count >= 5 THEN 'high'
      WHEN evidence_confidence_baseline >= 0.35 OR present_lens_count >= 3 THEN 'medium'
      ELSE 'low'
    END
  FROM base
)
"""

candidate_definitions = [
  %{
    "candidate" => "current_score",
    "definition" => "Existing `legacy_overall_score`.",
    "product_read" => "Baseline only."
  },
  %{
    "candidate" => "current_gated_2",
    "definition" => "Existing score shown only for 2+ present lenses.",
    "product_read" => "Minimum viable score-hiding threshold."
  },
  %{
    "candidate" => "current_gated_3",
    "definition" => "Existing score shown only for 3+ present lenses.",
    "product_read" => "Safer but hides too much long-tail catalog."
  },
  %{
    "candidate" => "confidence_adjusted",
    "definition" => "`legacy_overall_score * evidence_confidence_baseline`.",
    "product_read" => "Sorting candidate, not display score."
  },
  %{
    "candidate" => "bayesian_shrinkage",
    "definition" =>
      "Shrinks current score toward release/popularity/language/evidence cohort mean.",
    "product_read" => "Conservative score candidate."
  },
  %{
    "candidate" => "present_lens_average",
    "definition" => "Average of non-zero lens scores.",
    "product_read" => "Useful diagnostic, too coverage-sensitive alone."
  },
  %{
    "candidate" => "leakage_safe_average",
    "definition" => "Average of mob, critics, auteurs, and box-office lenses only.",
    "product_read" => "Target-sensitive validation reference."
  },
  %{
    "candidate" => "cohort_percentile",
    "definition" => "Percentile within release era + popularity + language + evidence regime.",
    "product_read" => "Sorting/tie-breaker candidate."
  },
  %{
    "candidate" => "hybrid_recommended",
    "definition" =>
      "2+ lens display, confidence-adjusted sorting, cohort percentile tie-breaker.",
    "product_read" => "Expected Phase 4 product candidate."
  }
]

defmodule ScoringPhase3Bakeoff do
  alias Cinegraph.Repo

  def query!(sql, params \\ [], opts \\ []) do
    Repo.query!(sql, params, Keyword.merge([timeout: :timer.minutes(10)], opts))
  end

  def rows(sql, params \\ []) do
    result = query!(sql, params)
    Enum.map(result.rows, &row_to_map(result.columns, &1))
  end

  def one(sql, params \\ []) do
    sql |> rows(params) |> List.first()
  end

  def row_to_map(columns, row) do
    columns
    |> Enum.zip(row)
    |> Map.new()
  end

  def md_table([], _columns), do: "_No rows._\n"

  def md_table(rows, columns) do
    header = "| " <> Enum.map_join(columns, " | ", fn {label, _key} -> label end) <> " |"
    rule = "| " <> Enum.map_join(columns, " | ", fn _ -> "---" end) <> " |"

    body =
      Enum.map(rows, fn row ->
        "| " <>
          Enum.map_join(columns, " | ", fn {_label, key} ->
            row |> Map.get(key) |> md_cell()
          end) <> " |"
      end)

    Enum.join([header, rule | body], "\n") <> "\n"
  end

  def md_cell(nil), do: "n/a"
  def md_cell([]), do: "none"
  def md_cell(value) when is_list(value), do: "`#{Enum.join(value, "`, `")}`"
  def md_cell(%Decimal{} = value), do: value |> Decimal.to_float() |> md_cell()
  def md_cell(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  def md_cell(value) when is_integer(value), do: format_integer(value)

  def md_cell(value) do
    value
    |> to_string()
    |> String.replace("|", "\\|")
  end

  def format_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def decimal_to_float(nil), do: -1.0
  def decimal_to_float(%Decimal{} = value), do: Decimal.to_float(value)
  def decimal_to_float(value) when is_integer(value), do: value * 1.0
  def decimal_to_float(value) when is_float(value), do: value

  def sql_string(value), do: String.replace(value, "'", "''")
end

alias ScoringPhase3Bakeoff, as: B

IO.puts("Phase 3 scoring bake-off: checking #{matrix}")

matview =
  B.one(
    """
    SELECT schemaname, matviewname
    FROM pg_matviews
    WHERE schemaname = 'public' AND matviewname = $1
    """,
    [matrix]
  )

if is_nil(matview) do
  Mix.raise("Missing materialized view #{matrix}. Run Phase 1 SQL before Phase 3.")
end

columns =
  B.rows(
    """
    SELECT attname
    FROM pg_attribute
    WHERE attrelid = to_regclass($1)
      AND attnum > 0
      AND NOT attisdropped
    ORDER BY attnum
    """,
    [matrix]
  )
  |> Enum.map(& &1["attname"])

missing_columns = required_columns -- columns

if missing_columns != [] do
  Mix.raise(
    "Missing required scoring_evidence_matrix columns: #{Enum.join(missing_columns, ", ")}"
  )
end

matrix_checks =
  B.one("""
  SELECT
    COUNT(*) AS matrix_rows,
    COUNT(DISTINCT movie_id) AS distinct_movie_ids,
    COUNT(*) FILTER (WHERE legacy_overall_score IS NOT NULL) AS rows_with_score,
    COUNT(*) FILTER (WHERE validation_target_canonical_without_time_machine) AS canonical_targets,
    COUNT(*) FILTER (WHERE validation_target_award_without_festival) AS award_targets,
    COUNT(*) FILTER (WHERE validation_target_canonical_without_time_machine AND validation_target_award_without_festival) AS canonical_award_targets,
    COUNT(*) FILTER (
      WHERE (validation_target_canonical_without_time_machine OR validation_target_award_without_festival)
        AND present_lens_count BETWEEN 1 AND 3
    ) AS sparse_positive_targets
  FROM scoring_evidence_matrix
  """)

if matrix_checks["matrix_rows"] == 0 do
  Mix.raise("scoring_evidence_matrix is empty.")
end

if matrix_checks["matrix_rows"] != matrix_checks["distinct_movie_ids"] do
  Mix.raise("scoring_evidence_matrix movie_id is not unique.")
end

IO.puts("Phase 3 scoring bake-off: evaluating candidates")

{:ok, :done} =
  Repo.transaction(
    fn ->
      B.query!("""
      CREATE TEMP TABLE phase3_candidates ON COMMIT DROP AS
      #{candidate_select_sql}
      SELECT
        movie_id,
        title,
        release_year,
        release_era_bucket,
        runtime_bucket,
        language_bucket,
        country_bucket,
        tmdb_popularity_bucket,
        evidence_regime,
        present_lens_count,
        validation_target_canonical_without_time_machine,
        validation_target_award_without_festival,
        canonical_list_count,
        festival_nomination_count,
        festival_win_count,
        canonical_list_keys,
        has_canonical_list_data,
        has_festival_data,
        candidate_key,
        candidate_label,
        candidate_score,
        sort_score,
        scoreability_state,
        confidence_label
      FROM candidates
      """)

      candidate_keys =
        B.rows("""
        SELECT DISTINCT candidate_key, candidate_label
        FROM phase3_candidates
        ORDER BY candidate_key
        """)

      target_counts =
        Enum.map(target_sets, fn target ->
          row =
            B.one("""
            SELECT
              COUNT(*) AS total_rows,
              COUNT(*) FILTER (WHERE #{target.condition}) AS positives,
              ROUND(100.0 * COUNT(*) FILTER (WHERE #{target.condition}) / NULLIF(COUNT(*), 0), 3) AS base_rate_pct
            FROM scoring_evidence_matrix
            """)

          Map.merge(target, row)
        end)

      candidate_results =
        for target <- target_sets, candidate <- candidate_keys do
          condition = target.condition
          candidate_key = candidate["candidate_key"]

          row =
            B.one(
              """
              WITH scored AS (
                SELECT
                  movie_id,
                  (#{condition}) AS is_target,
                  candidate_score,
                  sort_score,
                  scoreability_state,
                  confidence_label
                FROM phase3_candidates
                WHERE candidate_key = $1
              ),
              usable AS (
                SELECT *
                FROM scored
                WHERE sort_score IS NOT NULL
              ),
      counts AS (
        SELECT
          COUNT(*) AS usable_rows,
          COUNT(*) FILTER (WHERE is_target) AS usable_positives,
          (SELECT COUNT(*) FILTER (WHERE is_target) FROM scored) AS positives,
          COUNT(*) FILTER (WHERE NOT is_target) AS negatives,
          COUNT(DISTINCT sort_score) AS distinct_scores
        FROM usable
              ),
              ranked_asc AS (
                SELECT
                  *,
                  RANK() OVER (ORDER BY sort_score ASC) AS first_rank,
                  COUNT(*) OVER (PARTITION BY sort_score) AS tie_count
                FROM usable
              ),
              auc AS (
                SELECT
                  CASE
            WHEN (SELECT usable_positives FROM counts) > 0
             AND (SELECT negatives FROM counts) > 0
             AND (SELECT distinct_scores FROM counts) > 1
            THEN (
              SUM(CASE WHEN is_target THEN first_rank + ((tie_count - 1)::numeric / 2.0) ELSE 0 END) -
              ((SELECT usable_positives FROM counts)::numeric * ((SELECT usable_positives FROM counts) + 1) / 2.0)
            ) / ((SELECT usable_positives FROM counts)::numeric * (SELECT negatives FROM counts))
                  END AS roc_auc
                FROM ranked_asc
              ),
              ranked_desc AS (
                SELECT
                  *,
                  ROW_NUMBER() OVER (ORDER BY sort_score DESC, movie_id ASC) AS desc_rank,
                  CUME_DIST() OVER (ORDER BY sort_score DESC) AS desc_cume
                FROM usable
              ),
              top_n AS (
                SELECT
                  COUNT(*) AS selected,
                  COUNT(*) FILTER (WHERE is_target) AS hits
                FROM ranked_desc
                WHERE desc_rank <= GREATEST((SELECT positives FROM counts), 1)
              ),
      top_decile AS (
        SELECT
          COUNT(*) AS selected,
          COUNT(*) FILTER (WHERE is_target) AS hits
        FROM ranked_desc
        WHERE desc_rank <= GREATEST(1, CEIL(0.10 * (SELECT usable_rows FROM counts))::int)
      ),
              public_quality AS (
                SELECT
                  COUNT(*) FILTER (WHERE is_target AND candidate_score IS NULL) AS hidden_positive_count,
                  COUNT(*) FILTER (WHERE is_target AND candidate_score IS NOT NULL AND candidate_score < 2.0) AS visible_false_low_count,
                  COUNT(*) FILTER (WHERE is_target AND scoreability_state = 'insufficient_evidence') AS insufficient_positive_count
                FROM scored
              ),
              coverage AS (
                SELECT
                  COUNT(*) AS total_rows,
                  COUNT(*) FILTER (WHERE candidate_score IS NULL) AS hidden_rows,
                  COUNT(*) FILTER (WHERE scoreability_state = 'scoreable') AS scoreable_rows,
                  COUNT(*) FILTER (WHERE scoreability_state = 'limited') AS limited_rows,
                  COUNT(*) FILTER (WHERE scoreability_state = 'insufficient_evidence') AS insufficient_rows
                FROM scored
              )
              SELECT
                (SELECT usable_rows FROM counts) AS usable_rows,
        (SELECT usable_positives FROM counts) AS usable_positives,
                (SELECT distinct_scores FROM counts) AS distinct_scores,
                (SELECT hidden_rows FROM coverage) AS hidden_rows,
                ROUND(100.0 * (SELECT hidden_rows FROM coverage) / NULLIF((SELECT total_rows FROM coverage), 0), 2) AS hidden_pct,
                (SELECT scoreable_rows FROM coverage) AS scoreable_rows,
                (SELECT limited_rows FROM coverage) AS limited_rows,
                (SELECT insufficient_rows FROM coverage) AS insufficient_rows,
                ROUND((SELECT roc_auc FROM auc)::numeric, 4) AS roc_auc,
                (SELECT hits FROM top_n) AS recall_at_n_hits,
                ROUND(100.0 * (SELECT hits FROM top_n) / NULLIF((SELECT positives FROM counts), 0), 2) AS recall_at_n_pct,
                ROUND(100.0 * (SELECT hits FROM top_n) / NULLIF((SELECT selected FROM top_n), 0), 2) AS precision_at_n_pct,
                (SELECT hits FROM top_decile) AS top_decile_hits,
                ROUND(
          (100.0 * (SELECT hits FROM top_decile) / NULLIF((SELECT selected FROM top_decile), 0)) /
          NULLIF(100.0 * (SELECT usable_positives FROM counts) / NULLIF((SELECT usable_rows FROM counts), 0), 0),
                  2
                ) AS top_decile_lift,
                (SELECT hidden_positive_count FROM public_quality) AS hidden_positive_count,
                ROUND(100.0 * (SELECT hidden_positive_count FROM public_quality) / NULLIF((SELECT positives FROM counts), 0), 2) AS hidden_positive_pct,
                (SELECT visible_false_low_count FROM public_quality) AS visible_false_low_count,
                ROUND(100.0 * (SELECT visible_false_low_count FROM public_quality) / NULLIF((SELECT positives FROM counts), 0), 2) AS visible_false_low_pct,
                (SELECT insufficient_positive_count FROM public_quality) AS insufficient_positive_count,
                ROUND(100.0 * (SELECT insufficient_positive_count FROM public_quality) / NULLIF((SELECT positives FROM counts), 0), 2) AS insufficient_positive_pct
              """,
              [candidate_key]
            )

          row
          |> Map.merge(%{
            "target_key" => target.key,
            "target" => target.label,
            "candidate_key" => candidate_key,
            "candidate" => candidate["candidate_label"]
          })
        end

      leaderboard =
        candidate_results
        |> Enum.filter(&(&1["target_key"] in ["canonical_any", "award_any"]))
        |> Enum.sort_by(
          fn row ->
            {
              B.decimal_to_float(row["top_decile_lift"]),
              B.decimal_to_float(row["recall_at_n_pct"]),
              -B.decimal_to_float(row["visible_false_low_pct"])
            }
          end,
          :desc
        )
        |> Enum.take(25)

      all_target_summary =
        candidate_results
        |> Enum.group_by(& &1["target"])
        |> Enum.flat_map(fn {_target, rows} ->
          rows
          |> Enum.sort_by(
            fn row ->
              {
                B.decimal_to_float(row["top_decile_lift"]),
                B.decimal_to_float(row["recall_at_n_pct"]),
                -B.decimal_to_float(row["visible_false_low_pct"])
              }
            end,
            :desc
          )
          |> Enum.take(4)
        end)

      coverage_rows =
        B.rows("""
        SELECT
          candidate_label AS candidate,
          COUNT(*) AS movies,
          COUNT(*) FILTER (WHERE candidate_score IS NULL) AS hidden_rows,
          ROUND(100.0 * COUNT(*) FILTER (WHERE candidate_score IS NULL) / NULLIF(COUNT(*), 0), 2) AS hidden_pct,
          COUNT(*) FILTER (WHERE scoreability_state = 'scoreable') AS scoreable,
          COUNT(*) FILTER (WHERE scoreability_state = 'limited') AS limited,
          COUNT(*) FILTER (WHERE scoreability_state = 'insufficient_evidence') AS insufficient,
          COUNT(*) FILTER (WHERE confidence_label = 'high') AS high_confidence,
          COUNT(*) FILTER (WHERE confidence_label = 'medium') AS medium_confidence,
          COUNT(*) FILTER (WHERE confidence_label = 'low') AS low_confidence,
          COUNT(*) FILTER (WHERE confidence_label = 'insufficient') AS insufficient_confidence
        FROM phase3_candidates
        GROUP BY candidate_key, candidate_label
        ORDER BY candidate_key
        """)

      threshold_rows =
        B.rows("""
        SELECT
          threshold,
          COUNT(*) FILTER (WHERE present_lens_count >= min_lenses AND legacy_overall_score IS NOT NULL) AS visible_rows,
          ROUND(
            100.0 * COUNT(*) FILTER (WHERE present_lens_count >= min_lenses AND legacy_overall_score IS NOT NULL) /
            NULLIF(COUNT(*), 0),
            2
          ) AS visible_pct,
          COUNT(*) FILTER (
            WHERE (validation_target_canonical_without_time_machine OR validation_target_award_without_festival)
              AND present_lens_count < min_lenses
          ) AS hidden_known_positives,
          ROUND(
            100.0 * COUNT(*) FILTER (
              WHERE (validation_target_canonical_without_time_machine OR validation_target_award_without_festival)
                AND present_lens_count < min_lenses
            ) / NULLIF(COUNT(*) FILTER (WHERE validation_target_canonical_without_time_machine OR validation_target_award_without_festival), 0),
            2
          ) AS hidden_known_positive_pct,
          ROUND(
            100.0 * COUNT(*) FILTER (
              WHERE (validation_target_canonical_without_time_machine OR validation_target_award_without_festival)
                AND present_lens_count >= min_lenses
                AND COALESCE(legacy_overall_score, 0) < 2.0
            ) / NULLIF(COUNT(*) FILTER (
              WHERE (validation_target_canonical_without_time_machine OR validation_target_award_without_festival)
                AND present_lens_count >= min_lenses
            ), 0),
            2
          ) AS visible_known_positive_false_low_pct
        FROM scoring_evidence_matrix
        CROSS JOIN (
          VALUES
            ('0+ lenses', 0),
            ('2+ lenses', 2),
            ('3+ lenses', 3),
            ('4+ lenses', 4)
        ) AS thresholds(threshold, min_lenses)
        GROUP BY threshold, min_lenses
        ORDER BY min_lenses
        """)

      cohort_rows =
        Enum.flat_map(cohort_fields, fn {field, label} ->
          B.rows("""
          SELECT
            '#{B.sql_string(label)}' AS cohort,
            #{field} AS bucket,
            candidate_label AS candidate,
            COUNT(*) AS movies,
            COUNT(*) FILTER (WHERE validation_target_canonical_without_time_machine OR validation_target_award_without_festival) AS known_positives,
            ROUND(AVG(candidate_score)::numeric, 3) AS avg_candidate_score,
            ROUND(
              100.0 * COUNT(*) FILTER (
                WHERE (validation_target_canonical_without_time_machine OR validation_target_award_without_festival)
                  AND candidate_score IS NULL
              ) / NULLIF(COUNT(*) FILTER (WHERE validation_target_canonical_without_time_machine OR validation_target_award_without_festival), 0),
              2
            ) AS hidden_known_positive_pct,
            ROUND(
              100.0 * COUNT(*) FILTER (
                WHERE (validation_target_canonical_without_time_machine OR validation_target_award_without_festival)
                  AND candidate_score IS NOT NULL
                  AND candidate_score < 2.0
              ) / NULLIF(COUNT(*) FILTER (WHERE validation_target_canonical_without_time_machine OR validation_target_award_without_festival), 0),
              2
            ) AS visible_false_low_pct
          FROM phase3_candidates
          WHERE candidate_key IN ('current_score', 'current_gated_2', 'confidence_adjusted', 'bayesian_shrinkage', 'hybrid_recommended')
          GROUP BY #{field}, candidate_key, candidate_label
          HAVING COUNT(*) >= 50
          ORDER BY visible_false_low_pct DESC NULLS LAST, hidden_known_positive_pct DESC NULLS LAST
          LIMIT 6
          """)
        end)

      high_risk_rows =
        Enum.flat_map(high_risk_filters, fn {label, filter} ->
          B.rows("""
          SELECT
            '#{B.sql_string(label)}' AS risk_cohort,
            candidate_label AS candidate,
            COUNT(*) AS movies,
            COUNT(*) FILTER (WHERE validation_target_canonical_without_time_machine OR validation_target_award_without_festival) AS known_positives,
            ROUND(
              100.0 * COUNT(*) FILTER (
                WHERE (validation_target_canonical_without_time_machine OR validation_target_award_without_festival)
                  AND candidate_score IS NULL
              ) / NULLIF(COUNT(*) FILTER (WHERE validation_target_canonical_without_time_machine OR validation_target_award_without_festival), 0),
              2
            ) AS hidden_known_positive_pct,
            ROUND(
              100.0 * COUNT(*) FILTER (
                WHERE (validation_target_canonical_without_time_machine OR validation_target_award_without_festival)
                  AND candidate_score IS NOT NULL
                  AND candidate_score < 2.0
              ) / NULLIF(COUNT(*) FILTER (WHERE validation_target_canonical_without_time_machine OR validation_target_award_without_festival), 0),
              2
            ) AS visible_false_low_pct
          FROM phase3_candidates
          WHERE #{filter}
            AND candidate_key IN ('current_score', 'current_gated_2', 'confidence_adjusted', 'bayesian_shrinkage', 'hybrid_recommended')
          GROUP BY candidate_key, candidate_label
          ORDER BY candidate_key
          """)
        end)

      safety_rows =
        B.rows("""
        SELECT
          candidate_label AS candidate,
          COUNT(*) FILTER (WHERE present_lens_count = 0 AND scoreability_state = 'scoreable') AS zero_lens_scoreable,
          COUNT(*) FILTER (WHERE present_lens_count = 1 AND scoreability_state = 'scoreable') AS one_lens_scoreable,
          COUNT(*) FILTER (WHERE present_lens_count <= 1 AND confidence_label IN ('high', 'medium')) AS low_lens_medium_or_high_confidence,
          COUNT(*) FILTER (
            WHERE evidence_regime = 'high_evidence'
              AND (validation_target_canonical_without_time_machine OR validation_target_award_without_festival)
              AND candidate_score IS NOT NULL
              AND candidate_score >= 2.0
          ) AS high_evidence_positive_not_false_low,
          COUNT(*) FILTER (
            WHERE (validation_target_canonical_without_time_machine OR validation_target_award_without_festival)
              AND present_lens_count BETWEEN 1 AND 3
              AND candidate_score IS NOT NULL
              AND candidate_score < 2.0
          ) AS sparse_positive_visible_false_low
        FROM phase3_candidates
        GROUP BY candidate_key, candidate_label
        ORDER BY candidate_key
        """)

      known_positive_failures =
        B.rows("""
        SELECT
          candidate_label AS candidate,
          title,
          release_year::text AS release_year,
          ROUND(candidate_score::numeric, 3) AS candidate_score,
          present_lens_count AS lenses,
          evidence_regime,
          scoreability_state,
          confidence_label,
          canonical_list_keys,
          festival_nomination_count,
          festival_win_count
        FROM phase3_candidates
        WHERE candidate_key IN ('current_score', 'current_gated_2', 'confidence_adjusted', 'bayesian_shrinkage', 'hybrid_recommended')
          AND (validation_target_canonical_without_time_machine OR validation_target_award_without_festival)
          AND (
            candidate_score IS NULL
            OR candidate_score < 2.0
          )
        ORDER BY
          CASE candidate_key
            WHEN 'hybrid_recommended' THEN 0
            WHEN 'current_gated_2' THEN 1
            WHEN 'confidence_adjusted' THEN 2
            WHEN 'bayesian_shrinkage' THEN 3
            ELSE 4
          END,
          present_lens_count ASC,
          festival_win_count DESC,
          canonical_list_count DESC,
          title ASC
        LIMIT 30
        """)

      high_signal_non_targets =
        B.rows("""
        SELECT
          candidate_label AS candidate,
          title,
          release_year::text AS release_year,
          ROUND(candidate_score::numeric, 3) AS candidate_score,
          ROUND(sort_score::numeric, 3) AS sort_score,
          present_lens_count AS lenses,
          evidence_regime,
          scoreability_state,
          confidence_label
        FROM phase3_candidates
        WHERE candidate_key IN ('current_score', 'confidence_adjusted', 'bayesian_shrinkage', 'hybrid_recommended')
          AND NOT validation_target_canonical_without_time_machine
          AND NOT validation_target_award_without_festival
          AND sort_score IS NOT NULL
        ORDER BY
          CASE candidate_key
            WHEN 'hybrid_recommended' THEN 0
            WHEN 'confidence_adjusted' THEN 1
            WHEN 'bayesian_shrinkage' THEN 2
            ELSE 3
          END,
          sort_score DESC,
          movie_id ASC
        LIMIT 30
        """)

      hybrid_canonical =
        Enum.find(
          candidate_results,
          &(&1["target_key"] == "canonical_any" and &1["candidate_key"] == "hybrid_recommended")
        )

      hybrid_award =
        Enum.find(
          candidate_results,
          &(&1["target_key"] == "award_any" and &1["candidate_key"] == "hybrid_recommended")
        )

      current_canonical =
        Enum.find(
          candidate_results,
          &(&1["target_key"] == "canonical_any" and &1["candidate_key"] == "current_score")
        )

      current_award =
        Enum.find(
          candidate_results,
          &(&1["target_key"] == "award_any" and &1["candidate_key"] == "current_score")
        )

      report = """
      # CineGraph Phase 3 Candidate Score Bake-Off - 2026-05-02

      This report is generated by `priv/scripts/scoring_phase3_bakeoff.exs` from the
      Phase 1 `scoring_evidence_matrix` materialized view.

      This is a research artifact only. It does not select a production implementation,
      alter scoring behavior, add schema, update database rows, enqueue jobs, change UI, or
      call external APIs.

      ## Executive Recommendation

      Phase 4 should productize a **hybrid scoreability system**, not a single replacement
      number by itself.

      Recommended Phase 4 product behavior:

      - show a numeric CineGraph score only when a movie has at least **2 present lenses**;
      - label 2-3 lens movies as limited-confidence, not fully scored;
      - treat 0-1 lens movies as `insufficient_evidence` instead of displaying a low score;
      - use a confidence-adjusted score for default sorting, with cohort percentile as a tie-breaker;
      - keep raw/current score available internally for audit and comparison;
      - do not treat canonical/festival targets as complete ground truth.

      The bake-off supports this because the current score has real signal, but Phase 2 and Phase 3
      both show that low evidence is too often confused with low quality.

      ## Matrix Checks

      #{B.md_table([%{"check" => "Matrix rows", "value" => matrix_checks["matrix_rows"]}, %{"check" => "Distinct movie IDs", "value" => matrix_checks["distinct_movie_ids"]}, %{"check" => "Rows with legacy score", "value" => matrix_checks["rows_with_score"]}, %{"check" => "Required columns present", "value" => length(required_columns) - length(missing_columns)}, %{"check" => "Canonical targets", "value" => matrix_checks["canonical_targets"]}, %{"check" => "Award/festival targets", "value" => matrix_checks["award_targets"]}, %{"check" => "Canonical + festival targets", "value" => matrix_checks["canonical_award_targets"]}, %{"check" => "Sparse-evidence known positives", "value" => matrix_checks["sparse_positive_targets"]}],
      [{"Check", "check"}, {"Value", "value"}])}

      ## Candidate Definitions

      #{B.md_table(candidate_definitions, [{"Candidate", "candidate"}, {"Definition", "definition"}, {"Product read", "product_read"}])}

      ## Target Sets

      #{B.md_table(target_counts, [{"Target", :label}, {"Positives", "positives"}, {"Base rate", "base_rate_pct"}])}

      ## Candidate Leaderboard

      Ranked across canonical and award/festival targets by top-decile lift, recall@N,
      and visible false-low behavior. Hidden/null counts are shown separately so a candidate
      cannot win by silently excluding hard movies.

      #{B.md_table(leaderboard, [{"Target", "target"}, {"Candidate", "candidate"}, {"AUC", "roc_auc"}, {"Recall@N", "recall_at_n_pct"}, {"Precision@N", "precision_at_n_pct"}, {"Top-decile lift", "top_decile_lift"}, {"Hidden rows", "hidden_rows"}, {"Hidden positives", "hidden_positive_pct"}, {"Visible false-low", "visible_false_low_pct"}])}

      ## Current Vs Hybrid

      #{B.md_table([Map.merge(current_canonical, %{"comparison" => "Canonical target / current"}), Map.merge(hybrid_canonical, %{"comparison" => "Canonical target / hybrid"}), Map.merge(current_award, %{"comparison" => "Award target / current"}), Map.merge(hybrid_award, %{"comparison" => "Award target / hybrid"})],
      [{"Comparison", "comparison"}, {"AUC", "roc_auc"}, {"Recall@N", "recall_at_n_pct"}, {"Top-decile lift", "top_decile_lift"}, {"Hidden positives", "hidden_positive_pct"}, {"Visible false-low", "visible_false_low_pct"}, {"Usable rows", "usable_rows"}])}

      ## All-Target Summary

      Top candidates per validation target, including sparse-positive and canonical+festival targets.

      #{B.md_table(all_target_summary, [{"Target", "target"}, {"Candidate", "candidate"}, {"AUC", "roc_auc"}, {"Recall@N", "recall_at_n_pct"}, {"Top-decile lift", "top_decile_lift"}, {"Hidden positives", "hidden_positive_pct"}, {"Visible false-low", "visible_false_low_pct"}])}

      ## Scoreability Coverage

      #{B.md_table(coverage_rows, [{"Candidate", "candidate"}, {"Movies", "movies"}, {"Hidden", "hidden_rows"}, {"Hidden %", "hidden_pct"}, {"Scoreable", "scoreable"}, {"Limited", "limited"}, {"Insufficient", "insufficient"}, {"High conf", "high_confidence"}, {"Medium conf", "medium_confidence"}, {"Low conf", "low_confidence"}, {"Insufficient conf", "insufficient_confidence"}])}

      ## Threshold Analysis

      The best public display threshold is **2+ present lenses**. It removes the most misleading
      0-1 lens scores while preserving substantially more catalog coverage than 3+ or 4+.

      #{B.md_table(threshold_rows, [{"Threshold", "threshold"}, {"Visible rows", "visible_rows"}, {"Visible %", "visible_pct"}, {"Hidden known positives", "hidden_known_positives"}, {"Hidden known-positive %", "hidden_known_positive_pct"}, {"Visible known-positive false-low %", "visible_known_positive_false_low_pct"}])}

      ## Product-Safety Checks

      #{B.md_table(safety_rows, [{"Candidate", "candidate"}, {"0-lens scoreable", "zero_lens_scoreable"}, {"1-lens scoreable", "one_lens_scoreable"}, {"0-1 lens medium/high conf", "low_lens_medium_or_high_confidence"}, {"High-evidence positives not false-low", "high_evidence_positive_not_false_low"}, {"Sparse positives visible false-low", "sparse_positive_visible_false_low"}])}

      ## High-Risk Cohort Comparison

      This table compares candidates on the cohorts Phase 2 identified as most fragile.
      For product display, hidden known positives are preferable to visible false-low scores,
      but too much hiding can make the score useless for sorting.

      #{B.md_table(high_risk_rows, [{"Risk cohort", "risk_cohort"}, {"Candidate", "candidate"}, {"Movies", "movies"}, {"Known positives", "known_positives"}, {"Hidden known-positive %", "hidden_known_positive_pct"}, {"Visible false-low %", "visible_false_low_pct"}])}

      ## Cohort Fairness Scan

      Worst cohort/candidate combinations by visible known-positive false-low rate.

      #{B.md_table(cohort_rows, [{"Cohort", "cohort"}, {"Bucket", "bucket"}, {"Candidate", "candidate"}, {"Movies", "movies"}, {"Known positives", "known_positives"}, {"Avg candidate score", "avg_candidate_score"}, {"Hidden known-positive %", "hidden_known_positive_pct"}, {"Visible false-low %", "visible_false_low_pct"}])}

      ## Failure Examples: Known Positives Still Hidden Or Low

      These are not necessarily bad rows. They identify where Phase 4 copy and data-backfill
      strategy matter most.

      #{B.md_table(known_positive_failures, [{"Candidate", "candidate"}, {"Movie", "title"}, {"Year", "release_year"}, {"Score", "candidate_score"}, {"Lenses", "lenses"}, {"Evidence", "evidence_regime"}, {"State", "scoreability_state"}, {"Confidence", "confidence_label"}, {"Canonical keys", "canonical_list_keys"}, {"Noms", "festival_nomination_count"}, {"Wins", "festival_win_count"}])}

      ## Failure Examples: High-Signal Non-Targets Preserved

      These show why canonical/festival targets are incomplete ground truth. A candidate should
      not erase plausible high-signal movies just because they are absent from those target sets.

      #{B.md_table(high_signal_non_targets, [{"Candidate", "candidate"}, {"Movie", "title"}, {"Year", "release_year"}, {"Score", "candidate_score"}, {"Sort score", "sort_score"}, {"Lenses", "lenses"}, {"Evidence", "evidence_regime"}, {"State", "scoreability_state"}, {"Confidence", "confidence_label"}])}

      ## Phase 4 Handoff

      Phase 4 may productize the following fields after implementation planning:

      - `cinegraph_score`: display score, null when insufficient evidence;
      - `cinegraph_sort_score`: confidence-adjusted sorting score;
      - `scoreability_state`: `scoreable`, `limited`, or `insufficient_evidence`;
      - `score_confidence_label`: `high`, `medium`, `low`, or `insufficient`;
      - `present_lens_count`;
      - `evidence_confidence`;
      - `cohort_percentile`, if used as a secondary sort or explanatory detail.

      Phase 4 should decide whether these belong in `movie_score_caches`, a dedicated score cache,
      or a derived query/view. Phase 3 intentionally makes no schema decision.

      ## Reproducibility

      Run:

      ```bash
      mix run priv/scripts/scoring_phase3_bakeoff.exs
      ```

      The script performs read-only queries against `scoring_evidence_matrix` and writes this report.
      """

      File.write!(report_path, report)
      IO.puts("Phase 3 scoring bake-off report written to #{report_path}")
      :done
    end,
    timeout: :timer.minutes(60)
  )
