defmodule Mix.Tasks.Predictions.Matrix do
  @moduledoc """
  Run the model matrix (#1061 Session 2) — `classes × lists × strategies × buckets` — recording
  every evaluated cell to the experiment ledger (`prediction_experiments`).

  Holdout-free (never touches the sacred holdout). This is how the ledger gets populated across
  model classes so `mix predictions.leaderboard` can answer "which model/strategy/features wins
  which list." Read-only sandbox runs (`mix predictions.experiment`) still don't persist.

      mix predictions.matrix                                   # all classes × all lists
      mix predictions.matrix --lists afi_100,criterion
      mix predictions.matrix --classes linear_logreg,pooled_linear --buckets objective_only,all
      mix predictions.matrix --lists afi_100 --sample 20000    # fast-mode (approx)
      mix predictions.matrix --json
      mix predictions.matrix --plan                            # estimate, don't run (#1065)

  Options:
    --lists        comma-separated source_keys (default: all active lists)
    --classes      comma-separated model_class keys (default: all registered)
    --strategies   comma-separated: temporal,static (default: both)
    --buckets      comma-separated: objective_only,canon_overlap,all,raw,derived (default: obj,canon,all)
    --sample       fast-mode non-member pool cap (0 = full pool, the honest default)
    --alpha        L2 regularization strength
    --seed         RNG seed (default 1337)
    --plan         print the planner-generated cell grid + a pool-weighted ETA from history; no run
    --json         machine-readable output
  """
  use Mix.Task

  alias Cinegraph.Predictions.{MatrixPlanner, Trainer}
  alias Mix.Tasks.Predictions.ProgressLine

  @shortdoc "Run classes × lists × strategies × buckets into the experiment ledger (#1061)"

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()
    # Many tiny fits in one process → BinaryBackend avoids EXLA's :system_limit.
    Application.put_env(:nx, :default_backend, Nx.BinaryBackend)
    # Full-pool scoring issues thousands of queries per cell; dev's :debug query logging would
    # dominate wall-clock and bloat the log. A matrix run is a batch job — quiet it to :warning.
    Logger.configure(level: :warning)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          lists: :string,
          classes: :string,
          strategies: :string,
          buckets: :string,
          sample: :integer,
          alpha: :float,
          seed: :integer,
          concurrency: :integer,
          plan: :boolean,
          json: :boolean
        ]
      )

    run_opts =
      []
      |> put_csv(:lists, opts[:lists])
      |> put_csv(:classes, opts[:classes])
      |> put_csv(:strategies, opts[:strategies])
      |> put_buckets(opts[:buckets])
      |> maybe_put(:sample, opts[:sample])
      |> maybe_put(:alpha, opts[:alpha])
      |> maybe_put(:seed, opts[:seed])
      # Concurrent full-pool cells each run big PG sorts; on memory-pressured boxes the kernel
      # kills backends (observed 2026-06-06: shared_buffers 16GB + concurrency 4 ⇒ backend SIGTERM
      # mid-run). --concurrency 2 trades wall-clock for stability.
      |> maybe_put(:max_concurrency, parse_concurrency(opts[:concurrency]))

    if opts[:plan] do
      run_plan(run_opts, opts[:json])
    else
      run_matrix(run_opts, opts[:json])
    end
  end

  # `--plan` (#1065): print the exact grid a real run would execute + a pool-weighted ETA from
  # Phase-1 `duration_ms` history, without running anything.
  defp run_plan(run_opts, json?) do
    est = run_opts |> MatrixPlanner.plan() |> MatrixPlanner.estimate(run_opts)

    if json? do
      IO.puts(Jason.encode!(plan_json(est), pretty: true))
    else
      print_plan(est)
    end
  end

  defp run_matrix(run_opts, json?) do
    t0 = System.monotonic_time(:millisecond)

    # JSON output stays clean (no status line writing to stdout); interactive runs get a live line.
    rows = if json?, do: Trainer.run_matrix(run_opts), else: run_with_progress(run_opts)
    secs = Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)

    if json? do
      IO.puts(Jason.encode!(%{seconds: secs, rows: Enum.map(rows, &row_json/1)}, pretty: true))
    else
      print_table(rows, secs)
    end
  end

  # Live status line (#1065 Phase 3): a per-cell `:on_progress` callback updates an accumulator and
  # rewrites one line. ETA = remaining cells × historical avg per-cell ÷ concurrency (the planner's
  # pool-weighted cost); throughput = cells/min so far.
  defp run_with_progress(run_opts) do
    plan = MatrixPlanner.plan(run_opts)
    total = plan.total
    conc = Keyword.get(run_opts, :max_concurrency, 4)
    avg_ms = avg_predicted(MatrixPlanner.price_cells(plan.cells))
    started = System.monotonic_time(:millisecond)

    {:ok, acc} = Agent.start_link(fn -> %{done: 0, failed: 0, current: nil} end)

    on_progress = fn event ->
      snap =
        Agent.get_and_update(acc, fn s ->
          s = %{
            done: s.done + 1,
            failed: s.failed + if(event.status == :failed, do: 1, else: 0),
            current: event.cell
          }

          {s, s}
        end)

      ProgressLine.write(progress_snapshot(snap, total, conc, avg_ms, started))
    end

    # try/after so a raised run still erases the half-drawn status line and stops the accumulator.
    try do
      Trainer.run_matrix(Keyword.put(run_opts, :on_progress, on_progress))
    after
      ProgressLine.clear()
      # Guard against :noproc (CodeRabbit #1072): if the agent already died, an unguarded stop in
      # `after` would raise and MASK the original run failure.
      if Process.alive?(acc), do: Agent.stop(acc)
    end
  end

  defp progress_snapshot(
         %{done: done, failed: failed, current: current},
         total,
         conc,
         avg_ms,
         started
       ) do
    elapsed_ms = System.monotonic_time(:millisecond) - started
    throughput = if elapsed_ms > 0, do: done / (elapsed_ms / 60_000), else: nil
    eta_ms = avg_ms && round(max(total - done, 0) * avg_ms / conc)

    %{
      label: "matrix",
      done: done,
      total: total,
      current: current,
      throughput_per_min: throughput,
      eta_ms: eta_ms,
      failed: failed
    }
  end

  defp avg_predicted(priced) do
    case Enum.reject(Enum.map(priced, & &1.predicted_ms), &is_nil/1) do
      [] -> nil
      ms -> Enum.sum(ms) / length(ms)
    end
  end

  defp print_table(rows, secs) do
    Mix.shell().info(
      "\nMATRIX — #{length(rows)} cells recorded in #{secs}s (failed cells also persisted)\n"
    )

    Mix.shell().info(
      "  #{pad("list", 26)}#{pad("class", 15)}#{pad("strat", 11)}#{pad("bucket", 16)}#{p("obj")}#{p("full")}#{pad("  grade", 12)}"
    )

    rows
    |> Enum.sort_by(&{&1.source_key, &1.model_class, &1.backtest_strategy, &1.feature_bucket})
    |> Enum.each(fn r ->
      m = r.metrics

      Mix.shell().info(
        "  #{pad(r.source_key, 26)}#{pad(r.model_class, 15)}#{pad(r.backtest_strategy, 11)}" <>
          "#{pad(r.feature_bucket, 16)}#{p(fmt(obj(m)))}#{p(fmt(m["recall_at_k"]))}#{pad("  " <> to_string(r.grade), 12)}"
      )
    end)

    Mix.shell().info("\nRead it back: mix predictions.leaderboard --by-class\n")
  end

  defp print_plan(est) do
    {pooled, per_cell} = Enum.split_with(est.by_class, &(&1.kind == :pooled))

    headline =
      Enum.map_join(est.by_class, " + ", &"#{&1.class} #{&1.count} #{kind_word(&1.kind)}")

    Mix.shell().info("\nMATRIX PLAN — #{est.total} cells   (#{headline})")

    basis =
      if est.basis_count > 0,
        do: "based on #{est.basis_count} historical cells",
        else: "no history yet — estimate unavailable"

    # State the expected error band (residual RMSE of the cost-model fit) so the ETA is honest about
    # its uncertainty — the acceptance band an actual run should land within. Only shown when the fit
    # is trustworthy (r² ≥ 0.5); below that the ETA falls back to empirical medians, so the model's
    # band wouldn't describe it.
    band =
      case est.cost_model do
        %{rel_err: re, r2: r2} when r2 >= 0.5 -> "±#{round(re * 100)}% · "
        _ -> ""
      end

    Mix.shell().info(
      "estimated wall-clock @ concurrency #{est.concurrency}:  ~#{dur(est.eta_ms)}   (#{band}#{basis})"
    )

    case est.cost_model do
      %{k: k, r2: r2, n: n} ->
        Mix.shell().info(
          "cost model:  duration ≈ #{Float.round(k, 4)} ms/movie-score · r² #{Float.round(r2, 2)} · n=#{n}\n"
        )

      _ ->
        Mix.shell().info("")
    end

    for c <- per_cell ++ pooled do
      # Per-class wall-clock contribution (work / concurrency) so the lines sum to the headline ETA;
      # `heaviest` below shows individual cell cost (undivided).
      contribution = c.predicted_ms && round(c.predicted_ms / est.concurrency)

      Mix.shell().info(
        "  #{pad(kind_word(c.kind), 9)} #{pad(c.class, 16)} #{pad("#{c.count} cells", 11)}" <>
          " ~#{pad(dur(contribution), 9)} (temporal #{c.temporal} · static #{c.static})"
      )
    end

    case est.heaviest do
      [] ->
        :ok

      heavy ->
        line = Enum.map_join(heavy, " · ", &"#{shape(&1)} (~#{dur(&1.predicted_ms)})")
        Mix.shell().info("  heaviest:  #{line}")
    end

    no_hist =
      case est.no_history do
        [] -> "<none>"
        cells -> cells |> Enum.map(&shape/1) |> Enum.uniq() |> Enum.join(" · ")
      end

    Mix.shell().info("  no history for:  #{no_hist}\n")
    Mix.shell().info("Run it: drop --plan.\n")
  end

  defp plan_json(est) do
    %{
      total: est.total,
      concurrency: est.concurrency,
      eta_ms: est.eta_ms,
      basis_count: est.basis_count,
      cost_model: est.cost_model,
      by_class:
        Enum.map(est.by_class, fn c ->
          %{
            class: c.class,
            kind: c.kind,
            count: c.count,
            temporal: c.temporal,
            static: c.static,
            predicted_ms: c.predicted_ms
          }
        end),
      heaviest: Enum.map(est.heaviest, &%{shape: shape(&1), predicted_ms: &1.predicted_ms}),
      no_history: est.no_history |> Enum.map(&shape/1) |> Enum.uniq()
    }
  end

  defp shape(c), do: "#{c.source_key}/#{c.strategy}/#{c.feature_bucket}"

  defp kind_word(:per_cell), do: "per-cell"
  defp kind_word(:pooled), do: "pooled"

  # Human wall-clock from milliseconds: "—" when unknown, else seconds under a minute else "Nm".
  defp dur(nil), do: "—"
  defp dur(ms) when ms < 60_000, do: "#{round(ms / 1000)}s"
  defp dur(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp row_json(r) do
    %{
      source_key: r.source_key,
      model_class: r.model_class,
      strategy: r.backtest_strategy,
      feature_bucket: r.feature_bucket,
      grade: r.grade,
      objective_recall_at_k: obj(r.metrics),
      recall_at_k: r.metrics["recall_at_k"]
    }
  end

  defp obj(m), do: m["objective_recall_at_k"] || m["recall_at_k"]

  defp put_csv(kw, _key, nil), do: kw
  defp put_csv(kw, key, csv), do: Keyword.put(kw, key, String.split(csv, ",", trim: true))

  defp put_buckets(kw, nil), do: kw

  defp put_buckets(kw, csv),
    do:
      Keyword.put(kw, :buckets, csv |> String.split(",", trim: true) |> Enum.map(&parse_bucket/1))

  @valid_buckets ~w(objective_only canon_overlap all raw derived)
  defp parse_bucket(b) when b in @valid_buckets, do: String.to_atom(b)

  defp parse_bucket(b),
    do:
      Mix.raise(
        "invalid --buckets value #{inspect(b)} (expected #{Enum.join(@valid_buckets, "|")})"
      )

  # `--concurrency 0` would divide-by-zero the ETA math (CodeRabbit #1083) and stall the run.
  defp parse_concurrency(nil), do: nil
  defp parse_concurrency(n) when is_integer(n) and n >= 1, do: n

  defp parse_concurrency(n),
    do: Mix.raise("invalid --concurrency #{inspect(n)} (expected integer >= 1)")

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, val), do: Keyword.put(kw, key, val)

  defp fmt(nil), do: "—"
  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 4)
  defp fmt(n), do: to_string(n)

  defp pad(v, n), do: v |> to_string() |> String.pad_trailing(n)
  defp p(v), do: v |> to_string() |> String.pad_leading(9)
end
