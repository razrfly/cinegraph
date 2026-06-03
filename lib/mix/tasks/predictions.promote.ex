defmodule Mix.Tasks.Predictions.Promote do
  @moduledoc """
  Ledger-driven promotion (#1061 Session 2) — pick the best recorded model per list and activate it.

  For each list, reads the experiment ledger (`prediction_experiments`) and reports the best `ok`
  run by **objective full-pool recall** (`COALESCE(objective_recall_at_k, recall_at_k)`). Activation
  is restricted to **serving-cleared classes** — only `:active`-lifecycle classes, and in Session 2
  only `linear_logreg` is ever pointed at a list. A non-linear winner (e.g. `pooled_linear`) is
  reported for transparency but NOT activated.

  Activation goes through the existing integrity protocol: a fresh pre-registration (honest
  `failure_threshold` = the popularity baseline) + `Trainer.train(save: true)` on the winning
  strategy, which spends that list's sacred holdout exactly once.

      mix predictions.promote                      # dry-run standings for all lists
      mix predictions.promote --only afi_100,1001_movies
      mix predictions.promote --commit             # SPEND holdouts + activate the linear winners
      mix predictions.promote --json
  """
  use Mix.Task
  import Ecto.Query

  alias Cinegraph.Predictions.{ExperimentLedger, ModelRegistry, PreRegistration, Trainer}
  alias Cinegraph.Repo

  @shortdoc "Promote the best ledger-recorded model per list (linear only; dry-run unless --commit)"

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()
    Application.put_env(:nx, :default_backend, Nx.BinaryBackend)

    {opts, _, _} =
      OptionParser.parse(args, strict: [only: :string, commit: :boolean, json: :boolean])

    commit = opts[:commit] || false
    lists = target_lists(opts[:only])

    results = standings(lists)
    results = if commit, do: Enum.map(results, &commit_one/1), else: results

    cond do
      # strip the raw Ecto row (kept only to drive --commit) before JSON encoding.
      opts[:json] ->
        IO.puts(
          Jason.encode!(Enum.map(results, &Map.delete(&1, :_activatable_row)), pretty: true)
        )

      commit ->
        print_commit(results)

      true ->
        print_dry_run(results)
    end
  end

  @doc """
  Per-list promotion standings from the ledger (read-only; spends nothing). For each list:
  `:overall_best` (any class, for transparency) and `:activatable` (best `:active`-lifecycle,
  non-insufficient run — what `--commit` would activate). Exposed for testing.
  """
  def standings(lists, promotable \\ nil) do
    promotable = promotable || MapSet.new(ModelRegistry.promotable_keys())
    Enum.map(lists, &assess(&1, promotable))
  end

  # ── assessment (reads the ledger; spends nothing) ─────────────────────────────────
  defp assess(source_key, promotable) do
    overall = best_row(source_key, fn _ -> true end)

    activatable =
      best_row(source_key, fn r ->
        MapSet.member?(promotable, r.model_class) and r.grade != "insufficient"
      end)

    %{
      source_key: source_key,
      overall_best: brief(overall),
      activatable: brief(activatable),
      # the raw row is kept (not in JSON) for the commit step
      _activatable_row: activatable
    }
  end

  @grade_rank %{"high" => 4, "moderate" => 3, "low" => 2, "insufficient" => 1}

  # Best `ok` row for a list — **grade first, then objective recall** (#1061: "top-grading entry").
  # A moderate/high run outranks a low one even if the low run's recall is higher (reliability caps
  # differ). Filtered in Elixir by lifecycle/grade via `keep?`.
  defp best_row(source_key, keep?) do
    from(e in ExperimentLedger,
      where: e.status == "ok" and e.source_key == ^source_key
    )
    |> Repo.all()
    |> Enum.sort_by(fn r -> {Map.get(@grade_rank, r.grade, 0), obj(r.metrics) || 0.0} end, :desc)
    |> Enum.find(keep?)
  end

  defp brief(nil), do: nil

  defp brief(r) do
    %{
      model_class: r.model_class,
      strategy: r.backtest_strategy,
      feature_bucket: r.feature_bucket,
      grade: r.grade,
      objective_recall: obj(r.metrics),
      recall_at_k: r.metrics["recall_at_k"]
    }
  end

  @doc """
  Assess + commit a single list (spends its holdout). Exposed for testing the commit path;
  `run/1` maps this over the target lists. Returns the result map with a `:commit` key.
  """
  def commit(source_key) do
    [result] = standings([source_key])
    commit_one(result)
  end

  # ── commit (spends the sacred holdout, one fresh prereg per list) ──────────────────
  defp commit_one(%{_activatable_row: nil} = r),
    do:
      Map.put(r, :commit, %{status: "skipped", reason: "no activatable (linear, sufficient) run"})

  defp commit_one(%{source_key: sk, _activatable_row: row} = r) do
    threshold = honest_threshold(row)

    # Replay the EXACT recorded training shape (#1061): strategy + feature bucket + weight variant.
    # Without this, a `static/objective_only` winner would be committed as `static/all`.
    train_opts =
      [granularity: :data_point, save: true, backtest_strategy: row.backtest_strategy] ++
        replay_shape(row)

    commit =
      with {:ok, prereg} <- register_prereg(sk, threshold),
           {:ok, summary} <- Trainer.train(sk, [prereg: prereg] ++ train_opts) do
        %{
          status: "ok",
          model_class: row.model_class,
          strategy: row.backtest_strategy,
          feature_bucket: row.feature_bucket,
          model_id: summary[:model_id],
          recall_at_k: summary.integrity_report["recall_at_k"],
          passed: summary.verdict["passed"]
        }
      else
        {:error, reason} -> %{status: "error", reason: inspect(reason)}
      end

    Map.put(r, :commit, commit)
  end

  # The recorded feature bucket + weight variant, as Trainer.train opts. nil variant ⇒ defaults
  # (simplex / alpha 1.0), which is what every default matrix run used.
  defp replay_shape(row) do
    [features: bucket_atom(row.feature_bucket)]
    |> maybe_norm(row.metrics["weight_normalize"])
    |> maybe_alpha(row.metrics["alpha"])
  end

  # Explicit literal mapping (NOT String.to_existing_atom — that raises if the bucket atom isn't
  # loaded in the task process). Literals here are created at compile time of this module.
  defp bucket_atom("objective_only"), do: :objective_only
  defp bucket_atom("canon_overlap"), do: :canon_overlap
  defp bucket_atom("raw"), do: :raw
  defp bucket_atom("derived"), do: :derived
  defp bucket_atom("all"), do: :all
  # Unknown/legacy bucket → fall back to the full surface (the historical default).
  defp bucket_atom(_), do: :all

  defp maybe_norm(kw, "simplex"), do: Keyword.put(kw, :weight_normalize, :simplex)
  defp maybe_norm(kw, "signed"), do: Keyword.put(kw, :weight_normalize, :signed)
  defp maybe_norm(kw, _), do: kw

  defp maybe_alpha(kw, a) when is_number(a), do: Keyword.put(kw, :alpha, a)
  defp maybe_alpha(kw, _), do: kw

  defp honest_threshold(row) do
    pop = get_in(row.metrics, ["baselines", "popularity"])
    if is_number(pop), do: Float.round(pop, 4), else: 0.0
  end

  defp register_prereg(source_key, threshold) do
    PreRegistration.register(%{
      source_key: source_key,
      expected_top_features: %{"note" => "ledger-driven promotion (#1061 Session 2)"},
      expected_accuracy_range: %{"min" => threshold, "max" => 1.0},
      failure_threshold: :erlang.float_to_binary(threshold, decimals: 4)
    })
  end

  # ── output ────────────────────────────────────────────────────────────────────────
  defp print_dry_run(results) do
    Mix.shell().info("\nLEDGER-DRIVEN PROMOTION — dry-run, nothing spent\n")
    Mix.shell().info("#{pad("list", 26)}#{pad("overall best", 34)}→ would activate")
    Mix.shell().info(String.duplicate("-", 92))

    Enum.each(results, fn r ->
      Mix.shell().info("#{pad(r.source_key, 26)}#{pad(cell(r.overall_best), 34)}#{activation(r)}")
    end)

    Mix.shell().info("\nRun with --commit to spend the sacred holdouts and activate.\n")
  end

  defp print_commit(results) do
    Mix.shell().info("\nLEDGER-DRIVEN PROMOTION — committed (sacred holdouts spent)\n")

    Enum.each(results, fn %{source_key: sk, commit: c} ->
      case c do
        %{status: "ok"} = c ->
          Mix.shell().info(
            "✓ #{pad(sk, 26)} #{pad(c.model_class, 14)} #{pad(c.strategy, 9)} model ##{c.model_id} · recall #{fmt(c.recall_at_k)} · passed=#{c.passed}"
          )

        %{status: "skipped", reason: reason} ->
          Mix.shell().info("• #{pad(sk, 26)} skipped — #{reason}")

        %{status: "error", reason: reason} ->
          Mix.shell().info("✗ #{pad(sk, 26)} error — #{reason}")
      end
    end)

    Mix.shell().info("\nRun `mix predictions.reliability --all` for the live scoreboard.\n")
  end

  defp activation(%{activatable: nil, overall_best: nil}), do: "— (no recorded runs)"

  defp activation(%{activatable: nil, overall_best: %{model_class: c}}),
    do: "— (best is #{c}, not serving-cleared)"

  defp activation(%{activatable: a}), do: "#{a.model_class}/#{a.strategy} (#{a.grade})"

  defp cell(nil), do: "—"
  defp cell(b), do: "#{b.model_class}/#{b.strategy} obj=#{fmt(b.objective_recall)} #{b.grade}"

  defp target_lists(nil),
    do: Repo.all(from l in "movie_lists", where: not is_nil(l.source_key), select: l.source_key)

  defp target_lists(csv), do: String.split(csv, ",", trim: true)

  defp fmt(nil), do: "—"
  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 4)
  defp fmt(n), do: to_string(n)

  defp obj(m), do: m["objective_recall_at_k"] || m["recall_at_k"]
  defp pad(v, n), do: v |> to_string() |> String.pad_trailing(n)
end
