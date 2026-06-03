defmodule Mix.Tasks.Predictions.Experiment do
  @moduledoc """
  Run one **holdout-free** prediction experiment (#1040) — the iteration sandbox.

  Fits a model on the train decades and scores it on the **validation** tier, reporting smooth
  tuning metrics (PR-AUC, log-loss) alongside recall@K, plus per-feature coverage and importance.
  The sacred holdout (the latest decade) is **never** touched and no pre-registration is required,
  so you can compare feature/weight variants freely without burning the holdout. Graduating a
  validated winner to an active model is the separate `mix predictions.train` path.

      mix predictions.experiment --list 1001_movies
      mix predictions.experiment --list 1001_movies --features raw
      mix predictions.experiment --list 1001_movies --sweep                 # parallel variant grid
      mix predictions.experiment --list 1001_movies --sweep --concurrency 8
      mix predictions.experiment --list 1001_movies --json > runs/baseline.json

  Options:
    --list                source_key of the list (default 1001_movies)
    --granularity         data_point (default) or lens
    --features            all (default, raw+derived) | raw | derived  (data_point feature set)
    --sample-ratio        negative undersampling ratio (default 5)
    --seed                RNG seed for the undersample (default 1337 — deterministic comparison)
    --min-val-positives   pool validation decades until ≥ this many positives (default 30)
    --label               a human tag echoed back in the output (for your own bookkeeping)
    --sweep               run a grid of feature/ratio variants in parallel, ranked by PR-AUC
    --concurrency         parallel workers for --sweep (default 4)
    --json                machine-readable output (redirect to a file to keep a trail)
  """
  use Mix.Task

  alias Cinegraph.Predictions.Trainer

  @shortdoc "Run a holdout-free prediction experiment on the validation tier"

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          list: :string,
          granularity: :string,
          features: :string,
          sample_ratio: :integer,
          seed: :integer,
          min_val_positives: :integer,
          label: :string,
          sweep: :boolean,
          concurrency: :integer,
          json: :boolean
        ]
      )

    list = opts[:list] || "1001_movies"
    granularity = parse_granularity(opts[:granularity])

    run_opts =
      [granularity: granularity]
      |> maybe_put(:features, parse_features(opts[:features]))
      |> maybe_put(:sample_ratio, opts[:sample_ratio])
      |> maybe_put(:seed, opts[:seed])
      |> maybe_put(:min_val_positives, opts[:min_val_positives])

    if opts[:sweep], do: sweep(list, run_opts, opts), else: single(list, run_opts, opts)
  end

  # ── single experiment ────────────────────────────────────────────────────────────
  defp single(list, run_opts, opts) do
    case Trainer.run_experiment(list, run_opts) do
      {:ok, result} ->
        if opts[:json], do: print_json(result, opts[:label]), else: print(result, opts[:label])

      {:error, reason} ->
        Mix.raise("experiment failed for #{list}: #{inspect(reason)}")
    end
  end

  # ── parallel sweep over a variant grid (the Mac-Studio loop) ──────────────────────
  # Default grid: feature sets {raw, all, derived} at ratio 5, plus all-features at ratios 3 & 10.
  @grid [
    [features: :raw, sample_ratio: 5],
    [features: :all, sample_ratio: 5],
    [features: :derived, sample_ratio: 5],
    [features: :all, sample_ratio: 3],
    [features: :all, sample_ratio: 10]
  ]

  defp sweep(list, run_opts, opts) do
    conc = opts[:concurrency] || 4
    sweep_opts = Keyword.put(run_opts, :max_concurrency, conc)

    t0 = System.monotonic_time(:millisecond)
    ranked = Trainer.run_sweep(list, @grid, sweep_opts)
    secs = Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)

    if ranked == [], do: Mix.raise("sweep produced no results for #{list}")

    if opts[:json] do
      IO.puts(
        Jason.encode!(%{list: list, concurrency: conc, seconds: secs, ranked: ranked},
          pretty: true
        )
      )
    else
      print_sweep(list, ranked, conc, secs)
    end
  end

  defp print_sweep(list, ranked, conc, secs) do
    Mix.shell().info("""

    SWEEP — #{list} · #{length(@grid)} variants · #{conc} parallel workers · #{secs}s wall-clock
    ranked by validation PR-AUC (holdout untouched)

      #   FEATURES   RATIO  PR-AUC   log-loss  recall@K  calib    n_pos
    """)

    ranked
    |> Enum.with_index(1)
    |> Enum.each(fn {r, i} ->
      m = r.metrics
      win = if i == 1, do: " ◀ winner", else: ""

      Mix.shell().info(
        "  #{pad(i, 3)} #{pad(r.features, 10)} #{pad(r.sample_ratio, 6)} #{pad(fmt(m["pr_auc"]), 8)} " <>
          "#{pad(fmt(m["log_loss"]), 9)} #{pad(fmt(m["recall_at_k"]), 9)} #{pad(r.calibration, 8)} #{m["n_positives"]}#{win}"
      )
    end)

    Mix.shell().info("")
  end

  defp parse_features(nil), do: nil
  defp parse_features("all"), do: :all
  defp parse_features("raw"), do: :raw
  defp parse_features("derived"), do: :derived

  defp parse_features(f),
    do: Mix.raise("invalid --features #{inspect(f)} (expected all | raw | derived)")

  defp parse_granularity(nil), do: :data_point
  defp parse_granularity("data_point"), do: :data_point
  defp parse_granularity("lens"), do: :lens

  defp parse_granularity(g),
    do: Mix.raise("invalid --granularity #{inspect(g)} (expected data_point | lens)")

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, val), do: Keyword.put(kw, key, val)

  # ── human output ────────────────────────────────────────────────────────────────
  defp print(r, label) do
    m = r.metrics
    base = get_in(m, ["baselines", "popularity"])

    Mix.shell().info("""

    EXPERIMENT — #{r.source_key} · #{r.granularity} · features=#{r.features} ratio=#{r.sample_ratio}#{label_suffix(label)}
    train #{inspect(r.train_decades)} → validation #{inspect(r.validation_decades)}
    (holdout #{inspect(r.holdout_decades)} reserved, untouched)

      PR-AUC          #{fmt(m["pr_auc"])}        ← primary tuning metric (rank-based)
      log-loss        #{fmt(m["log_loss"])}        ← lower is better
      recall@K        #{fmt(m["recall_at_k"])}  (vs popularity #{fmt(base)})
      calibration     #{r.calibration}
      validation set  #{m["n_positives"]} positives / #{m["n_evaluated"]} scored
    """)

    print_features(r)
  end

  defp print_features(r) do
    Mix.shell().info("  feature · importance · coverage (top 12 by importance)")

    r.feature_importance
    |> Enum.sort_by(fn {_code, w} -> -w end)
    |> Enum.take(12)
    |> Enum.each(fn {code, w} ->
      cov = Map.get(r.feature_coverage, code)

      Mix.shell().info(
        "    #{pad(code, 30)} #{pad(fmt(w), 8)} #{if cov, do: "cov #{fmt(cov)}", else: ""}"
      )
    end)

    Mix.shell().info("")
  end

  # ── json ──────────────────────────────────────────────────────────────────────
  defp print_json(r, label) do
    IO.puts(Jason.encode!(Map.put(r, :label, label), pretty: true))
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────
  defp label_suffix(nil), do: ""
  defp label_suffix(label), do: " · #{label}"

  defp fmt(nil), do: "—"
  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 4)
  defp fmt(n), do: to_string(n)

  defp pad(v, n), do: v |> to_string() |> String.pad_trailing(n)
end
