# Phase 2 CineGraph scoring validation harness.
#
# Run with:
#   mix run priv/scripts/scoring_phase2_validation.exs
#
# This is a research-only script. It reads from the Phase 1
# scoring_evidence_matrix materialized view and writes a markdown report.

alias Cinegraph.Repo
require Logger

Logger.configure(level: :warning)

report_path = "docs/scoring/reports/scoring_validation_phase2_2026_05_02.md"
matrix = "scoring_evidence_matrix"

required_columns = ~w[
  movie_id title release_year release_era_bucket runtime_bucket language_bucket
  country_bucket tmdb_popularity_bucket legacy_overall_score mob_score
  critics_score festival_recognition_score time_machine_score auteurs_score
  box_office_score evidence_confidence_baseline evidence_regime present_lens_count
  validation_target_canonical_without_time_machine validation_target_award_without_festival canonical_list_count
  festival_nomination_count festival_win_count canonical_list_keys
]

target_sets = [
  %{
    key: "canonical_any",
    label: "Canonical target",
    condition: "validation_target_canonical_without_time_machine",
    description: "Movies present in at least one canonical source."
  },
  %{
    key: "award_any",
    label: "Award/festival target",
    condition: "validation_target_award_without_festival",
    description: "Movies with at least one festival or award nomination/win row."
  },
  %{
    key: "canonical_and_festival",
    label: "Canonical + festival intersection",
    condition: "validation_target_canonical_without_time_machine AND validation_target_award_without_festival",
    description: "High-confidence positives that appear in canonical and festival/award evidence."
  },
  %{
    key: "sparse_positive",
    label: "Sparse-evidence known positives",
    condition:
      "(validation_target_canonical_without_time_machine OR validation_target_award_without_festival) AND present_lens_count BETWEEN 1 AND 3",
    description: "Known-positive films with only one to three present score lenses."
  }
]

