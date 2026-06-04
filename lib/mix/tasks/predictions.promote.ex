defmodule Mix.Tasks.Predictions.Promote do
  @moduledoc """
  Ledger-driven promotion (#1061 Session 2) — pick the best recorded model per list and activate it.

  For each list, reads the experiment ledger (`prediction_experiments`) and reports the best `ok`
  run ranked **grade first, then objective full-pool recall** (`COALESCE(objective_recall_at_k,
  recall_at_k)`) — the "top-grading entry," so a moderate/high run isn't beaten by a low run with a
  higher raw recall. Activation is restricted to **serving-cleared classes** — only `:active`-
  lifecycle classes, and in Session 2 only `linear_logreg` is ever pointed at a list. A non-linear
  winner (e.g. `pooled_linear`) is reported for transparency but NOT activated.

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

  alias Cinegraph.Predictions.{
    ExperimentLedger,
    ModelRegistry,
    PreRegistration,
    RunReporter,
    Trainer
  }

  alias Cinegraph.Repo
  alias Mix.Tasks.Predictions.ProgressLine

  @shortdoc "Promote the best ledger-recorded model per list (linear only; dry-run unless --commit)"

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()
    Application.put_env(:nx, :default_backend, Nx.BinaryBackend)
    # Exact full-pool training per list is query-heavy; quiet dev's :debug logging for the batch.
    Logger.configure(level: :warning)

    {opts, _, _} =
      OptionParser.parse(args, strict: [only: :string, commit: :boolean, json: :boolean])

    commit = opts[:commit] || false
    lists = target_lists(opts[:only])

    results = standings(lists)
    results = if commit, do: run_commit(results, opts), else: results

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

  # Buckets a model may SERVE (#1068 §6.2): exclude `canon_overlap` (pure circular signal — it
  # exists for the ablation, not for serving). `all` is allowed (graded on objective recall, and
  # Explanation discloses its circularity %); only `objective_only`/`all` may be activated.
  @activatable_buckets ~w(objective_only all)

  # ── assessment (reads the ledger; spends nothing) ─────────────────────────────────
  defp assess(source_key, promotable) do
    overall = best_row(source_key, fn _ -> true end)

    activatable =
      source_key
      |> best_row(&activatable_keep?(&1, promotable))
      |> prefer_static_if_underpowered(source_key, promotable)

    %{
      source_key: source_key,
      overall_best: brief(overall),
      activatable: brief(activatable),
      # the raw row is kept (not in JSON) for the commit step
      _activatable_row: activatable
    }
  end

  # A row is servable iff its class is promotable, it isn't graded insufficient, and its bucket is
  # serving-cleared (#1068 §6.1/§6.2 — canon_overlap excluded).
  defp activatable_keep?(r, promotable) do
    MapSet.member?(promotable, r.model_class) and r.grade != "insufficient" and
      r.feature_bucket in @activatable_buckets
  end

  # #1068 §6.4 ("prefer static, else disclose"): the TEMPORAL commit's sacred holdout is the single
  # latest decade, so a temporal ledger row graded on the pooled validation tier can still commit a
  # model that grades :insufficient on that one decade → the guard refuses it → the gamed model
  # persists. When the latest decade is underpowered (<10 members), re-pick the best STATIC
  # activatable (member-holdout, gradeable). If none qualifies, serve nothing (disclose).
  defp prefer_static_if_underpowered(nil, _sk, _promotable), do: nil

  defp prefer_static_if_underpowered(%{backtest_strategy: "temporal"} = row, sk, promotable) do
    if Trainer.temporal_underpowered?(sk) do
      best_row(sk, &(activatable_keep?(&1, promotable) and &1.backtest_strategy == "static"))
    else
      row
    end
  end

  defp prefer_static_if_underpowered(row, _sk, _promotable), do: row

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
    commit_one(result, nil)
  end

  # Wrap the commit loop in a `prediction_runs` lifecycle (#1065 Session 2): one promote run groups
  # the per-list `prediction_models` rows it activates (via their `run_id`) so promote shows up in the
  # unified runs history. `total_cells` counts only the lists that will actually train (activatable);
  # skipped lists aren't recorded.
  defp run_commit(results, opts) do
    run_id = gen_run_id()
    total = Enum.count(results, & &1._activatable_row)
    render? = !opts[:json]
    RunReporter.start(run_id, "promote", total, %{only: opts[:only]})
    started = System.monotonic_time(:millisecond)

    # try/rescue/after so a raised commit doesn't leave the run stuck "running" (and still clears the
    # status line). Mirrors run_matrix's lifecycle guard.
    try do
      {committed, _acc} =
        Enum.map_reduce(results, %{done: 0, failed: 0}, fn result, acc ->
          c = commit_one(result, run_id)
          record_commit(run_id, c)
          {c, render_progress(acc, c, total, started, render?)}
        end)

      RunReporter.finish(run_id, "completed")
      committed
    rescue
      e ->
        RunReporter.finish(run_id, "failed", e)
        reraise e, __STACKTRACE__
    catch
      # throw/exit also leave the run "running" without this (CodeRabbit #1072): finalize, then
      # re-raise the original kind/reason so the failure still propagates unchanged.
      kind, reason ->
        RunReporter.finish(run_id, "failed", {kind, reason})
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      if render?, do: ProgressLine.clear()
    end
  end

  # Skipped lists aren't part of the activatable total; don't advance the bar for them.
  defp render_progress(acc, %{commit: %{status: "skipped"}}, _total, _started, _render?), do: acc

  defp render_progress(acc, %{source_key: sk, commit: c}, total, started, render?) do
    done = acc.done + 1
    failed = acc.failed + if(c.status == "error", do: 1, else: 0)
    elapsed = System.monotonic_time(:millisecond) - started
    throughput = if elapsed > 0, do: done / (elapsed / 60_000), else: nil

    # Promote has no per-cell cost model; a running-average ETA (remaining lists × mean time/list so
    # far) is the honest estimate since per-list holdout-train times are roughly uniform.
    eta_ms = if done > 0, do: round(max(total - done, 0) * (elapsed / done)), else: nil

    if render? do
      ProgressLine.write(%{
        label: "promote",
        done: done,
        total: total,
        current: sk,
        throughput_per_min: throughput,
        eta_ms: eta_ms,
        failed: failed
      })
    end

    %{done: done, failed: failed}
  end

  defp record_commit(run_id, %{source_key: sk, commit: %{status: "ok"}}),
    do: RunReporter.record(run_id, %{status: :ok, current_cell: sk})

  defp record_commit(run_id, %{source_key: sk, commit: %{status: "error"}}),
    do: RunReporter.record(run_id, %{status: :failed, current_cell: sk})

  # Skipped lists (no activatable run) aren't part of total_cells — don't count them.
  defp record_commit(_run_id, _skipped), do: :ok

  defp gen_run_id do
    ms = Integer.to_string(System.system_time(:millisecond), 36)
    rand = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    "promote-#{ms}-#{rand}"
  end

  # ── commit (spends the sacred holdout, one fresh prereg per list) ──────────────────
  defp commit_one(%{_activatable_row: nil} = r, _run_id),
    do:
      Map.put(r, :commit, %{status: "skipped", reason: "no activatable (linear, sufficient) run"})

  defp commit_one(%{source_key: sk, _activatable_row: row} = r, run_id) do
    threshold = honest_threshold(row)

    # Replay the EXACT recorded training shape (#1061): strategy + feature bucket + weight variant.
    # Without this, a `static/objective_only` winner would be committed as `static/all`.
    train_opts =
      [
        granularity: :data_point,
        save: true,
        backtest_strategy: row.backtest_strategy,
        run_id: run_id
      ] ++
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
