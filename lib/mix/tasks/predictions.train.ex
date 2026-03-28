defmodule Mix.Tasks.Predictions.Train do
  @moduledoc """
  Train optimal prediction weights for a movie list via logistic regression.

  Discovers weights from historical data (canonical_sources membership as labels,
  5 criteria scores as features) using Scholar.Linear.LogisticRegression,
  then validates via leave-one-decade-out cross-validation.

  ## Usage

      mix predictions.train
      mix predictions.train --list-key "1001_movies"
      mix predictions.train --list-key "sight_sound_critics_2022"
      mix predictions.train --sample-ratio 5
      mix predictions.train --save
      mix predictions.train --json

  ## Options

    * `--list-key` - source_key of the movie list to train on (default: "1001_movies")
    * `--sample-ratio` - negatives-to-positives ratio for undersampling (default: 5)
    * `--save` - persist learned weights to movie_lists.trained_weights in DB
    * `--json` - output raw JSON

  """
  use Mix.Task

  @shortdoc "Train ML weights for a movie list via logistic regression"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          list_key: :string,
          sample_ratio: :integer,
          save: :boolean,
          json: :boolean
        ]
      )

    list_key = Keyword.get(opts, :list_key, "1001_movies")
    sample_ratio = Keyword.get(opts, :sample_ratio, 5)
    save? = Keyword.get(opts, :save, false)
    json? = Keyword.get(opts, :json, false)

    unless json? do
      Mix.shell().info("""

      ═══════════════════════════════════
      TRAINING — #{list_key}
      ═══════════════════════════════════
      """)

      Mix.shell().info("Building feature matrix (sample ratio #{sample_ratio}:1)...")
    end

    result =
      Cinegraph.Predictions.WeightOptimizer.train(list_key,
        sample_ratio: sample_ratio,
        save: save?
      )

    if json? do
      output = %{
        "task" => "predictions.train",
        "list_key" => list_key,
        "weights" => Map.new(result.weights, fn {k, v} -> {Atom.to_string(k), v} end),
        "baseline_accuracy" => result.baseline_accuracy,
        "trained_accuracy" => result.trained_accuracy,
        "n_positives" => result.n_positives,
        "n_negatives" => result.n_negatives,
        "cv_by_decade" =>
          Enum.map(result.cv_by_decade, fn %{decade: d, accuracy: a} ->
            %{"decade" => d, "accuracy" => a}
          end),
        "feature_importance" =>
          Enum.map(result.feature_importance, fn {k, v} ->
            %{"criterion" => Atom.to_string(k), "weight" => v}
          end)
      }

      IO.puts(Jason.encode!(output, pretty: true))
    else
      print_results(result, save?)
    end
  end

  defp print_results(result, saved?) do
    Mix.shell().info("""
    Learned Weights:
    """)

    result.feature_importance
    |> Enum.each(fn {criterion, weight} ->
      pct = Float.round(weight * 100, 1)
      bar = build_bar(weight, 20)
      label = criterion |> Atom.to_string() |> String.pad_trailing(22)
      pct_str = String.pad_leading("#{pct}%", 6)
      Mix.shell().info("  #{label} #{pct_str}  #{bar}")
    end)

    diff = Float.round(result.trained_accuracy - result.baseline_accuracy, 1)
    diff_str = if diff >= 0, do: "+#{diff}pp", else: "#{diff}pp"

    Mix.shell().info("""

    Cross-validation (leave-one-decade-out):
      Overall: #{result.trained_accuracy}%  vs baseline #{result.baseline_accuracy}%  (#{diff_str})
    """)

    result.cv_by_decade
    |> Enum.sort_by(& &1.decade)
    |> Enum.each(fn %{decade: decade, accuracy: acc} ->
      Mix.shell().info("  #{decade}s:  #{acc}%")
    end)

    Mix.shell().info("")

    if saved? do
      Mix.shell().info("Weights saved to DB.")
    else
      Mix.shell().info("Run with --save to persist weights to database.")
    end
  end

  defp build_bar(value, width) do
    filled = round(value * width)
    empty = width - filled
    String.duplicate("█", filled) <> String.duplicate("░", empty)
  end
end