baselines = [
  %{
    key: "current_score",
    label: "Current legacy score",
    score: "legacy_overall_score",
    leakage_note: "Uses the current production cached score."
  },
  %{
    key: "present_lens_average",
    label: "Present-lens average",
    score: """
    CASE
      WHEN present_lens_count > 0 THEN (
        COALESCE(mob_score, 0) +
        COALESCE(critics_score, 0) +
        COALESCE(festival_recognition_score, 0) +
        COALESCE(time_machine_score, 0) +
        COALESCE(auteurs_score, 0) +
        COALESCE(box_office_score, 0)
      ) / present_lens_count
    END
    """,
    leakage_note: "Averages only lenses that are present."
  },
  %{
    key: "present_lens_count",
    label: "Present-lens count only",
    score: "present_lens_count::double precision",
    leakage_note: "Measures evidence availability, not quality."
  },
  %{
    key: "evidence_confidence",
    label: "Evidence confidence baseline",
    score: "evidence_confidence_baseline::double precision",
    leakage_note: "Measures source coverage and confidence."
  },
  %{
    key: "audience_only",
    label: "Audience-only lens",
    score: "NULLIF(mob_score, 0)",
    leakage_note: "Single-family baseline."
  },
  %{
    key: "critics_only",
    label: "Critics-only lens",
    score: "NULLIF(critics_score, 0)",
    leakage_note: "Single-family baseline."
  },
  %{
    key: "festival_only",
    label: "Festival-only lens",
    score: "NULLIF(festival_recognition_score, 0)",
    leakage_note: "Leaks award targets; use only as a reference there."
  },
  %{
    key: "auteurs_only",
    label: "Auteurs-only lens",
    score: "NULLIF(auteurs_score, 0)",
    leakage_note: "Single-family baseline."
  },
  %{
    key: "box_office_only",
    label: "Box-office-only lens",
    score: "NULLIF(box_office_score, 0)",
    leakage_note: "Single-family baseline."
  },
  %{
    key: "no_canonical_proxy",
    label: "No-canonical proxy",
    score: """
    CASE
      WHEN (
        (COALESCE(mob_score, 0) > 0)::int +
        (COALESCE(critics_score, 0) > 0)::int +
        (COALESCE(festival_recognition_score, 0) > 0)::int +
        (COALESCE(auteurs_score, 0) > 0)::int +
        (COALESCE(box_office_score, 0) > 0)::int
      ) > 0 THEN (
        COALESCE(mob_score, 0) +
        COALESCE(critics_score, 0) +
        COALESCE(festival_recognition_score, 0) +
        COALESCE(auteurs_score, 0) +
        COALESCE(box_office_score, 0)
      ) / (
        (COALESCE(mob_score, 0) > 0)::int +
        (COALESCE(critics_score, 0) > 0)::int +
        (COALESCE(festival_recognition_score, 0) > 0)::int +
        (COALESCE(auteurs_score, 0) > 0)::int +
        (COALESCE(box_office_score, 0) > 0)::int
      )
    END
    """,
    leakage_note: "Excludes time-machine/canonical-adjacent lens."
  },
  %{
    key: "no_festival_proxy",
    label: "No-festival proxy",
    score: """
    CASE
      WHEN (
        (COALESCE(mob_score, 0) > 0)::int +
        (COALESCE(critics_score, 0) > 0)::int +
        (COALESCE(time_machine_score, 0) > 0)::int +
        (COALESCE(auteurs_score, 0) > 0)::int +
        (COALESCE(box_office_score, 0) > 0)::int
      ) > 0 THEN (
        COALESCE(mob_score, 0) +
        COALESCE(critics_score, 0) +
        COALESCE(time_machine_score, 0) +
        COALESCE(auteurs_score, 0) +
        COALESCE(box_office_score, 0)
      ) / (
        (COALESCE(mob_score, 0) > 0)::int +
        (COALESCE(critics_score, 0) > 0)::int +
        (COALESCE(time_machine_score, 0) > 0)::int +
        (COALESCE(auteurs_score, 0) > 0)::int +
        (COALESCE(box_office_score, 0) > 0)::int
      )
    END
    """,
    leakage_note: "Excludes festival-recognition lens."
  },
  %{
    key: "cohort_percentile_current",
    label: "Cohort-percentile current score",
    score: """
    PERCENT_RANK() OVER (
      PARTITION BY release_era_bucket, tmdb_popularity_bucket, language_bucket, evidence_regime
      ORDER BY COALESCE(legacy_overall_score, 0)
    )
    """,
    leakage_note: "Normalizes current score within coarse evidence/cohort buckets."
  },
  %{
    key: "gated_2_lenses",
    label: "Current score, 2+ lenses only",
    score: "CASE WHEN present_lens_count >= 2 THEN legacy_overall_score END",
    leakage_note: "Hides/omits zero- and one-lens scores."
  },
  %{
    key: "gated_3_lenses",
    label: "Current score, 3+ lenses only",
    score: "CASE WHEN present_lens_count >= 3 THEN legacy_overall_score END",
    leakage_note: "Requires moderate evidence."
  },
  %{
    key: "gated_4_lenses",
    label: "Current score, 4+ lenses only",
    score: "CASE WHEN present_lens_count >= 4 THEN legacy_overall_score END",
    leakage_note: "Requires high evidence."
  }
]

cohort_fields = [
  {"release_era_bucket", "Release era"},
  {"tmdb_popularity_bucket", "TMDb popularity"},
  {"language_bucket", "Language"},
  {"country_bucket", "Country"},
  {"runtime_bucket", "Runtime"},
  {"evidence_regime", "Evidence regime"},
  {"has_canonical_list_data::text", "Canonical status"},
  {"has_festival_data::text", "Festival status"}
]

