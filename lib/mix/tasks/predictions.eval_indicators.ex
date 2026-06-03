defmodule Mix.Tasks.Predictions.EvalIndicators do
  @moduledoc """
  Keep-criterion for the missingness indicators (#1051 A4).

  For each list, runs the holdout-free sandbox (`Trainer.run_sweep/3`, which shares one validation
  universe across variants) comparing:

    * **base** — `features: :objective_only` (the surface already includes each field's raw value), vs
    * **base + one indicator** — for each of `has_metacritic`, `has_budget`, …

  An indicator is **kept** (catalog `is_available: true`) only if it raises objective-only validation
  PR-AUC by ≥ the threshold on ≥ `--min-lists` lists. Because the indicators are tested *on top of*
  the raw value, any lift is the missingness *pattern* adding signal beyond the value — the guard
  against merely re-encoding "missing ⇒ canon". The candidate universe is ~100% OMDb-fetched (post
  A2), so a surviving indicator reflects genuine source-absence, not fetch-status (reported per list
  as the coverage-matched control).

  This task only MEASURES + recommends; flipping `is_available` is a separate migration so the
  decision is reviewable.

  ## Usage
      mix predictions.eval_indicators                 # all active lists
      mix predictions.eval_indicators --source-key tspdt_1000
      mix predictions.eval_indicators --min-lists 6 --threshold 0.005
  """
  use Mix.Task
  import Ecto.Query

  alias Cinegraph.Predictions.{CandidateUniverse, Trainer}
  alias Cinegraph.Repo

  @shortdoc "Evaluate which missingness indicators to keep (#1051 A4)"

  @indicators ~w(has_imdb_rating has_metacritic has_rotten_tomatoes has_budget has_revenue)

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()

    # This harness runs ~60 tiny logistic fits in one process; that exhausts EXLA's callback-server
    # limit (:system_limit). The fits are trivial (a few thousand × ~50), so route Nx to the
    # pure-Elixir BinaryBackend for this analysis run — set globally so the spawned sweep tasks
    # inherit it. (Results are backend-independent.)
    Application.put_env(:nx, :default_backend, Nx.BinaryBackend)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [source_key: :string, min_lists: :integer, threshold: :float, seed: :integer]
      )

    threshold = Keyword.get(opts, :threshold, 0.005)
    seed = Keyword.get(opts, :seed, 1337)

    lists =
      case Keyword.get(opts, :source_key) do
        nil -> Repo.all(from l in "movie_lists", where: l.active == true, select: l.source_key)
        sk -> [sk]
      end

    min_lists = Keyword.get(opts, :min_lists, max(1, div(length(lists) + 1, 2)))

    Mix.shell().info(
      "Evaluating #{length(@indicators)} indicators over #{length(lists)} lists " <>
        "(keep if Δpr_auc ≥ #{threshold} on ≥ #{min_lists} lists)\n"
    )

    # per_list: %{source_key => %{indicator => delta_pr_auc | nil}}
    per_list = Map.new(lists, fn sk -> {sk, eval_list(sk, seed)} end)

    print_per_list(per_list)
    print_control(lists)
    decide(per_list, threshold, min_lists)
  end

  # Returns %{"base" => pr_auc, indicator => delta_pr_auc, ...} or %{} if the list can't be evaluated.
  defp eval_list(source_key, seed) do
    objective = Trainer.data_point_codes(source_key) -- Trainer.canon_overlap_codes(source_key)

    if objective == [] do
      Mix.shell().info("  #{source_key}: no objective features — skipped")
      %{}
    else
      variants =
        [[id: "base", features: objective]] ++
          Enum.map(@indicators, fn ind -> [id: ind, features: objective ++ [ind]] end)

      by_id =
        Trainer.run_sweep(source_key, variants, seed: seed, max_concurrency: 6)
        |> Map.new(fn r -> {r.variant[:id], r.metrics["pr_auc"]} end)

      case by_id["base"] do
        nil ->
          Mix.shell().info("  #{source_key}: base experiment failed — skipped")
          %{}

        base_pr ->
          deltas =
            Map.new(@indicators, fn ind ->
              {ind, by_id[ind] && Float.round(by_id[ind] - base_pr, 4)}
            end)

          Map.put(deltas, "base", base_pr)
      end
    end
  end

  defp print_per_list(per_list) do
    Mix.shell().info("Δ PR-AUC vs objective-only baseline (per list):")
    Mix.shell().info(String.duplicate("-", 92))
    header = "list" |> String.pad_trailing(28)

    cols =
      Enum.map(@indicators, &(String.replace_prefix(&1, "has_", "") |> String.pad_leading(11)))

    Mix.shell().info(header <> "  base" <> Enum.join(cols))
    Mix.shell().info(String.duplicate("-", 92))

    Enum.each(per_list, fn {sk, m} ->
      if m == %{} do
        Mix.shell().info("#{String.pad_trailing(sk, 28)}  (skipped)")
      else
        base = "#{m["base"]}" |> String.pad_leading(6)

        cells =
          Enum.map(@indicators, fn ind ->
            d = m[ind]
            txt = if is_nil(d), do: "—", else: Float.to_string(d)
            String.pad_leading(txt, 11)
          end)

        Mix.shell().info("#{String.pad_trailing(sk, 28)}#{base}#{Enum.join(cells)}")
      end
    end)

    Mix.shell().info("")
  end

  # Coverage-matched control: fraction of each list's candidate universe that's OMDb-fetched.
  # High → a surviving indicator reflects source-absence (field genuinely missing), not fetch-status.
  defp print_control(lists) do
    Mix.shell().info("Coverage-matched control — candidate universe OMDb-fetched %:")

    Enum.each(lists, fn sk ->
      {members, negs} = CandidateUniverse.ids_for(sk)
      ids = members ++ negs

      fetched =
        Repo.one(
          from em in "external_metrics",
            where: em.source == "omdb" and em.movie_id in ^ids,
            select: count(em.movie_id, :distinct)
        ) || 0

      pct = if ids == [], do: 0.0, else: Float.round(fetched / length(ids) * 100, 1)

      Mix.shell().info(
        "  #{String.pad_trailing(sk, 28)} #{pct}% fetched (#{fetched}/#{length(ids)})"
      )
    end)

    Mix.shell().info("")
  end

  defp decide(per_list, threshold, min_lists) do
    Mix.shell().info("Decision (threshold Δ ≥ #{threshold}, on ≥ #{min_lists} lists):")

    survivors =
      Enum.filter(@indicators, fn ind ->
        passes =
          per_list
          |> Map.values()
          |> Enum.count(fn m -> is_number(m[ind]) and m[ind] >= threshold end)

        verdict = if passes >= min_lists, do: "KEEP", else: "drop"

        Mix.shell().info(
          "  #{String.pad_trailing(ind, 24)} passes on #{passes} lists → #{verdict}"
        )

        passes >= min_lists
      end)

    Mix.shell().info("\nRecommended survivors: #{inspect(survivors)}")

    Mix.shell().info(
      "Enable with a migration: UPDATE metric_definitions SET is_available = true WHERE code = ANY(#{inspect(survivors)})\n"
    )
  end
end
