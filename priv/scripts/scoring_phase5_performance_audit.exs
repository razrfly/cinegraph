# Phase 5 CineGraph scoreability performance audit.
#
# Run with:
#   mix run priv/scripts/scoring_phase5_performance_audit.exs
#
# This script is read-only against the database. It captures the query plans
# that matter for Phase 5 scoreability performance work and writes a markdown
# report for the issue trail.

:inets.start()

report_path = "docs/scoring/reports/scoring_phase5_performance_2026_05_02.md"
timestamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

lens_count_sql = """
(
  (COALESCE(sc.mob_score, 0) > 0)::int +
  (COALESCE(sc.critics_score, 0) > 0)::int +
  (COALESCE(sc.festival_recognition_score, 0) > 0)::int +
  (COALESCE(sc.time_machine_score, 0) > 0)::int +
  (COALESCE(sc.auteurs_score, 0) > 0)::int +
  (COALESCE(sc.box_office_score, 0) > 0)::int
)
"""

sort_score_sql = "sc.overall_score * (#{lens_count_sql}::float / 6.0)"

queries = [
  %{
    name: "generic_left_join_scoreability_sort_page_1",
    sql: """
    SELECT m.id, m.title,
      CASE WHEN #{lens_count_sql} >= 2 THEN #{sort_score_sql} ELSE NULL END AS cinegraph_sort_score
    FROM movies m
    LEFT JOIN movie_score_caches sc ON sc.movie_id = m.id
    WHERE m.import_status = 'full'
      AND (m.release_date IS NULL OR m.release_date <= CURRENT_DATE)
    ORDER BY
      CASE WHEN sc.id IS NOT NULL AND #{lens_count_sql} >= 2 THEN 0 ELSE 1 END ASC,
      CASE WHEN #{lens_count_sql} >= 2 THEN #{sort_score_sql} ELSE NULL END DESC NULLS LAST,
      m.release_date DESC NULLS LAST,
      m.id ASC
    LIMIT 24
    """
  },
  %{
    name: "score_cache_first_scoreability_sort_page_1",
    sql: """
    SELECT m.id, m.title, #{sort_score_sql} AS cinegraph_sort_score
    FROM movie_score_caches sc
    JOIN movies m ON m.id = sc.movie_id
    WHERE m.import_status = 'full'
      AND (m.release_date IS NULL OR m.release_date <= CURRENT_DATE)
      AND sc.overall_score IS NOT NULL
      AND #{lens_count_sql} >= 2
    ORDER BY #{sort_score_sql} DESC NULLS LAST, m.release_date DESC NULLS LAST, m.id ASC
    LIMIT 24
    """
  },
  %{
    name: "score_cache_first_scoreability_sort_page_10",
    sql: """
    SELECT m.id, m.title, #{sort_score_sql} AS cinegraph_sort_score
    FROM movie_score_caches sc
    JOIN movies m ON m.id = sc.movie_id
    WHERE m.import_status = 'full'
      AND (m.release_date IS NULL OR m.release_date <= CURRENT_DATE)
      AND sc.overall_score IS NOT NULL
      AND #{lens_count_sql} >= 2
    ORDER BY #{sort_score_sql} DESC NULLS LAST, m.release_date DESC NULLS LAST, m.id ASC
    LIMIT 24 OFFSET 216
    """
  },
  %{
    name: "score_cache_first_scoreability_sort_page_size_48",
    sql: """
    SELECT m.id, m.title, #{sort_score_sql} AS cinegraph_sort_score
    FROM movie_score_caches sc
    JOIN movies m ON m.id = sc.movie_id
    WHERE m.import_status = 'full'
      AND (m.release_date IS NULL OR m.release_date <= CURRENT_DATE)
      AND sc.overall_score IS NOT NULL
      AND #{lens_count_sql} >= 2
    ORDER BY #{sort_score_sql} DESC NULLS LAST, m.release_date DESC NULLS LAST, m.id ASC
    LIMIT 48
    """
  },
  %{
    name: "scoreability_view_display_lookup_page_1",
    sql: """
    SELECT m.id, m.title, sv.cinegraph_display_score, sv.scoreability_state
    FROM movies m
    LEFT JOIN movie_scoreability_view sv ON sv.movie_id = m.id
    WHERE m.import_status = 'full'
      AND (m.release_date IS NULL OR m.release_date <= CURRENT_DATE)
    ORDER BY m.release_date DESC NULLS LAST, m.id ASC
    LIMIT 24
    """
  },
  %{
    name: "representative_filtered_generic_score_sort",
    sql: """
    SELECT m.id, m.title,
      CASE WHEN #{lens_count_sql} >= 2 THEN #{sort_score_sql} ELSE NULL END AS cinegraph_sort_score
    FROM movies m
    JOIN movie_genres mg ON mg.movie_id = m.id
    LEFT JOIN movie_score_caches sc ON sc.movie_id = m.id
    WHERE m.import_status = 'full'
      AND (m.release_date IS NULL OR m.release_date <= CURRENT_DATE)
    ORDER BY
      CASE WHEN sc.id IS NOT NULL AND #{lens_count_sql} >= 2 THEN 0 ELSE 1 END ASC,
      CASE WHEN #{lens_count_sql} >= 2 THEN #{sort_score_sql} ELSE NULL END DESC NULLS LAST,
      m.release_date DESC NULLS LAST,
      m.id ASC
    LIMIT 24
    """
  }
]