defmodule ScoringPhase2Validation do
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

  def fmt(nil), do: "n/a"
  def fmt(%Decimal{} = decimal), do: decimal |> Decimal.to_float() |> fmt()
  def fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  def fmt(value) when is_integer(value), do: format_integer(value)
  def fmt(value), do: to_string(value)

  def pct(nil), do: "n/a"
  def pct(%Decimal{} = decimal), do: decimal |> Decimal.to_float() |> pct()
  def pct(value) when is_float(value), do: "#{:erlang.float_to_binary(value, decimals: 2)}%"
  def pct(value) when is_integer(value), do: "#{value}%"

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
  def md_cell(%Decimal{} = value), do: fmt(value)
  def md_cell(value) when is_float(value), do: fmt(value)
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

  def sql_string(value), do: value |> String.replace("'", "''")

  def decimal_to_float(nil), do: -1.0
  def decimal_to_float(%Decimal{} = value), do: Decimal.to_float(value)
  def decimal_to_float(value) when is_integer(value), do: value * 1.0
  def decimal_to_float(value) when is_float(value), do: value
end

alias ScoringPhase2Validation, as: V

IO.puts("Phase 2 scoring validation: checking #{matrix}")

matview =
  V.one("""
  SELECT schemaname, matviewname
  FROM pg_matviews
  WHERE schemaname = 'public' AND matviewname = $1
  """, [matrix])

if is_nil(matview) do
  Mix.raise("Missing materialized view #{matrix}. Run Phase 1 SQL before Phase 2.")
end

columns =
  V.rows("""
  SELECT attname
  FROM pg_attribute
  WHERE attrelid = to_regclass($1)
    AND attnum > 0
    AND NOT attisdropped
  ORDER BY attnum
  """, [matrix])
  |> Enum.map(& &1["attname"])

missing_columns = required_columns -- columns

if missing_columns != [] do
  Mix.raise("Missing required scoring_evidence_matrix columns: #{Enum.join(missing_columns, ", ")}")
end

