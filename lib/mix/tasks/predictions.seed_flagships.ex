defmodule Mix.Tasks.Predictions.SeedFlagships do
  @moduledoc """
  Honest re-promotion of the canonical-list prediction models (#1051 Stage C).

  For each target list it evaluates **both** backtest strategies holdout-free
  (`Trainer.evaluate_strategy/3`), grades each with the pure `Reliability` scorer, and picks the
  higher-grading valid one. The honest full-pool metric (#1055) means the right strategy is no
  longer obvious per list — so we measure instead of hardcoding.

  The strategy PICK is **sampled by default** (`--sample 25000`): the exact full-member-decade pool
  is ≈ the whole catalog for broad static lists, so an exact pick across 10 lists is hours. Sampling
  preserves the relative temporal-vs-static ranking; projected grades read OPTIMISTIC (fewer
  competitors). The **committed** model's stored grade is always **exact** — `Trainer.train` never
  samples. Pass `--sample 0` to pick on the exact pool (slow).

  **Default is a dry-run that spends nothing** — it prints the standings (recommended strategy +
  projected grade). With `--commit` it registers a fresh pre-registration per list (honest
  `failure_threshold` = the popularity baseline) and runs `Trainer.train(save: true)` once on the
  recommended strategy — spending that list's sacred holdout a single time and pointing the list at
  the new model. Lists that grade `:insufficient` are saved-but-not-activated by the activation
  guard (correct, not a bug).

      mix predictions.seed_flagships                    # fast sampled dry-run, all 10 lists
      mix predictions.seed_flagships --sample 0         # exact pick (slow)
      mix predictions.seed_flagships --only criterion,afi_100
      mix predictions.seed_flagships --commit           # pick (sampled) + train chosen EXACT, spend holdouts
      mix predictions.seed_flagships --commit --only national_film_registry --json
  """
  use Mix.Task

  alias Cinegraph.Predictions.{ListFrontier, PreRegistration, Reliability, Trainer}

  @shortdoc "Honest re-promotion: auto-pick strategy per list; dry-run by default, --commit to spend (#1051)"

  @lists ~w(1001_movies afi_100 criterion cult_movies_400 ebert_great_movies
            letterboxd_top_250 national_film_registry sight_sound_critics_2022
            sight_sound_directors_2022 tspdt_1000)

  @strategies ~w(temporal static)
  @grade_rank %{high: 4, moderate: 3, low: 2, insufficient: 1}

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()
    # Many logistic fits in one process → BinaryBackend avoids EXLA's :system_limit.
    Application.put_env(:nx, :default_backend, Nx.BinaryBackend)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          commit: :boolean,
          only: :string,
          sample: :integer,
          seed: :integer,
          json: :boolean
        ]
      )

    commit = opts[:commit] || false

    # --commit can't honor --seed end-to-end (CodeRabbit #1059): the assess seeds
    # `Trainer.evaluate_strategy/3`, but `Trainer.train/2` has no seed knob, so the committed model
    # would differ from the seeded assessment. Reject the combination rather than mislead.
    if commit and opts[:seed],
      do: Mix.raise("--seed cannot be combined with --commit (train/2 does not accept a seed)")

    # The strategy PICK is sampled by default (the exact full-member-decade pool ≈ the whole catalog
    # for broad static lists — minutes→hours). Sampling preserves the relative temporal-vs-static
    # ranking; the COMMITTED model's stored grade is always exact (`Trainer.train` never samples).
    # Pass `--sample 0` to assess on the exact pool (slow). Projected grades are optimistic.
    # Reject negatives (CodeRabbit #1062): only 0/nil mean "exact full pool"; a negative would
    # slip past that check and sample with an invalid pool size instead of the documented behavior.
    sample =
      case Keyword.get(opts, :sample, 25_000) do
        n when is_integer(n) and n >= 0 -> n
        _ -> Mix.raise("--sample must be a non-negative integer")
      end

    targets =
      case opts[:only] do
        nil -> @lists
        csv -> validate_only(String.split(csv, ",", trim: true))
      end

    assess_opts = [sample: sample] |> maybe_put(:seed, opts[:seed])
    results = Enum.map(targets, fn sk -> assess(sk, assess_opts) end)

    results = if commit, do: Enum.map(results, &commit_one/1), else: results

    cond do
      opts[:json] -> IO.puts(Jason.encode!(results, pretty: true))
      commit -> print_commit(results)
      true -> print_dry_run(results, sample)
    end
  end

  # ── assessment (holdout-free; spends nothing) ─────────────────────────────────────
  defp assess(source_key, opts) do
    frontier = ListFrontier.resolve(source_key)

    evals =
      Map.new(@strategies, fn strategy ->
        {strategy, eval_strategy(source_key, strategy, frontier, opts)}
      end)

    recommended =
      evals
      |> Enum.filter(fn {_s, e} -> e.status == "ok" end)
      |> Enum.sort_by(fn {_s, e} -> {@grade_rank[e.grade] || 0, e.recall || 0.0} end, :desc)
      |> case do
        [{strategy, _} | _] -> strategy
        [] -> nil
      end

    %{source_key: source_key, evals: evals, recommended: recommended}
  end

  defp eval_strategy(source_key, strategy, frontier, opts) do
    case Trainer.evaluate_strategy(source_key, strategy, opts) do
      {:ok, %{report: report, calibration: calibration}} ->
        threshold = honest_threshold(report)

        scorecard =
          Reliability.score(report, calibration, %{
            is_stale: false,
            frontier: frontier,
            threshold: threshold,
            prereg?: true
          })

        %{
          status: "ok",
          strategy: strategy,
          recall: report["recall_at_k"],
          n_pos: report["n_positives"],
          pop: get_in(report, ["baselines", "popularity"]),
          threshold: threshold,
          grade: scorecard.grade,
          headline: scorecard.headline_pct
        }

      {:error, reason} ->
        %{status: "error", strategy: strategy, reason: inspect(reason)}
    end
  end

  # "Must beat the dumb baseline" — the honest, list-specific failure threshold.
  defp honest_threshold(report) do
    pop = get_in(report, ["baselines", "popularity"])
    if is_number(pop), do: Float.round(pop, 4), else: 0.0
  end

  # ── commit (spends the sacred holdout, one fresh prereg per list) ──────────────────
  defp commit_one(%{recommended: nil} = r),
    do: Map.put(r, :commit, %{status: "skipped", reason: "no valid strategy"})

  defp commit_one(%{source_key: sk, recommended: strategy, evals: evals} = r) do
    threshold = evals[strategy].threshold

    commit =
      with {:ok, prereg} <- register_prereg(sk, threshold),
           {:ok, summary} <-
             Trainer.train(sk,
               granularity: :data_point,
               save: true,
               prereg: prereg,
               backtest_strategy: strategy
             ) do
        %{
          status: "ok",
          strategy: strategy,
          model_id: summary[:model_id],
          recall_at_k: summary.integrity_report["recall_at_k"],
          calibration: summary.calibration["method"],
          passed: summary.verdict["passed"]
        }
      else
        {:error, reason} -> %{status: "error", strategy: strategy, reason: inspect(reason)}
      end

    Map.put(r, :commit, commit)
  end

  defp register_prereg(source_key, threshold) do
    PreRegistration.register(%{
      source_key: source_key,
      expected_top_features: %{"note" => "honest re-promotion (Stage C auto-pick)"},
      expected_accuracy_range: %{"min" => threshold, "max" => 1.0},
      failure_threshold: :erlang.float_to_binary(threshold, decimals: 4)
    })
  end

  # ── output ────────────────────────────────────────────────────────────────────────
  defp print_dry_run(results, sample) do
    note =
      if sample > 0,
        do: " · sample #{sample} (fast — recall/grades OPTIMISTIC vs full pool)",
        else: ""

    Mix.shell().info("\nHONEST RE-PROMOTION — dry-run, nothing spent#{note}\n")

    Mix.shell().info("#{pad("list", 28)}#{pad("temporal", 22)}#{pad("static", 22)}→ recommend")
    Mix.shell().info(String.duplicate("-", 92))

    Enum.each(results, fn %{source_key: sk, evals: e, recommended: rec} ->
      rec_label =
        case rec do
          nil -> "— (no valid strategy)"
          s -> "#{s} (#{e[s].grade})"
        end

      Mix.shell().info(
        "#{pad(sk, 28)}#{pad(cell(e["temporal"]), 22)}#{pad(cell(e["static"]), 22)}#{rec_label}"
      )
    end)

    Mix.shell().info("\nRun with --commit to spend the sacred holdouts and promote.\n")
  end

  defp cell(%{status: "ok", recall: r, grade: g}), do: "#{fmt(r)} #{g}"
  defp cell(%{status: "error", reason: reason}), do: "(#{String.slice(reason, 0, 14)})"
  defp cell(_), do: "—"

  defp print_commit(results) do
    Mix.shell().info("\nHONEST RE-PROMOTION — committed (sacred holdouts spent)\n")

    Enum.each(results, fn %{source_key: sk, commit: c} ->
      case c do
        %{status: "ok"} = c ->
          Mix.shell().info(
            "✓ #{pad(sk, 28)} #{pad(c.strategy, 9)} model ##{c.model_id} · " <>
              "recall@K #{fmt(c.recall_at_k)} · calib #{c.calibration} · passed=#{c.passed}"
          )

        %{status: "skipped", reason: reason} ->
          Mix.shell().info("• #{pad(sk, 28)} skipped — #{reason}")

        %{status: "error", reason: reason} ->
          Mix.shell().info("✗ #{pad(sk, 28)} error — #{reason}")
      end
    end)

    Mix.shell().info("\nRun `mix predictions.reliability --all` for the honest scoreboard.\n")
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────
  defp validate_only(requested) do
    {known, unknown} = Enum.split_with(requested, &(&1 in @lists))

    if unknown != [] do
      Mix.shell().error("Unknown list(s) skipped: #{Enum.join(unknown, ", ")}")
      Mix.shell().error("Valid lists: #{Enum.join(@lists, ", ")}")
    end

    # Dedup (CodeRabbit #1059): a repeated list under --commit would register two preregs and spend
    # the same holdout twice (holdout enforcement is per-prereg, not per-list).
    Enum.uniq(known)
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, val), do: Keyword.put(kw, key, val)

  defp pad(v, n), do: v |> to_string() |> String.pad_trailing(n)
  defp fmt(nil), do: "—"
  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 4)
  defp fmt(n), do: to_string(n)
end
