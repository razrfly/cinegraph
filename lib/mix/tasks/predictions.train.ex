defmodule Mix.Tasks.Predictions.Train do
  @moduledoc """
  Train + promote ONE list's prediction model under the Prediction Integrity Protocol (#1036).

  Pre-registers a hypothesis, trains on all-but-the-latest decade, scores the **sacred holdout**
  (latest decade) exactly once through the Layer-2 bus, calibrates, and reports recall@K /
  precision@K / Brier / baselines with an honest pass/fail. (The old profile-based "accuracy vs
  70%" path was retired in #1051 — use `mix predictions.experiment` for holdout-free iteration and
  `mix predictions.seed_flagships` to (re)promote the whole fleet.)

  ## Usage
      mix predictions.train --list-key 1001_movies                       # data-point, dry-run
      mix predictions.train --list-key 1001_movies --granularity lens
      mix predictions.train --list-key cult_movies_400 --strategy static --save --threshold 0.25

  ## Options
    * `--list-key`    - source_key of the movie list (default 1001_movies)
    * `--save`        - persist the artifact + set it active (spends the sacred holdout once)
    * `--granularity` - data_point (default) | lens
    * `--strategy`    - temporal (default) | static  (recorded on the model)
    * `--threshold`   - pre-registered min holdout recall@K (default 0.20)
    * `--json`        - raw JSON output
  """
  use Mix.Task

  alias Cinegraph.Predictions.{PreRegistration, Trainer}

  @shortdoc "Train + promote one list's model under the integrity protocol (#1036)"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          list_key: :string,
          save: :boolean,
          json: :boolean,
          granularity: :string,
          strategy: :string,
          threshold: :float
        ]
      )

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
            expected_top_features: %{"note" => "auto-registered by mix predictions.train"},
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
    recall@K        : #{ifmt(i["recall_at_k"])}  (objective #{ifmt(i["objective_recall_at_k"])})
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
    do: "static member-holdout #{ifmt(i["holdout_fraction"])} (seed #{i["seed"]})"

  defp eval_label(i), do: "temporal holdout #{inspect(i["holdout_decades"])}"

  defp ifmt(nil), do: "—"
  defp ifmt(n) when is_float(n), do: n |> Float.round(4) |> to_string()
  defp ifmt(n), do: to_string(n)
end