matrix_checks =
  V.one("""
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

IO.puts("Phase 2 scoring validation: profiling target sets and baselines")

target_counts =
  Enum.map(target_sets, fn target ->
    row =
      V.one("""
      SELECT
        COUNT(*) AS total_rows,
        COUNT(*) FILTER (WHERE #{target.condition}) AS positives,
        ROUND(100.0 * COUNT(*) FILTER (WHERE #{target.condition}) / NULLIF(COUNT(*), 0), 3) AS base_rate_pct
      FROM scoring_evidence_matrix
      """)

    Map.merge(target, row)
  end)

baseline_results =
  for target <- target_sets, baseline <- baselines do
    score = baseline.score
    condition = target.condition

    row =
      V.one("""
      WITH scored AS (
        SELECT
          movie_id,
          (#{condition}) AS is_target,
          (#{score})::double precision AS score
        FROM scoring_evidence_matrix
      ),
      usable AS (
        SELECT *
        FROM scored
        WHERE score IS NOT NULL
      ),
      counts AS (
        SELECT
          COUNT(*) AS usable_rows,
          COUNT(*) FILTER (WHERE is_target) AS positives,
          COUNT(*) FILTER (WHERE NOT is_target) AS negatives,
          COUNT(DISTINCT score) AS distinct_scores
        FROM usable
      ),
      ranked_asc AS (
        SELECT
          *,
          RANK() OVER (ORDER BY score ASC) AS first_rank,
          COUNT(*) OVER (PARTITION BY score) AS tie_count
        FROM usable
      ),
      auc AS (
        SELECT
          CASE
            WHEN (SELECT positives FROM counts) > 0
             AND (SELECT negatives FROM counts) > 0
             AND (SELECT distinct_scores FROM counts) > 1
            THEN (
              SUM(CASE WHEN is_target THEN first_rank + ((tie_count - 1)::numeric / 2.0) ELSE 0 END) -
              ((SELECT positives FROM counts)::numeric * ((SELECT positives FROM counts) + 1) / 2.0)
            ) / ((SELECT positives FROM counts)::numeric * (SELECT negatives FROM counts))
          END AS roc_auc
        FROM ranked_asc
      ),
      ranked_desc AS (
        SELECT
          *,
          ROW_NUMBER() OVER (ORDER BY score DESC, movie_id ASC) AS desc_rank,
          CUME_DIST() OVER (ORDER BY score DESC) AS desc_cume,
          NTILE(10) OVER (ORDER BY score DESC, movie_id ASC) AS desc_decile
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
        WHERE desc_decile = 1
      ),
      false_low AS (
        SELECT
          COUNT(*) FILTER (WHERE is_target AND desc_cume > 0.50) AS target_below_median,
          COUNT(*) FILTER (WHERE is_target AND desc_cume > 0.75) AS target_bottom_quartile
        FROM ranked_desc
      )
      SELECT
        (SELECT usable_rows FROM counts) AS usable_rows,
        (SELECT positives FROM counts) AS positives,
        (SELECT negatives FROM counts) AS negatives,
        (SELECT distinct_scores FROM counts) AS distinct_scores,
        #{matrix_checks["matrix_rows"]} - (SELECT usable_rows FROM counts) AS null_or_insufficient_rows,
        ROUND((SELECT roc_auc FROM auc)::numeric, 4) AS roc_auc,
        (SELECT selected FROM top_n) AS top_n_selected,
        (SELECT hits FROM top_n) AS recall_at_n_hits,
        ROUND(100.0 * (SELECT hits FROM top_n) / NULLIF((SELECT positives FROM counts), 0), 2) AS recall_at_n_pct,
        ROUND(100.0 * (SELECT hits FROM top_n) / NULLIF((SELECT selected FROM top_n), 0), 2) AS precision_at_n_pct,
        (SELECT selected FROM top_decile) AS top_decile_selected,
        (SELECT hits FROM top_decile) AS top_decile_hits,
        ROUND(
          (100.0 * (SELECT hits FROM top_decile) / NULLIF((SELECT selected FROM top_decile), 0)) /
          NULLIF(100.0 * (SELECT positives FROM counts) / NULLIF((SELECT usable_rows FROM counts), 0), 0),
          2
        ) AS top_decile_lift,
        (SELECT target_below_median FROM false_low) AS target_below_median,
        ROUND(100.0 * (SELECT target_below_median FROM false_low) / NULLIF((SELECT positives FROM counts), 0), 2) AS target_below_median_pct,
        (SELECT target_bottom_quartile FROM false_low) AS target_bottom_quartile,
        ROUND(100.0 * (SELECT target_bottom_quartile FROM false_low) / NULLIF((SELECT positives FROM counts), 0), 2) AS target_bottom_quartile_pct
      """)

    row
    |> Map.merge(%{
      "target_key" => target.key,
      "target" => target.label,
      "baseline_key" => baseline.key,
      "baseline" => baseline.label,
      "leakage_note" => baseline.leakage_note
    })
  end

leaderboard =
  baseline_results
  |> Enum.filter(&(&1["target_key"] in ["canonical_any", "award_any"]))
  |> Enum.sort_by(
    fn row ->
      {
        V.decimal_to_float(row["top_decile_lift"]),
        V.decimal_to_float(row["recall_at_n_pct"]),
        V.decimal_to_float(row["roc_auc"])
      }
    end,
    :desc
  )
  |> Enum.take(20)

all_target_summary =
  baseline_results
  |> Enum.group_by(& &1["target"])
  |> Enum.flat_map(fn {_target, rows} ->
    rows
    |> Enum.sort_by(
      fn row ->
        {
          V.decimal_to_float(row["top_decile_lift"]),
          V.decimal_to_float(row["recall_at_n_pct"]),
          V.decimal_to_float(row["roc_auc"])
        }
      end,
      :desc
    )
    |> Enum.take(5)
  end)

cohort_rows =
  Enum.flat_map(cohort_fields, fn {field, label} ->
    V.rows("""
    SELECT
      '#{V.sql_string(label)}' AS cohort,
      #{field} AS bucket,
      COUNT(*) AS movies,
      COUNT(*) FILTER (WHERE legacy_overall_score IS NOT NULL) AS scored,
      COUNT(*) FILTER (WHERE validation_target_canonical_without_time_machine OR validation_target_award_without_festival) AS known_positives,
      ROUND(AVG(legacy_overall_score)::numeric, 3) AS avg_current_score,
      ROUND(AVG(evidence_confidence_baseline)::numeric, 3) AS avg_evidence_confidence,
      ROUND(AVG(present_lens_count)::numeric, 3) AS avg_present_lenses,
      ROUND(
        100.0 * COUNT(*) FILTER (
          WHERE (validation_target_canonical_without_time_machine OR validation_target_award_without_festival)
            AND COALESCE(legacy_overall_score, 0) < 2.0
        ) / NULLIF(COUNT(*) FILTER (WHERE validation_target_canonical_without_time_machine OR validation_target_award_without_festival), 0),
        2
      ) AS known_positive_false_low_pct
    FROM scoring_evidence_matrix
    GROUP BY #{field}
    HAVING COUNT(*) >= 50
    ORDER BY known_positive_false_low_pct DESC NULLS LAST, movies DESC
    LIMIT 12
    """)
  end)

calibration_rows =
  V.rows("""
  SELECT
    evidence_regime,
    COUNT(*) AS movies,
    COUNT(*) FILTER (WHERE legacy_overall_score IS NOT NULL) AS scored,
    COUNT(*) FILTER (WHERE validation_target_canonical_without_time_machine OR validation_target_award_without_festival) AS known_positives,
    ROUND(AVG(legacy_overall_score)::numeric, 3) AS avg_current_score,
    ROUND(AVG(evidence_confidence_baseline)::numeric, 3) AS avg_evidence_confidence,
    ROUND(AVG(present_lens_count)::numeric, 3) AS avg_present_lenses,
    ROUND(
      100.0 * COUNT(*) FILTER (
        WHERE (validation_target_canonical_without_time_machine OR validation_target_award_without_festival)
          AND COALESCE(legacy_overall_score, 0) < 2.0
      ) / NULLIF(COUNT(*) FILTER (WHERE validation_target_canonical_without_time_machine OR validation_target_award_without_festival), 0),
      2
    ) AS known_positive_false_low_pct
  FROM scoring_evidence_matrix
  GROUP BY evidence_regime
  ORDER BY MIN(present_lens_count)
  """)

false_negatives =
  V.rows("""
  SELECT
    title,
    release_year::text AS release_year,
    legacy_overall_score AS score,
    present_lens_count AS lenses,
    evidence_regime,
    canonical_list_keys,
    festival_nomination_count,
    festival_win_count,
    ROUND(evidence_confidence_baseline::numeric, 3) AS evidence_confidence
  FROM scoring_evidence_matrix
  WHERE (validation_target_canonical_without_time_machine OR validation_target_award_without_festival)
    AND COALESCE(legacy_overall_score, 0) < 2.0
  ORDER BY present_lens_count ASC, legacy_overall_score ASC NULLS FIRST, festival_win_count DESC, canonical_list_count DESC
  LIMIT 25
  """)

false_positives =
  V.rows("""
  WITH ranked AS (
    SELECT
      title,
      release_year::text AS release_year,
      legacy_overall_score,
      present_lens_count,
      evidence_regime,
      canonical_list_keys,
      festival_nomination_count,
      festival_win_count,
      ROW_NUMBER() OVER (ORDER BY legacy_overall_score DESC NULLS LAST, movie_id ASC) AS rank
    FROM scoring_evidence_matrix
    WHERE legacy_overall_score IS NOT NULL
      AND NOT validation_target_canonical_without_time_machine
      AND NOT validation_target_award_without_festival
  )
  SELECT
    title,
    release_year,
    legacy_overall_score AS score,
    present_lens_count AS lenses,
    evidence_regime,
    canonical_list_keys,
    festival_nomination_count,
    festival_win_count
  FROM ranked
  WHERE rank <= 25
  """)

current_canonical =
  Enum.find(baseline_results, &(&1["target_key"] == "canonical_any" and &1["baseline_key"] == "current_score"))

no_canonical =
  Enum.find(baseline_results, &(&1["target_key"] == "canonical_any" and &1["baseline_key"] == "no_canonical_proxy"))

current_award =
  Enum.find(baseline_results, &(&1["target_key"] == "award_any" and &1["baseline_key"] == "current_score"))

no_festival =
  Enum.find(baseline_results, &(&1["target_key"] == "award_any" and &1["baseline_key"] == "no_festival_proxy"))

report = """
# CineGraph Phase 2 Scoring Validation Report - 2026-05-02

This report is generated by `priv/scripts/scoring_phase2_validation.exs` from the
Phase 1 `scoring_evidence_matrix` materialized view.

This is a research artifact only. It does not select a final model, alter scoring
behavior, update database rows, or add product schema.

## Executive Summary

We are still on the correct path. Phase 2 confirms that the core product question is
not just "what is the right score?" but "when is a score mathematically safe enough
to show, and when should it be normalized, qualified, or hidden?"

The current score is useful for high-evidence movies, but it is entangled with evidence
availability. The validation harness therefore compares the current score against
simple baselines and leakage-safe proxies before any replacement score is proposed.

## Matrix Checks

#{V.md_table([
  %{"check" => "Matrix rows", "value" => matrix_checks["matrix_rows"]},
  %{"check" => "Distinct movie IDs", "value" => matrix_checks["distinct_movie_ids"]},
  %{"check" => "Rows with legacy score", "value" => matrix_checks["rows_with_score"]},
  %{"check" => "Required columns present", "value" => length(required_columns) - length(missing_columns)},
  %{"check" => "Canonical targets", "value" => matrix_checks["canonical_targets"]},
  %{"check" => "Award/festival targets", "value" => matrix_checks["award_targets"]},
  %{"check" => "Canonical + festival targets", "value" => matrix_checks["canonical_award_targets"]},
  %{"check" => "Sparse-evidence known positives", "value" => matrix_checks["sparse_positive_targets"]}
], [{"Check", "check"}, {"Value", "value"}])}

## Target Sets

#{V.md_table(target_counts, [
  {"Target", :label},
  {"Description", :description},
  {"Positives", "positives"},
  {"Base rate", "base_rate_pct"}
])}

