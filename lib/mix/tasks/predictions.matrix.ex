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

  Options:
    --lists        comma-separated source_keys (default: all active lists)
    --classes      comma-separated model_class keys (default: all registered)
    --strategies   comma-separated: temporal,static (default: both)
    --buckets      comma-separated: objective_only,canon_overlap,all,raw,derived (default: obj,canon,all)
    --sample       fast-mode non-member pool cap (0 = full pool, the honest default)
    --alpha        L2 regularization strength
    --seed         RNG seed (default 1337)
    --json         machine-readable output
  """
  use Mix.Task

  alias Cinegraph.Predictions.Trainer

  @shortdoc "Run classes × lists × strategies × buckets into the experiment ledger (#1061)"

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()
    # Many tiny fits in one process → BinaryBackend avoids EXLA's :system_limit.
    Application.put_env(:nx, :default_backend, Nx.BinaryBackend)

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

    t0 = System.monotonic_time(:millisecond)
    rows = Trainer.run_matrix(run_opts)
    secs = Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)

    if opts[:json] do
      IO.puts(Jason.encode!(%{seconds: secs, rows: Enum.map(rows, &row_json/1)}, pretty: true))
    else
      print_table(rows, secs)
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

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, val), do: Keyword.put(kw, key, val)

  defp fmt(nil), do: "—"
  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 4)
  defp fmt(n), do: to_string(n)

  defp pad(v, n), do: v |> to_string() |> String.pad_trailing(n)
  defp p(v), do: v |> to_string() |> String.pad_leading(9)
end
