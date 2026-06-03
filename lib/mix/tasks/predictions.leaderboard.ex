defmodule Mix.Tasks.Predictions.Leaderboard do
  @moduledoc """
  Read the experiment ledger (#1061 Session 1) — "which model/strategy/features wins which list."

  Ranks recorded runs (`prediction_experiments`, `status = "ok"`) on **objective full-pool recall**
  — `objective_recall_at_k`, falling back to `recall_at_k` when a run has no objective measurement
  (the honest #1055 metric, never the gameable curated universe). This is the queryable form of the
  ablation board: instead of pasting CLI output into a doc, every persisted run is here for good.

      mix predictions.leaderboard                       # top 20 runs across all lists
      mix predictions.leaderboard --list 50             # top 50
      mix predictions.leaderboard --source-key tspdt_1000
      mix predictions.leaderboard --by-class            # best run per model_class
      mix predictions.leaderboard --json

  Options:
    --list N        how many rows to show (default 20)
    --source-key    restrict to one list
    --by-class      group by model_class, best-first within each
    --json          machine-readable
  """
  use Mix.Task
  import Ecto.Query

  alias Cinegraph.Predictions.ExperimentLedger
  alias Cinegraph.Repo

  @shortdoc "Rank recorded prediction experiments on objective full-pool recall (#1061)"

  # COALESCE(objective_recall_at_k, recall_at_k) — the honest ranking key.
  @rank_sql "COALESCE((? ->> 'objective_recall_at_k')::float, (? ->> 'recall_at_k')::float)"

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [list: :integer, source_key: :string, by_class: :boolean, json: :boolean]
      )

    limit = opts[:list] || 20
    rows = fetch_rows(opts[:source_key], limit)

    cond do
      opts[:json] -> IO.puts(Jason.encode!(Enum.map(rows, &row_json/1), pretty: true))
      opts[:by_class] -> print_by_class(rows)
      true -> print_table(rows, limit, opts[:source_key])
    end
  end

  defp fetch_rows(source_key, limit) do
    base =
      from e in ExperimentLedger,
        where: e.status == "ok",
        order_by: [desc_nulls_last: fragment(@rank_sql, e.metrics, e.metrics)],
        limit: ^limit

    base
    |> maybe_filter(source_key)
    |> Repo.all()
  end

  defp maybe_filter(query, nil), do: query
  defp maybe_filter(query, sk), do: from(e in query, where: e.source_key == ^sk)

  # ── output ──────────────────────────────────────────────────────────────────────
  defp print_table(rows, limit, source_key) do
    scope = if source_key, do: " · #{source_key}", else: ""

    Mix.shell().info("""

    PREDICTION LEADERBOARD#{scope} — top #{limit}, ranked by objective full-pool recall (#1055)
    obj = objective recall@K (honesty-graded) · full = canon-inclusive recall

      #{pad("list", 26)}#{pad("class", 15)}#{pad("strat", 11)}#{pad("bucket", 16)}#{p("obj")}#{p("full")}#{p("pr_auc")}#{pad("  grade", 12)}#{p("n_pos")}
    """)

    if rows == [] do
      Mix.shell().info(
        "  (no recorded experiments — run `mix predictions.ablation` to populate)\n"
      )
    else
      Enum.each(rows, fn r ->
        m = r.metrics

        Mix.shell().info(
          "  #{pad(r.source_key, 26)}#{pad(r.model_class, 15)}#{pad(r.backtest_strategy, 11)}" <>
            "#{pad(r.feature_bucket || "—", 16)}#{p(fmt(obj(m)))}#{p(fmt(m["recall_at_k"]))}" <>
            "#{p(fmt(m["pr_auc"]))}#{pad("  " <> to_string(r.grade), 12)}#{p(to_string(m["n_positives"]))}"
        )
      end)

      Mix.shell().info("")
    end
  end

  defp print_by_class(rows) do
    Mix.shell().info("\nLEADERBOARD BY MODEL CLASS — best objective recall per class\n")

    rows
    |> Enum.group_by(& &1.model_class)
    |> Enum.sort_by(fn {_class, rs} -> -best_obj(rs) end)
    |> Enum.each(fn {class, rs} ->
      Mix.shell().info("  #{class} — #{length(rs)} runs (best obj #{fmt(best_obj(rs))})")

      rs
      |> Enum.sort_by(&(-(obj(&1.metrics) || -1.0)))
      |> Enum.take(5)
      |> Enum.each(fn r ->
        m = r.metrics

        Mix.shell().info(
          "    #{pad(r.source_key, 26)}#{pad(r.backtest_strategy, 11)}#{pad(r.feature_bucket || "—", 16)}" <>
            "obj #{fmt(obj(m))} · full #{fmt(m["recall_at_k"])} · #{r.grade}"
        )
      end)
    end)

    Mix.shell().info("")
  end

  defp row_json(r) do
    %{
      source_key: r.source_key,
      model_class: r.model_class,
      strategy: r.backtest_strategy,
      feature_bucket: r.feature_bucket,
      grade: r.grade,
      objective_recall_at_k: obj(r.metrics),
      recall_at_k: r.metrics["recall_at_k"],
      pr_auc: r.metrics["pr_auc"],
      n_positives: r.metrics["n_positives"],
      run_at: r.run_at
    }
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────
  defp obj(m), do: m["objective_recall_at_k"] || m["recall_at_k"]

  defp best_obj(rows) do
    rows |> Enum.map(&(obj(&1.metrics) || -1.0)) |> Enum.max(fn -> -1.0 end)
  end

  defp fmt(nil), do: "—"
  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 4)
  defp fmt(n), do: to_string(n)

  defp pad(v, n), do: v |> to_string() |> String.pad_trailing(n)
  defp p(v), do: v |> to_string() |> String.pad_leading(9)
end