## Baseline Leaderboard

Ranked across canonical and award/festival targets by top-decile lift, recall@N, and AUC.
Rows with high null counts are not product recommendations; they show how much each signal
would leave unscored.

#{V.md_table(leaderboard, [
  {"Target", "target"},
  {"Baseline", "baseline"},
  {"AUC", "roc_auc"},
  {"Recall@N", "recall_at_n_pct"},
  {"Precision@N", "precision_at_n_pct"},
  {"Top-decile lift", "top_decile_lift"},
  {"False-low below median", "target_below_median_pct"},
  {"Null / insufficient", "null_or_insufficient_rows"}
])}

## Leakage-Safe Comparisons

For canonical validation, the no-canonical proxy excludes the time-machine/canonical-adjacent
lens. For award validation, the no-festival proxy excludes the festival-recognition lens.

#{V.md_table([
  Map.merge(current_canonical, %{"comparison" => "Canonical target / current score"}),
  Map.merge(no_canonical, %{"comparison" => "Canonical target / no-canonical proxy"}),
  Map.merge(current_award, %{"comparison" => "Award target / current score"}),
  Map.merge(no_festival, %{"comparison" => "Award target / no-festival proxy"})
], [
  {"Comparison", "comparison"},
  {"AUC", "roc_auc"},
  {"Recall@N", "recall_at_n_pct"},
  {"Top-decile lift", "top_decile_lift"},
  {"False-low below median", "target_below_median_pct"},
  {"Usable rows", "usable_rows"}
])}

