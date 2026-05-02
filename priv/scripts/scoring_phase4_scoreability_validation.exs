# Phase 4 CineGraph scoreability validation.
#
# Run with:
#   mix run priv/scripts/scoring_phase4_scoreability_validation.exs
#
# This is a read-only validation script for the product scoreability view. It
# writes a markdown report under docs/scoring/reports.

report_path = "docs/scoring/reports/scoring_phase4_scoreability_validation_2026_05_02.md"

defmodule ScoringPhase4ScoreabilityValidation do
  def query!(sql, params \\ []) do
    case Cinegraph.Repo.query(sql, params, timeout: :timer.minutes(10)) do
      {:ok, result} -> result
      {:error, error} -> Mix.raise(Exception.message(error))
    end
  end

  def rows(result) do
    Enum.map(result.rows, fn row ->
      result.columns
      |> Enum.zip(row)
      |> Map.new()
    end)
  end

  def one(sql), do: sql |> query!() |> rows() |> List.first()

  def fmt(nil), do: "n/a"

  def fmt(value) when is_float(value) do
    :erlang.float_to_binary(Float.round(value, 3), decimals: 3)
  end

  def fmt(%Decimal{} = value), do: value |> Decimal.to_float() |> fmt()

  def fmt(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def fmt(value), do: to_string(value)

  def md_table(rows, columns) do
    header = "| " <> Enum.map_join(columns, " | ", &elem(&1, 0)) <> " |"
    divider = "| " <> Enum.map_join(columns, " | ", fn _ -> "---" end) <> " |"

    body =
      Enum.map(rows, fn row ->
        "| " <>
          Enum.map_join(columns, " | ", fn {_label, key} ->
            row |> Map.get(key) |> fmt() |> String.replace("|", "\\|")
          end) <> " |"
      end)

    Enum.join([header, divider | body], "\n")
  end
end

alias ScoringPhase4ScoreabilityValidation, as: V

view_exists =
  V.one("""
  SELECT to_regclass('public.movie_scoreability_view') IS NOT NULL AS exists
  """)

unless view_exists["exists"] do
  Mix.raise("movie_scoreability_view does not exist. Run migrations before validation.")
end

required_columns = ~w[
  movie_id raw_cinegraph_score legacy_score_confidence mob_score critics_score
  festival_recognition_score time_machine_score auteurs_score box_office_score
  present_lens_count missing_lens_count present_lens_labels missing_lens_labels
  evidence_confidence scoreability_state score_confidence_label cinegraph_display_score
  cinegraph_sort_score cohort_percentile score_hidden_reason score_explanation_short
  score_explanation_detail
]

columns =
  V.query!("""
  SELECT column_name
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'movie_scoreability_view'
  """)
  |> V.rows()
  |> Enum.map(& &1["column_name"])

missing_columns = required_columns -- columns

if missing_columns != [] do
  Mix.raise("movie_scoreability_view is missing columns: #{Enum.join(missing_columns, ", ")}")
end

checks =
  V.query!("""
  SELECT 'View rows' AS check, COUNT(*)::text AS value FROM movie_scoreability_view
  UNION ALL
  SELECT 'Distinct movie IDs', COUNT(DISTINCT movie_id)::text FROM movie_scoreability_view
  UNION ALL
  SELECT 'Movies table rows', (SELECT COUNT(*)::text FROM movies)
  UNION ALL
  SELECT 'Rows with raw score', COUNT(*) FILTER (WHERE raw_cinegraph_score IS NOT NULL)::text FROM movie_scoreability_view
  UNION ALL
  SELECT '0-lens numeric display count', COUNT(*) FILTER (WHERE present_lens_count = 0 AND cinegraph_display_score IS NOT NULL)::text FROM movie_scoreability_view
  UNION ALL
  SELECT '1-lens numeric display count', COUNT(*) FILTER (WHERE present_lens_count = 1 AND cinegraph_display_score IS NOT NULL)::text FROM movie_scoreability_view
  UNION ALL
  SELECT '2+ lens numeric display count', COUNT(*) FILTER (WHERE present_lens_count >= 2 AND cinegraph_display_score IS NOT NULL)::text FROM movie_scoreability_view
  """)
  |> V.rows()

scoreability_buckets =
  V.query!("""
  SELECT
    scoreability_state AS state,
    score_confidence_label AS confidence,
    COUNT(*) AS movies,
    COUNT(*) FILTER (WHERE cinegraph_display_score IS NOT NULL) AS visible_scores
  FROM movie_scoreability_view
  GROUP BY scoreability_state, score_confidence_label
  ORDER BY
    CASE scoreability_state
      WHEN 'scoreable' THEN 1
      WHEN 'limited' THEN 2
      ELSE 3
    END,
    score_confidence_label
  """)
  |> V.rows()

thresholds =
  V.query!("""
  WITH thresholds(min_lenses) AS (VALUES (0), (2), (3), (4))
  SELECT
    (min_lenses::text || '+ lenses') AS threshold,
    COUNT(*) FILTER (WHERE present_lens_count >= min_lenses AND raw_cinegraph_score IS NOT NULL) AS visible_rows,
    ROUND(
      100.0 * COUNT(*) FILTER (WHERE present_lens_count >= min_lenses AND raw_cinegraph_score IS NOT NULL) /
      NULLIF(COUNT(*), 0),
      2
    ) AS visible_pct
  FROM movie_scoreability_view, thresholds
  GROUP BY min_lenses
  ORDER BY min_lenses
  """)
  |> V.rows()

sample_rows =
  V.query!("""
  SELECT
    title,
    release_year::text,
    raw_cinegraph_score,
    cinegraph_display_score,
    present_lens_count,
    scoreability_state,
    score_confidence_label,
    score_hidden_reason
  FROM (
    SELECT
      title,
      EXTRACT(YEAR FROM release_date)::int AS release_year,
      raw_cinegraph_score,
      cinegraph_display_score,
      present_lens_count,
      scoreability_state,
      score_confidence_label,
      score_hidden_reason,
      ROW_NUMBER() OVER (PARTITION BY scoreability_state ORDER BY movie_id) AS rn
    FROM movie_scoreability_view
  ) samples
  WHERE rn <= 5
  ORDER BY scoreability_state, rn
  """)
  |> V.rows()

report = """
# CineGraph Phase 4 Scoreability Validation - 2026-05-02

This report validates the product `movie_scoreability_view`.

This is a baseline implementation check only. It does not change scores, refresh caches,
enqueue jobs, or call external APIs.

## View Checks

#{V.md_table(checks, [{"Check", "check"}, {"Value", "value"}])}

## Scoreability Buckets

#{V.md_table(scoreability_buckets, [{"State", "state"}, {"Confidence", "confidence"}, {"Movies", "movies"}, {"Visible scores", "visible_scores"}])}

## Threshold Comparison

Phase 3 expected the 2+ lens visible count to be close to 550,797 on the restored production snapshot.
Differences are expected if the database snapshot or score cache changed.

#{V.md_table(thresholds, [{"Threshold", "threshold"}, {"Visible rows", "visible_rows"}, {"Visible %", "visible_pct"}])}

## Sample Rows

#{V.md_table(sample_rows, [{"Movie", "title"}, {"Year", "release_year"}, {"Raw score", "raw_cinegraph_score"}, {"Display score", "cinegraph_display_score"}, {"Lenses", "present_lens_count"}, {"State", "scoreability_state"}, {"Confidence", "score_confidence_label"}, {"Hidden reason", "score_hidden_reason"}])}

## Acceptance Checks

- 0-lens numeric display count must be `0`.
- 1-lens numeric display count must be `0`.
- 2+ lens numeric display count should be close to the Phase 3 production snapshot if the DB snapshot is unchanged.
- `scoreable` and `limited` rows may expose `cinegraph_display_score`.
- `insufficient_evidence` rows must not expose `cinegraph_display_score`.
"""

File.mkdir_p!(Path.dirname(report_path))
File.write!(report_path, report)

IO.puts("Phase 4 scoreability validation report written to #{report_path}")
