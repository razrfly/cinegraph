defmodule Mix.Tasks.Predictions.Backtest do
  @moduledoc """
  Runs the prediction algorithm backtest against historical decades.

  Clears the in-memory cache before running so results reflect current DB state.

  ## Usage

      mix predictions.backtest
      mix predictions.backtest --all
      mix predictions.backtest --decade 1960
      mix predictions.backtest --profile "Critics Choice"
      mix predictions.backtest --json

  ## Options

    * `--all` - backtest all decades (default)
    * `--decade` - backtest a single decade (e.g. 1960 for 1960s)
    * `--profile` - CriteriaScoring weight profile name (default: "default")
      Available: "default", "festival-heavy", "audience-first", "critics-choice", "auteur"
    * `--json` - output raw JSON instead of formatted table
    * `--limit N` - (parsed but currently a no-op; pool cap removed in Phase 2)
    * `--threshold` - accuracy target percentage (default: 70.0)

  ## Exit codes

    * 0 - overall accuracy meets threshold
    * 1 - overall accuracy below threshold

  """
  use Mix.Task

  @shortdoc "Backtest prediction algorithm accuracy against historical decades"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          all: :boolean,
          decade: :integer,
          profile: :string,
          json: :boolean,
          limit: :integer,
          threshold: :float
        ]
      )

    decade_filter = Keyword.get(opts, :decade)
    profile_name = Keyword.get(opts, :profile, "default")
    json? = Keyword.get(opts, :json, false)
    limit = Keyword.get(opts, :limit)
    threshold = Keyword.get(opts, :threshold, 70.0)

    if limit && !json? do
      Mix.shell().info("Note: --limit is currently a no-op (pool cap was removed in Phase 2)")
    end

    unless json? do
      Mix.shell().info("Clearing prediction cache...")
    end

    Cinegraph.Cache.PredictionsCache.clear_all()

    unless json? do
      Mix.shell().info("Running backtest...")
    end

    {results, overall_accuracy} =
      if decade_filter do
        result =
          Cinegraph.Predictions.HistoricalValidator.validate_decade(decade_filter, profile_name)

        {[result], result.accuracy_percentage}
      else
        validation = Cinegraph.Predictions.HistoricalValidator.validate_all_decades(profile_name)
        {validation.decade_results, validation.overall_accuracy}
      end

    if json? do
      decade_range =
        if length(results) > 1 do
          min_d = results |> Enum.map(& &1.decade) |> Enum.min()
          max_d = results |> Enum.map(& &1.decade) |> Enum.max()
          "#{min_d}s-#{max_d}s"
        else
          "#{hd(results).decade}s"
        end

      output = %{
        "task" => "predictions.backtest",
        "timestamp" => format_timestamp(),
        "profile" => profile_name,
        "overall_accuracy" => overall_accuracy,
        "decades_analyzed" => length(results),
        "decade_range" => decade_range,
        "target_met" => overall_accuracy >= threshold,
        "target_threshold" => threshold,
        "decade_results" =>
          Enum.map(results, fn r ->
            %{
              "decade" => r.decade,
              "label" => "#{r.decade}s",
              "accuracy_percentage" => r.accuracy_percentage,
              "correctly_predicted" => r.correctly_predicted,
              "total_1001_movies" => r.total_1001_movies,
              "missed_count" => r.missed_count,
              "false_positive_count" => r.false_positive_count
            }
          end)
      }

      IO.puts(Jason.encode!(output, pretty: true))
    else
      print_backtest(results, overall_accuracy, profile_name, threshold)
    end

    if overall_accuracy < threshold do
      exit({:shutdown, 1})
    end
  end

  defp print_backtest(results, overall_accuracy, profile_name, threshold) do
    icon = status_icon(overall_accuracy, threshold)

    Mix.shell().info("""

    ═══════════════════════════════════════════════
    BACKTEST — #{profile_name}
    Scoring: CriteriaScoring (festival 40% · mob 17.5% · critics 17.5% · cultural 20% · auteur 5%)
    ═══════════════════════════════════════════════
    Overall Accuracy: #{overall_accuracy}%  #{icon} #{if overall_accuracy >= threshold, do: "TARGET MET", else: "BELOW TARGET"}

    Decade  Accuracy  Correct  Total   Progress
    #{String.duplicate("-", 60)}
    """)

    results
    |> Enum.sort_by(& &1.decade)
    |> Enum.each(fn r ->
      bar = build_bar(r.accuracy_percentage / 100, 20)
      label = String.pad_trailing("#{r.decade}s", 6)
      acc_str = String.pad_leading("#{r.accuracy_percentage}%", 7)
      correct_str = "#{r.correctly_predicted}/#{r.total_1001_movies}"
      Mix.shell().info("  #{label}  #{acc_str}  #{String.pad_leading(correct_str, 8)}  #{bar}")
    end)

    Mix.shell().info("")
  end

  defp build_bar(value, width) do
    filled = round(value * width)
    empty = width - filled
    "[" <> String.duplicate("█", filled) <> String.duplicate("░", empty) <> "]"
  end

  defp format_timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp status_icon(value, threshold) when value >= threshold, do: "✅"
  defp status_icon(value, _) when value >= 60, do: "⚠"
  defp status_icon(_, _), do: "❌"
end