## All-Target Baseline Summary

Top five baselines per validation target. This keeps the sparse-positive and
canonical+festival target sets visible without turning the report into a full dump.

#{V.md_table(all_target_summary, [
  {"Target", "target"},
  {"Baseline", "baseline"},
  {"AUC", "roc_auc"},
  {"Recall@N", "recall_at_n_pct"},
  {"Top-decile lift", "top_decile_lift"},
  {"False-low below median", "target_below_median_pct"},
  {"Null / insufficient", "null_or_insufficient_rows"}
])}

## Evidence Calibration

#{V.md_table(calibration_rows, [
  {"Evidence regime", "evidence_regime"},
  {"Movies", "movies"},
  {"Scored", "scored"},
  {"Known positives", "known_positives"},
  {"Avg score", "avg_current_score"},
  {"Avg confidence", "avg_evidence_confidence"},
  {"Avg lenses", "avg_present_lenses"},
  {"Known-positive false-low", "known_positive_false_low_pct"}
])}

## Cohort Disparity Scan

These are the highest-risk cohort buckets where known-positive movies most often score
below 2.0 under the current score. Buckets with fewer than 50 movies are excluded.

#{V.md_table(cohort_rows, [
  {"Cohort", "cohort"},
  {"Bucket", "bucket"},
  {"Movies", "movies"},
  {"Known positives", "known_positives"},
  {"Avg score", "avg_current_score"},
  {"Avg confidence", "avg_evidence_confidence"},
  {"Avg lenses", "avg_present_lenses"},
  {"Known-positive false-low", "known_positive_false_low_pct"}
])}

