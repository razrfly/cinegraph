defmodule Mix.Tasks.Predictions.Sweep do
  @moduledoc """
  Random weight sweep: loads decade data once, then evaluates thousands of
  weight combinations in memory to find the highest-accuracy weighting for a
  given movie list.

  Because all scoring happens in memory after the initial data load, thousands
  of weight vectors can be evaluated in seconds.

  ## Usage

      mix predictions.sweep
      mix predictions.sweep --n-samples 2000
      mix predictions.sweep --list-key "1001_movies" --save
      mix predictions.sweep --json

  ## Options

    * `--list-key`   - source_key of the target list (default: "1001_movies")
    * `--n-samples`  - number of random weight vectors to evaluate (default: 500)
    * `--top`        - number of top results to display (default: 20)
    * `--save`       - persist the best weights to movie_lists.trained_weights
    * `--json`       - output raw JSON

  """
  use Mix.Task

  @shortdoc "Sweep random weight combinations to find the best prediction weights"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          list_key: :string,
          n_samples: :integer,
          top: :integer,
          save: :boolean,
          json: :boolean
        ]
      )

    list_key = Keyword.get(opts, :list_key, "1001_movies")
    n_samples = Keyword.get(opts, :n_samples, 500)
    top = Keyword.get(opts, :top, 20)
    save? = Keyword.get(opts, :save, false)
    json? = Keyword.get(opts, :json, false)

    unless json? do
      Mix.shell().info("""

      ═══════════════════════════════════════════
      WEIGHT SWEEP — #{list_key}
      #{n_samples} random samples + named profiles
      ═══════════════════════════════════════════
      Loading decade data...
      """)
    end

    results =
      try do
        Cinegraph.Predictions.WeightOptimizer.sweep(list_key, n_samples,
          save: save?,
          top: top
        )
      rescue
        e ->
          Mix.shell().error("Sweep failed: #{Exception.message(e)}")
          exit({:shutdown, 1})
      end

    if json? do
      output = %{
        "task" => "predictions.sweep",
        "list_key" => list_key,
        "n_samples" => n_samples,
        "results" =>
          Enum.map(results, fn r ->
            %{
              "rank" => r.rank,
              "accuracy" => r.accuracy,
              "label" => r.label,
              "weights" => Map.new(r.weights, fn {k, v} -> {Atom.to_string(k), v} end)
            }
          end)
      }

      IO.puts(Jason.encode!(output, pretty: true))
    else
      print_results(results, save?, list_key)
    end
  end

  defp print_results(results, saved?, list_key) do
    criteria = Cinegraph.Predictions.CriteriaScoring.scoring_criteria()

    Mix.shell().info(
      "  Rank  Accuracy  " <>
        (criteria |> Enum.map(&(String.pad_trailing(short_name(&1), 8))) |> Enum.join("  ")) <>
        "  Label"
    )

    Mix.shell().info("  " <> String.duplicate("-", 80))

    Enum.each(results, fn r ->
      rank_str = String.pad_leading("#{r.rank}", 4)
      acc_str = String.pad_leading("#{r.accuracy}%", 8)

      weight_cols =
        criteria
        |> Enum.map(fn c ->
          pct = Float.round(Map.get(r.weights, c, 0.0) * 100, 1)
          String.pad_leading("#{pct}%", 8)
        end)
        |> Enum.join("  ")

      label = if r.label, do: "  ← #{r.label}", else: ""
      Mix.shell().info("  #{rank_str}  #{acc_str}  #{weight_cols}#{label}")
    end)

    best = hd(results)

    Mix.shell().info("""

    Best: #{best.accuracy}% accuracy
    #{format_weights(best.weights)}
    """)

    if saved? do
      Mix.shell().info("Best weights saved to DB for #{list_key}.")
    else
      Mix.shell().info("Run with --save to persist best weights.")
    end
  end

  defp format_weights(weights) do
    weights
    |> Enum.sort_by(fn {_, v} -> v end, :desc)
    |> Enum.map(fn {k, v} ->
      pct = Float.round(v * 100, 1)
      bar = String.duplicate("█", round(v * 30))
      "  #{String.pad_trailing(Atom.to_string(k), 22)} #{String.pad_leading("#{pct}%", 6)}  #{bar}"
    end)
    |> Enum.join("\n")
  end

  defp short_name(:mob), do: "mob"
  defp short_name(:critics), do: "critics"
  defp short_name(:festival_recognition), do: "festival"
  defp short_name(:cultural_impact), do: "cultural"
  defp short_name(:auteur_recognition), do: "auteur"
  defp short_name(k), do: Atom.to_string(k)
end
