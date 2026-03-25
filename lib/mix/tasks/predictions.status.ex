defmodule Mix.Tasks.Predictions.Status do
  @moduledoc """
  Quick status snapshot: current accuracy vs. target and data coverage for 1001 Movies.

  ## Usage

      mix predictions.status
      mix predictions.status --profile "Critics Choice"
      mix predictions.status --json
      mix predictions.status --threshold 80.0

  ## Options

    * `--profile` - CriteriaScoring weight profile name (default: "default")
      Available: "default", "festival-heavy", "audience-first", "critics-choice", "auteur"
    * `--json` - output raw JSON instead of formatted table
    * `--threshold` - accuracy target percentage (default: 70.0)

  ## Exit codes

    * 0 - overall accuracy meets threshold
    * 1 - overall accuracy below threshold

  """
  use Mix.Task

  @shortdoc "Quick predictions accuracy + coverage snapshot"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          profile: :string,
          json: :boolean,
          threshold: :float
        ]
      )

    profile_name = Keyword.get(opts, :profile, "default")
    json? = Keyword.get(opts, :json, false)
    threshold = Keyword.get(opts, :threshold, 70.0)

    unless json? do
      Mix.shell().info("Running predictions status check...")
    end

    validation = Cinegraph.Predictions.HistoricalValidator.validate_all_decades(profile_name)
    coverage = fetch_coverage()

    if json? do
      output = %{
        "task" => "predictions.status",
        "timestamp" => format_timestamp(),
        "profile" => profile_name,
        "overall_accuracy" => validation.overall_accuracy,
        "target_threshold" => threshold,
        "target_met" => validation.overall_accuracy >= threshold,
        "coverage" => %{
          "total" => coverage.total,
          "has_imdb_pct" => coverage.has_imdb_pct,
          "has_rt_pct" => coverage.has_rt_pct,
          "has_metacritic_pct" => coverage.has_metacritic_pct,
          "has_festivals_pct" => coverage.has_festivals_pct
        },
        "decade_results" =>
          Enum.map(validation.decade_results, fn r ->
            %{
              "decade" => r.decade,
              "label" => "#{r.decade}s",
              "accuracy_percentage" => r.accuracy_percentage,
              "correctly_predicted" => r.correctly_predicted,
              "total_1001_movies" => r.total_1001_movies
            }
          end)
      }

      IO.puts(Jason.encode!(output, pretty: true))
    else
      print_status(validation, coverage, profile_name, threshold)
    end

    if validation.overall_accuracy < threshold do
      exit({:shutdown, 1})
    end
  end

  defp fetch_coverage do
    sql = """
    SELECT
      COUNT(DISTINCT m.id)                                                               AS total_movies,
      COUNT(DISTINCT CASE WHEN ei.id IS NOT NULL THEN m.id END)                         AS has_imdb,
      COUNT(DISTINCT CASE WHEN er.id IS NOT NULL THEN m.id END)                         AS has_rt,
      COUNT(DISTINCT CASE WHEN em.id IS NOT NULL THEN m.id END)                         AS has_metacritic,
      COUNT(DISTINCT CASE WHEN fn.id IS NOT NULL THEN m.id END)                         AS has_festivals
    FROM movies m
    LEFT JOIN external_metrics ei  ON ei.movie_id  = m.id AND ei.source  = 'imdb'            AND ei.metric_type = 'rating_average'
    LEFT JOIN external_metrics er  ON er.movie_id  = m.id AND er.source  = 'rotten_tomatoes'  AND er.metric_type = 'tomatometer'
    LEFT JOIN external_metrics em  ON em.movie_id  = m.id AND em.source  = 'metacritic'       AND em.metric_type = 'metascore'
    LEFT JOIN festival_nominations fn ON fn.movie_id = m.id
    WHERE (m.canonical_sources ? '1001_movies')
    """

    %{rows: [[total, has_imdb, has_rt, has_meta, has_festivals]]} =
      Cinegraph.Repo.query!(sql, [])

    %{
      total: total || 0,
      has_imdb_pct: pct(has_imdb, total),
      has_rt_pct: pct(has_rt, total),
      has_metacritic_pct: pct(has_meta, total),
      has_festivals_pct: pct(has_festivals, total)
    }
  end

  defp print_status(validation, coverage, profile_name, threshold) do
    overall = validation.overall_accuracy
    icon = status_icon(overall, threshold)

    Mix.shell().info("""

    ═══════════════════════════════════════════════
    PREDICTIONS STATUS — #{profile_name}
    ═══════════════════════════════════════════════
    Overall Accuracy: #{overall}%  #{icon} #{if overall >= threshold, do: "TARGET MET (#{threshold}%)", else: "BELOW TARGET (#{threshold}%)"}

    Per-Decade:
    """)

    validation.decade_results
    |> Enum.sort_by(& &1.decade)
    |> Enum.each(fn r ->
      bar = build_bar(r.accuracy_percentage / 100, 20)
      label = String.pad_trailing("#{r.decade}s", 6)
      pct_str = String.pad_leading("#{r.accuracy_percentage}%", 6)
      Mix.shell().info("  #{label}  #{pct_str}  #{bar}")
    end)

    Mix.shell().info("""

    Data Coverage (1001 Movies):
      Total confirmed:    #{coverage.total}
      Has IMDb rating:    #{coverage.has_imdb_pct}%
      Has RT tomatometer: #{coverage.has_rt_pct}%
      Has Metacritic:     #{coverage.has_metacritic_pct}%
      Has festival data:  #{coverage.has_festivals_pct}%
    """)
  end

  defp build_bar(value, width) do
    filled = round(value * width)
    empty = width - filled
    "[" <> String.duplicate("█", filled) <> String.duplicate("░", empty) <> "]"
  end

  defp pct(count, total) when is_integer(total) and total > 0,
    do: Float.round(count / total * 100, 1)

  defp pct(_, _), do: 0.0

  defp format_timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp status_icon(value, threshold) when value >= threshold, do: "✅"
  defp status_icon(value, _) when value >= 60, do: "⚠"
  defp status_icon(_, _), do: "❌"
end
