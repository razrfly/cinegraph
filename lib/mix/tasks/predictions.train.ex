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

  ## Integrity-protocol mode (#1036 Session 3)

  With `--integrity`, training runs under the Prediction Integrity Protocol via
  `Cinegraph.Predictions.Trainer`: it pre-registers a hypothesis, trains on all-but-the-latest
  decade, scores the **sacred holdout** (latest decade) exactly once through the Layer-2 bus,
  calibrates, and reports recall@K / precision@K / Brier / baselines with an honest pass/fail.

      mix predictions.train --integrity --list-key 1001_movies                  # data-point, dry-run
      mix predictions.train --integrity --list-key 1001_movies --granularity lens
      mix predictions.train --integrity --list-key cult_movies_400 --save --threshold 0.25

    * `--integrity`   - use the integrity protocol + bus (else the legacy 6-lens path)
    * `--granularity` - data_point (default) | lens
    * `--strategy`    - temporal (default) | static  (recorded on the model)
    * `--threshold`   - pre-registered min holdout recall@K (default 0.20)
  """
  use Mix.Task

  alias Cinegraph.Predictions.{PreRegistration, Trainer}

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
          json: :boolean,
          integrity: :boolean,
          granularity: :string,
          strategy: :string,
          threshold: :float
        ]
      )

    if opts[:integrity] do
      run_integrity(opts)
    else
      run_legacy(opts)
    end
  end

  # ── integrity protocol (#1036 Session 3) ─────────────────────────────────────

  defp run_integrity(opts) do
    list = Keyword.get(opts, :list_key, "1001_movies")
    granularity = parse_granularity(Keyword.get(opts, :granularity, "data_point"))
    strategy = parse_strategy(Keyword.get(opts, :strategy, "temporal"))
    threshold = Keyword.get(opts, :threshold, 0.20)
    save? = Keyword.get(opts, :save, false)

    prereg =
      if save? do
        {:ok, p} =
          PreRegistration.register(%{
            source_key: list,
            expected_top_features: %{
              "note" => "auto-registered by mix predictions.train --integrity"
            },
            expected_accuracy_range: %{"min" => threshold, "max" => 1.0},
            failure_threshold: :erlang.float_to_binary(threshold, decimals: 2)
          })

        p
      end

    Mix.shell().info(
      "Integrity training #{granularity} for #{list} (strategy=#{strategy}, save=#{save?})…"
    )

    case Trainer.train(list,
           granularity: granularity,
           save: save?,
           prereg: prereg,
           backtest_strategy: strategy
         ) do
      {:ok, summary} -> print_integrity(summary, Keyword.get(opts, :json, false))
      {:error, reason} -> Mix.raise("Integrity training failed: #{inspect(reason)}")
    end
  end

  defp print_integrity(summary, true) do
    IO.puts(
      Jason.encode!(Map.take(summary, [:integrity_report, :calibration, :verdict]), pretty: true)
    )
  end

  defp print_integrity(summary, _) do
    i = summary.integrity_report
    v = summary.verdict
    b = i["baselines"]

    top =
      summary.weights
      |> Enum.sort_by(fn {_k, w} -> w end, :desc)
      |> Enum.take(5)
      |> Enum.map_join(", ", fn {k, w} -> "#{k}=#{Float.round(w, 3)}" end)

    Mix.shell().info("""

    ── #{summary.source_key} (#{summary.granularity}) ──────────────────────────
    evaluation      : #{eval_label(i)}  (n=#{i["n_evaluated"]}, positives=#{i["n_positives"]})
    recall@K        : #{ifmt(i["recall_at_k"])}
    precision@K     : #{ifmt(i["precision_at_k"])}
    Brier           : #{ifmt(i["brier"])}
    baselines       : popularity #{ifmt(b["popularity"])} · random #{ifmt(b["random"])} · prior #{ifmt(b["prior_rate"])}
    calibration     : #{summary.calibration["method"]}
    top features    : #{top}
    VERDICT         : #{verdict_line(v)}
    """)

    if summary[:model_id],
      do: Mix.shell().info("persisted model id=#{summary.model_id} (holdout spent)")
  end

  defp verdict_line(%{"passed" => true} = v),
    do:
      "PASS — recall@K #{ifmt(v["recall_at_k"])} ≥ threshold #{ifmt(v["failure_threshold"])}, beats popularity #{ifmt(v["popularity_baseline"])}"

  defp verdict_line(%{"passed" => false} = v),
    do:
      "FAIL — recall@K #{ifmt(v["recall_at_k"])} (beats_popularity=#{v["beats_popularity"]}, clears_threshold=#{v["clears_failure_threshold"]})"

  defp parse_granularity(g) when g in ~w(data_point lens), do: String.to_atom(g)

  defp parse_granularity(g),
    do: Mix.raise("invalid --granularity #{inspect(g)} (expected data_point | lens)")

  defp parse_strategy(s) when s in ~w(temporal static), do: s

  defp parse_strategy(s),
    do: Mix.raise("invalid --strategy #{inspect(s)} (expected temporal | static)")

  defp eval_label(%{"backtest_strategy" => "static"} = i),
    do: "static #{i["k_folds"]}-fold (seed #{i["seed"]})"

  defp eval_label(i), do: "temporal holdout #{inspect(i["holdout_decades"])}"

  defp ifmt(nil), do: "—"
  defp ifmt(n) when is_float(n), do: n |> Float.round(4) |> to_string()
  defp ifmt(n), do: to_string(n)

  # ── legacy 6-lens path ───────────────────────────────────────────────────────

  defp run_legacy(opts) do
    list_key = Keyword.get(opts, :list_key, "1001_movies")
    sample_ratio = Keyword.get(opts, :sample_ratio, 5)
    json? = Keyword.get(opts, :json, false)

    if Keyword.get(opts, :save, false) do
      Mix.shell().info(
        "NOTE: legacy mode is analysis-only and no longer persists. To train + save an active " <>
          "model, use: mix predictions.train --integrity --list-key #{list_key} --save"
      )
    end

    unless json? do
      Mix.shell().info("""

      ═══════════════════════════════════
      TRAINING (analysis-only) — #{list_key}
      ═══════════════════════════════════
      """)

      Mix.shell().info("Building feature matrix (sample ratio #{sample_ratio}:1)...")
    end

    result =
      try do
        Cinegraph.Predictions.WeightOptimizer.train(list_key, sample_ratio: sample_ratio)
      rescue
        e ->
          Mix.shell().error("Training failed: #{Exception.message(e)}")
          exit({:shutdown, 1})
      end

    if json? do
      timings = Map.get(result, :timings, %{})

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
          end),
        "timings" => %{
          "data_load_ms" => Map.get(timings, :data_load_ms),
          "model_fit_ms" => Map.get(timings, :model_fit_ms),
          "loocv_ms" => Map.get(timings, :loocv_ms),
          "baseline_cv_ms" => Map.get(timings, :baseline_cv_ms)
        }
      }

      IO.puts(Jason.encode!(output, pretty: true))
    else
      print_results(result)
    end
  end

  defp print_results(result) do
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
    Mix.shell().info("Analysis only. To persist an active model: add --integrity --save.")

    case Map.get(result, :timings) do
      nil ->
        :ok

      t ->
        total_ms =
          Map.values(t) |> Enum.sum()

        total_s = Float.round(total_ms / 1000, 1)

        Mix.shell().info("""

        ⏱  Timing Breakdown:
           Data load (parallel):  #{t.data_load_ms}ms
           Model fit (EXLA):      #{t.model_fit_ms}ms
           LOOCV (parallel):      #{t.loocv_ms}ms
           Baseline CV:           #{t.baseline_cv_ms}ms
           ──────────────────────────────
           Total:                 #{total_s}s
        """)
    end
  end

  defp build_bar(value, width) do
    filled = round(value * width)
    empty = width - filled
    String.duplicate("█", filled) <> String.duplicate("░", empty)
  end
end
