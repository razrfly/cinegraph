defmodule Mix.Tasks.Calibrate do
  @moduledoc """
  Runs the 1001 Movies recall calibration and prints results to stdout.

  ## Usage

      mix calibrate
      mix calibrate --profile "Critics Choice"
      mix calibrate --list "1001-movies" --threshold 0.20
      mix calibrate --json

  ## Options

    * `--profile` - scoring profile name (default: "Cinegraph Editorial")
    * `--list` - reference list slug (default: "1001-movies")
    * `--threshold` - top-N% threshold as decimal (default: 0.25 = top 25%)
    * `--json` - output raw JSON instead of formatted table

  """
  use Mix.Task

  @shortdoc "Run 1001 Movies recall calibration"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          profile: :string,
          list: :string,
          threshold: :float,
          json: :boolean
        ]
      )

    list_slug = Keyword.get(opts, :list, "1001-movies")
    profile_name = Keyword.get(opts, :profile, "Cinegraph Editorial")
    threshold = Keyword.get(opts, :threshold, 0.25)
    json? = Keyword.get(opts, :json, false)

    Mix.shell().info("""
    Running recall calibration…
      List:      #{list_slug}
      Profile:   #{profile_name}
      Threshold: top #{round(threshold * 100)}%
    """)

    case Cinegraph.Calibration.measure_recall(list_slug, profile_name, threshold: threshold) do
      {:error, :list_not_found} ->
        Mix.shell().error("Error: reference list '#{list_slug}' not found in DB.")
        Mix.shell().error("Run: mix import_canonical --list 1001-movies")
        exit({:shutdown, 1})

      {:error, :no_matched_references} ->
        Mix.shell().error("Error: no matched references found for list '#{list_slug}'.")
        Mix.shell().error("Ensure movies are imported and the reference list is populated.")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Error: #{inspect(reason)}")
        exit({:shutdown, 1})

      results ->
        if json? do
          # `by_decade` has integer keys; stringify them so Jason can encode the map
          results_for_json =
            Map.update!(results, :by_decade, fn by_decade ->
              Map.new(by_decade, fn {k, v} -> {to_string(k), v} end)
            end)

          IO.puts(Jason.encode!(results_for_json, pretty: true))
        else
          print_results(results, profile_name, threshold)
        end
    end
  end

  defp print_results(results, profile_name, threshold) do
    overall_pct = Float.round(results.overall_recall * 100, 1)
    status = recall_status(results.overall_recall)

    Mix.shell().info("""

    ═══════════════════════════════════════════════════
    RECALL RESULTS — #{profile_name}  (top #{round(threshold * 100)}%)
    ═══════════════════════════════════════════════════
    Overall Recall: #{overall_pct}%  #{status}
    Films surfaced: #{results.total_found} / #{results.total_reference}

    """)

    # Per-decade
    Mix.shell().info("Per-Decade Breakdown:")
    Mix.shell().info(String.duplicate("-", 51))

    results.by_decade
    |> Enum.sort_by(fn {decade, _} -> decade end)
    |> Enum.each(fn {_, r} ->
      pct = Float.round(r.recall * 100, 1)
      bar = build_bar(r.recall, 20)
      flag = if r.recall < 0.60, do: " ⚠", else: if(r.recall >= 0.75, do: " ✓", else: "")

      Mix.shell().info(
        "  #{String.pad_leading(r.decade_label, 6)}  #{bar}  #{String.pad_leading("#{pct}%", 6)}  (#{r.found}/#{r.total})#{flag}"
      )
    end)

    # Lens correlations
    if results.lens_correlations != [] do
      Mix.shell().info("\nLens Scores (mean across reference films):")
      Mix.shell().info(String.duplicate("-", 51))

      results.lens_correlations
      |> Enum.each(fn corr ->
        pct = Float.round(corr.mean_score * 100, 1)
        bar = build_bar(corr.mean_score, 20)
        Mix.shell().info("  #{String.pad_trailing(corr.label, 24)}  #{bar}  #{pct}%")
      end)
    end

    # Systematic gaps
    if results.systematic_gaps != [] do
      Mix.shell().info("\nSystematic Gaps:")
      Mix.shell().info(String.duplicate("-", 51))

      results.systematic_gaps
      |> Enum.each(fn gap ->
        Mix.shell().info("  [#{gap.category}] #{gap.description}")
      end)
    end

    Mix.shell().info("")

    target_met = results.overall_recall >= 0.75

    decade_floor_met =
      Enum.all?(results.by_decade, fn {_, r} -> r.total == 0 or r.recall >= 0.60 end)

    Mix.shell().info("Targets:")

    Mix.shell().info(
      "  Overall ≥ 75%:           #{if target_met, do: "✅ PASS (#{overall_pct}%)", else: "❌ FAIL (#{overall_pct}%)"}"
    )

    Mix.shell().info(
      "  All decades ≥ 60%:       #{if decade_floor_met, do: "✅ PASS", else: "❌ FAIL — see ⚠ decades above"}"
    )

    Mix.shell().info("")
  end

  defp build_bar(value, width) do
    filled = round(value * width)
    empty = width - filled
    "[" <> String.duplicate("█", filled) <> String.duplicate("░", empty) <> "]"
  end

  defp recall_status(recall) when recall >= 0.75, do: "✅ TARGET MET"
  defp recall_status(recall) when recall >= 0.60, do: "⚠  BELOW TARGET"
  defp recall_status(_), do: "❌ FAR BELOW TARGET"
end