defmodule Phase5Audit do
  def explain(sql) do
    explained = "EXPLAIN (ANALYZE, BUFFERS) #{sql}"

    case Ecto.Adapters.SQL.query(Cinegraph.Repo, explained, [], timeout: :infinity) do
      {:ok, %{rows: rows}} ->
        lines = Enum.map(rows, fn [line] -> line end)

        %{
          execution_ms: extract_ms(lines, "Execution Time"),
          planning_ms: extract_ms(lines, "Planning Time"),
          temp_io?: Enum.any?(lines, &String.contains?(&1, "temp ")),
          plan: Enum.join(lines, "\n")
        }

      {:error, error} ->
        %{
          error: Exception.message(error),
          execution_ms: nil,
          planning_ms: nil,
          temp_io?: nil,
          plan: ""
        }
    end
  end

  def endpoint_timing(url) do
    started = System.monotonic_time(:millisecond)

    result =
      :httpc.request(
        :get,
        {String.to_charlist(url), []},
        [timeout: 15_000],
        body_format: :binary
      )

    total_ms = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, {{_, status, _}, _headers, _body}} -> %{status: status, total_ms: total_ms}
      {:error, reason} -> %{status: "error", total_ms: total_ms, error: inspect(reason)}
    end
  end

  def md_table(rows, columns) do
    header = "| " <> Enum.map_join(columns, " | ", &elem(&1, 0)) <> " |"
    sep = "| " <> Enum.map_join(columns, " | ", fn _ -> "---" end) <> " |"

    body =
      Enum.map(rows, fn row ->
        "| " <>
          Enum.map_join(columns, " | ", fn {_label, key} ->
            row |> Map.get(key) |> format_cell()
          end) <> " |"
      end)

    Enum.join([header, sep | body], "\n")
  end

  defp extract_ms(lines, label) do
    lines
    |> Enum.find_value(fn line ->
      case Regex.run(~r/#{Regex.escape(label)}: ([0-9.]+) ms/, line) do
        [_, value] -> value
        _ -> nil
      end
    end)
  end

  defp format_cell(nil), do: ""
  defp format_cell(true), do: "yes"
  defp format_cell(false), do: "no"
  defp format_cell(value), do: to_string(value) |> String.replace("\n", "<br>")
end

query_results =
  Enum.map(queries, fn query ->
    result = Phase5Audit.explain(query.sql)

    Map.merge(result, %{
      name: query.name,
      execution_ms: result.execution_ms || "error",
      planning_ms: result.planning_ms || "",
      temp_io: result.temp_io?
    })
  end)

endpoint_urls = [
  "http://localhost:4001/movies?sort=score_desc",
  "http://localhost:4001/movies?sort=score_desc&page=10",
  "http://localhost:4001/movies?sort=score_desc&per_page=48"
]

endpoint_results =
  endpoint_urls
  |> Enum.flat_map(fn url ->
    for run <- 1..3 do
      %{url: url, run: run}
      |> Map.merge(Phase5Audit.endpoint_timing(url))
    end
  end)

report = """
# Phase 5 CineGraph Scoreability Performance Audit

Generated at: #{timestamp}

This report captures read-only query plans and local endpoint timings for Phase 5
scoreability performance hardening. The product behavior remains Phase 4:
numeric scores are public only for movies with 2+ present lenses.

## Query Plan Summary

#{Phase5Audit.md_table(query_results, [{"Query", :name}, {"Execution ms", :execution_ms}, {"Planning ms", :planning_ms}, {"Temp I/O", :temp_io}])}

## Endpoint Timing

These timings require a local Phoenix server on `localhost:4001`. If the server is
not running, the rows are marked as errors.

#{Phase5Audit.md_table(endpoint_results, [{"URL", :url}, {"Run", :run}, {"Status", :status}, {"Total ms", :total_ms}, {"Error", :error}])}

## Full Plans

#{Enum.map_join(query_results, "\n\n", fn result -> "### #{result.name}\n\n```text\n#{result.plan}\n```" end)}

## Recommendation

Prefer a score-cache-first fast path for plain CineGraph score sorts and keep
`movie_scoreability_view` as the display/API contract. If endpoint timings stay
above the Phase 5 threshold after the expression index and fast path, move
materialized-view/cache work into a separate follow-up.
"""

File.mkdir_p!(Path.dirname(report_path))
File.write!(report_path, report)

IO.puts("Phase 5 performance audit report written to #{report_path}")