## Failure Analysis: Known Positives Scoring Below 2.0

These are not necessarily bad rows. They are examples where the system likely has too
little evidence to make a confident quality claim.

#{V.md_table(false_negatives, [
  {"Movie", "title"},
  {"Year", "release_year"},
  {"Score", "score"},
  {"Lenses", "lenses"},
  {"Evidence", "evidence_regime"},
  {"Canonical keys", "canonical_list_keys"},
  {"Noms", "festival_nomination_count"},
  {"Wins", "festival_win_count"},
  {"Confidence", "evidence_confidence"}
])}

## Failure Analysis: High Current Scores Without Canonical/Festival Targets

These are not necessarily false positives. They show where the current score finds high
signal outside the two validation target families.

#{V.md_table(false_positives, [
  {"Movie", "title"},
  {"Year", "release_year"},
  {"Score", "score"},
  {"Lenses", "lenses"},
  {"Evidence", "evidence_regime"},
  {"Canonical keys", "canonical_list_keys"},
  {"Noms", "festival_nomination_count"},
  {"Wins", "festival_win_count"}
])}

## Interpretation

Phase 2 should not be treated as final model selection. The target labels are partial:
canonical and festival data are strong but incomplete proxies for quality. The goal here
is to detect whether scoring behavior is stable, fair, and useful across evidence regimes.

The strongest product direction to test next is a hybrid:

- keep a score for high-evidence movies;
- show a confidence/coverage label with every score;
- use cohort-relative percentiles for sorting comparisons;
- hide or qualify scores for zero- and one-lens movies;
- test leakage-safe score formulas before changing production scoring.

## Phase 3 Recommendation

Phase 3 should run a model bake-off using this validation harness as the measuring stick.
It should compare a small set of candidate formulas and explicitly decide:

1. the minimum evidence threshold for showing a numeric score;
2. whether the public sort should use raw score, confidence-adjusted score, or cohort percentile;
3. which confidence labels map to user-facing copy;
4. whether selected fields should be promoted into `movie_score_caches` or a new production cache.

Do not ship a scoring behavior change directly from Phase 2.

## Reproducibility

Run:

```bash
mix run priv/scripts/scoring_phase2_validation.exs
```

The script performs read-only queries against `scoring_evidence_matrix` and writes this report.
"""

File.write!(report_path, report)
IO.puts("Phase 2 scoring validation report written to #{report_path}")
