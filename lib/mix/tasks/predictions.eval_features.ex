defmodule Mix.Tasks.Predictions.EvalFeatures do
  @moduledoc """
  Keep-criterion for the Tier-0 categorical features (#1070 Phase 1).

  Sibling of `mix predictions.eval_indicators` — same holdout-free A/B harness (`Trainer.run_sweep/3`,
  one shared validation universe per list), applied to the new categorical channel instead of the
  missingness indicators. For each list it compares:

    * **base** — `features: :objective_only` (the current B₀ feature surface), vs
    * **base + group** — for each of `lang` (language one-hot), `genre` (genre multi-hot),
      `rating` (`content_rating_age`), and `all` (all three together).

  A group is **kept** (flip its codes' catalog `is_available: true` via migration) only if it raises
  objective-only validation **PR-AUC** by ≥ `--threshold` on ≥ `--min-lists` lists. The codes emit
  even while `is_available: false` because they're in `DerivedFeatures.supported_codes/0` and passed
  explicitly here — so this measures candidate features without touching the served surface.

  This task only MEASURES + recommends; flipping `is_available` is a separate migration so the
  decision is reviewable (exactly like `eval_indicators`).

  ## Scope (#1070 Phase 1) — what's in, what's deferred
    * **In:** language one-hot, genre multi-hot, `content_rating_age` ordinal.
    * **Deferred to Phase 1b:** `keyword_ids` (high-cardinality ~50k → needs feature-hashing or
      top-K; a user-approved deferral, not an oversight). The catalog/emitter scaffolding here is
      the template to extend.
    * **Deferred to a parallel eval task:** the richer honesty metrics (stratified recall@K,
      lift@top-x%, AUL). This harness gates on **PR-AUC** — the smooth iteration metric — by design;
      a group that doesn't move PR-AUC won't move full-pool recall@K, so this is the cheap pre-filter
      before the matrix/holdout.

  ## Audit trail (#1070 §4 "one lever per trip")
  This is a holdout-free *iteration-tier* A/B, so it does NOT write `prediction_experiments` ledger
  rows (the ledger is the holdout-graded record written by `evaluate_cell`). Durable record instead:
  `--json` emits the per-list deltas + decision for the learning log; a **kept** group is then flipped
  `is_available: true` (migration) → it enters the `objective_only` matrix bucket → and *there* it
  earns ledger rows the normal way. So kept candidates get the ledger; rejected candidates get the
  JSON artifact + the report under `docs/scoring/reports/`.

  ## Usage
      mix predictions.eval_features                      # all active lists (human table)
      mix predictions.eval_features --source-key 1001_movies
      mix predictions.eval_features --min-lists 3 --threshold 0.005
      mix predictions.eval_features --sample 40000        # era-stratified pool sample → minutes, not 30m+
      mix predictions.eval_features --seed 7 --json      # machine-readable (learning-log artifact)
  """
  use Mix.Task
  import Ecto.Query

  alias Cinegraph.Predictions.Trainer
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.DerivedFeatures

  @shortdoc "Evaluate which Tier-0 categorical feature groups to keep (#1070 Phase 1)"

  # group_id => the candidate codes added on top of the objective-only base.
  defp groups do
    [
      {"lang", DerivedFeatures.language_codes()},
      {"genre", DerivedFeatures.genre_codes()},
      {"rating", ["content_rating_age"]},
      {"cat", DerivedFeatures.categorical_codes()},
      {"text", Cinegraph.Scoring.TextFeatures.codes()}
    ]
  end

  @group_ids ~w(lang genre rating cat text)

  # Rough archetype tags (#1070 §4) — display-only, to read deltas in context.
  @archetype %{
    "afi_100" => "consensus",
    "1001_movies" => "consensus",
    "national_film_registry" => "consensus",
    "sight_sound_critics_2022" => "consensus",
    "sight_sound_directors_2022" => "consensus",
    "tspdt_1000" => "auteur",
    "criterion" => "auteur",
    "ebert_great_movies" => "auteur",
    "cult_movies_400" => "taste",
    "letterboxd_top_250" => "taste"
  }

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()
    # Many tiny logistic fits in one process exhaust EXLA's callback-server limit; route Nx to the
    # pure-Elixir BinaryBackend (results are backend-independent), matching eval_indicators.
    Application.put_env(:nx, :default_backend, Nx.BinaryBackend)

    # Quiet dev's :debug Ecto query logging so `--json` stdout is the JSON only (matches promote.ex).
    Logger.configure(level: :warning)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          source_key: :string,
          min_lists: :integer,
          threshold: :float,
          seed: :integer,
          sample: :integer,
          json: :boolean
        ]
      )

    threshold = Keyword.get(opts, :threshold, 0.005)
    seed = Keyword.get(opts, :seed, 1337)
    sample = Keyword.get(opts, :sample, 0)
    json? = Keyword.get(opts, :json, false)

    lists =
      case Keyword.get(opts, :source_key) do
        nil -> Repo.all(from l in "movie_lists", where: l.active == true, select: l.source_key)
        sk -> [sk]
      end

    min_lists = Keyword.get(opts, :min_lists, max(1, div(length(lists) + 1, 2)))

    unless json? do
      Mix.shell().info(
        "Evaluating #{length(@group_ids)} categorical groups over #{length(lists)} lists " <>
          "(keep if Δpr_auc ≥ #{threshold} on ≥ #{min_lists} lists)\n"
      )
    end

    per_list = Map.new(lists, fn sk -> {sk, eval_list(sk, seed, sample, json?)} end)
    survivors = compute_survivors(per_list, threshold, min_lists)

    if json? do
      emit_json(per_list, survivors, seed, threshold, min_lists)
    else
      print_per_list(per_list)
      print_decision(per_list, survivors, threshold, min_lists)
    end
  end

  # %{"base" => pr_auc, group_id => delta_pr_auc, ...} or %{} if the list can't be evaluated.
  # `sample > 0` era-stratified-samples the non-member pool (passthrough to `run_experiment`), which
  # collapses the dominant cost (pool-weighted loading/assembly) for the iteration-tier PR-AUC gate —
  # the full pool is only needed for the final holdout recall@K, not this keep/kill check.
  defp eval_list(source_key, seed, sample, json?) do
    objective = Trainer.data_point_codes(source_key) -- Trainer.canon_overlap_codes(source_key)

    if objective == [] do
      unless json?, do: Mix.shell().info("  #{source_key}: no objective features — skipped")
      %{}
    else
      variants =
        [[id: "base", features: objective]] ++
          Enum.map(groups(), fn {id, codes} -> [id: id, features: objective ++ codes] end)

      by_id =
        Trainer.run_sweep(source_key, variants, seed: seed, sample: sample, max_concurrency: 6)
        |> Map.new(fn r -> {r.variant[:id], r.metrics["pr_auc"]} end)

      case by_id["base"] do
        nil ->
          unless json?, do: Mix.shell().info("  #{source_key}: base experiment failed — skipped")
          %{}

        base_pr ->
          deltas =
            Map.new(@group_ids, fn id ->
              {id, by_id[id] && Float.round(by_id[id] - base_pr, 4)}
            end)

          Map.put(deltas, "base", base_pr)
      end
    end
  end

  defp print_per_list(per_list) do
    Mix.shell().info("Δ PR-AUC vs objective-only baseline (per list):")
    Mix.shell().info(String.duplicate("-", 84))

    header =
      "list"
      |> String.pad_trailing(28)
      |> Kernel.<>("arch" |> String.pad_trailing(11))
      |> Kernel.<>("base" |> String.pad_leading(7))
      |> Kernel.<>(Enum.map_join(@group_ids, "", &String.pad_leading(&1, 9)))

    Mix.shell().info(header)
    Mix.shell().info(String.duplicate("-", 84))

    per_list
    |> Enum.sort_by(fn {sk, _} -> {@archetype[sk] || "z", sk} end)
    |> Enum.each(fn {sk, m} ->
      arch = String.pad_trailing(@archetype[sk] || "—", 11)

      if m == %{} do
        Mix.shell().info("#{String.pad_trailing(sk, 28)}#{arch}(skipped)")
      else
        base = "#{m["base"]}" |> String.pad_leading(7)

        cells =
          Enum.map_join(@group_ids, "", fn id ->
            d = m[id]
            txt = if is_nil(d), do: "—", else: Float.to_string(d)
            String.pad_leading(txt, 9)
          end)

        Mix.shell().info("#{String.pad_trailing(sk, 28)}#{arch}#{base}#{cells}")
      end
    end)

    Mix.shell().info("")
  end

  # Pure keep-criterion: how many lists each group clears, and whether it passes ≥ min_lists.
  defp compute_survivors(per_list, threshold, min_lists) do
    Enum.filter(@group_ids, fn id -> passes_count(per_list, id, threshold) >= min_lists end)
  end

  defp passes_count(per_list, id, threshold) do
    per_list
    |> Map.values()
    |> Enum.count(fn m -> is_number(m[id]) and m[id] >= threshold end)
  end

  defp codes_for(survivors) do
    map = Map.new(groups())
    survivors |> Enum.flat_map(&Map.get(map, &1, [])) |> Enum.uniq()
  end

  defp print_decision(per_list, survivors, threshold, min_lists) do
    Mix.shell().info("Decision (threshold Δ ≥ #{threshold}, on ≥ #{min_lists} lists):")

    Enum.each(@group_ids, fn id ->
      passes = passes_count(per_list, id, threshold)
      verdict = if id in survivors, do: "KEEP", else: "drop"
      Mix.shell().info("  #{String.pad_trailing(id, 8)} passes on #{passes} lists → #{verdict}")
    end)

    Mix.shell().info("\nRecommended survivor groups: #{inspect(survivors)}")

    case codes_for(survivors) do
      [] ->
        Mix.shell().info(
          "No group cleared the keep-criterion — Tier-0 categorical signal is flat.\n"
        )

      codes ->
        Mix.shell().info(
          "Enable with a migration: UPDATE metric_definitions SET is_available = true " <>
            "WHERE code = ANY(#{inspect(codes)})\n"
        )
    end
  end

  # Machine-readable artifact for the #1070 learning log (run with multiple seeds → noise band).
  defp emit_json(per_list, survivors, seed, threshold, min_lists) do
    payload = %{
      phase: "1_tier0",
      seed: seed,
      threshold: threshold,
      min_lists: min_lists,
      survivors: survivors,
      codes_to_enable: codes_for(survivors),
      per_list:
        Map.new(per_list, fn {sk, m} ->
          {sk, Map.put(m, "archetype", @archetype[sk] || "—")}
        end)
    }

    IO.puts(Jason.encode!(payload, pretty: true))
  end
end
