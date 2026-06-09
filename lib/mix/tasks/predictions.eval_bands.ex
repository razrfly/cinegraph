defmodule Mix.Tasks.Predictions.EvalBands do
  @moduledoc """
  Keep-criterion for the band (one-hot) features (#1087).

  Sibling of `mix predictions.eval_features` — same holdout-free A/B harness (`Trainer.run_sweep/3`,
  full-pool validation by default), but the band variant **replaces** the raw continuous codes with
  their one-hot bands instead of *adding* a group on top of the baseline. #1086 showed the
  raw-continuous + monotonic + non-negative model can't represent the inverted-U that box office has
  for arthouse/cult lists; bands let each list learn its own shape from data.

  For each list it compares:

    * **base** — `features: :objective_only` (the current B₀ surface), vs
    * **bands_simplex** — `(:objective_only − raw continuous codes) ++ band codes` (default simplex
      weighting; one-hot bins already express an inverted-U: high middle bins, ~0 extremes), vs
    * **bands_signed** — same features with `weight_normalize: :signed` (lets an extreme bin go
      actively below baseline).

  Bands are **kept** (flip their catalog `is_available: true` via migration, and disable the raw codes
  they replace) only if they raise objective validation **PR-AUC** by ≥ `--threshold` on ≥
  `--min-lists` lists — identical convention to `eval_features`. The band codes emit even while
  catalogued `is_available: false` because they're in `DerivedFeatures.supported_codes/0` and passed
  explicitly here, so this measures the candidate surface without touching the served models.

  This task only MEASURES + recommends; the migration is separate (reviewable). It also prints the
  fitted per-bin **revenue-band weights** for each list so the shape-sanity check is visible:
  `1001_movies` should rise across bins; `criterion`/`cult_movies_400` should peak in the middle and
  fall at the extremes (the inverted-U we claim to capture).

  ## Usage
      mix predictions.eval_bands                          # all active lists (human table)
      mix predictions.eval_bands --source-key criterion
      mix predictions.eval_bands --min-lists 3 --threshold 0.005
      mix predictions.eval_bands --sample 20000           # pool sample → minutes (approx, iteration)
      mix predictions.eval_bands --seed 7 --json          # machine-readable (learning-log artifact)
  """
  use Mix.Task
  import Ecto.Query

  alias Cinegraph.Predictions.Trainer
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.DerivedFeatures

  @shortdoc "Evaluate whether to replace raw continuous features with one-hot bands (#1087)"

  # Box-office raw codes the bands REPLACE (#1087 refined hypothesis): bin ONLY the families with a
  # proven inverted-U (#1086) and leave RT/votes/ratings/popularity raw, so we capture shape where
  # it's non-monotonic without losing resolution where it's monotonic. `--` is a no-op for any code a
  # list's surface doesn't contain, so this is safe per-list. This is also the exact set the Stage-5
  # migration sets `is_available: false`.
  @bo_raw ~w(tmdb_revenue_worldwide omdb_revenue_domestic tmdb_budget box_office_roi)
  @bo_prefixes ~w(rev_ww rev_dom budget roi)

  # The band variants compared against base. `bands_all_*` (replace EVERY continuous code) were
  # measured net-negative (resolution loss) on criterion/cult/1001, so the A/B keeps only the
  # box-office-only design (bin rev_ww/rev_dom/budget/roi, leave the rest raw).
  @variant_ids ~w(bands_bo_simplex bands_bo_signed)

  # The family whose fitted per-bin weights we print for the shape-sanity check.
  @shape_prefix "rev_ww"

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
    # pure-Elixir BinaryBackend (results are backend-independent), matching eval_features.
    Application.put_env(:nx, :default_backend, Nx.BinaryBackend)
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
        "Evaluating band variants over #{length(lists)} lists " <>
          "(keep if Δpr_auc ≥ #{threshold} on ≥ #{min_lists} lists; sample=#{sample}, seed=#{seed})\n"
      )
    end

    per_list = Map.new(lists, fn sk -> {sk, eval_list(sk, seed, sample, json?)} end)
    survivors = compute_survivors(per_list, threshold, min_lists)

    if json? do
      emit_json(per_list, survivors, seed, threshold, min_lists)
    else
      print_per_list(per_list)
      print_shapes(per_list)
      print_decision(per_list, survivors, threshold, min_lists)
    end
  end

  # %{"base" => pr_auc, "bands_simplex" => Δ, "bands_signed" => Δ, :shape => %{variant => [{code,w}]}}
  # or %{} when the list can't be evaluated.
  defp eval_list(source_key, seed, sample, json?) do
    objective = Trainer.data_point_codes(source_key) -- Trainer.canon_overlap_codes(source_key)
    bo_bands = Enum.flat_map(@bo_prefixes, &DerivedFeatures.band_codes_for/1)
    bo_banded = (objective -- @bo_raw) ++ bo_bands

    cond do
      objective == [] ->
        unless json?, do: Mix.shell().info("  #{source_key}: no objective features — skipped")
        %{}

      bo_banded == objective ->
        # No box-office codes present to replace → banding can't apply on this list.
        unless json?,
          do: Mix.shell().info("  #{source_key}: no box-office codes to band — skipped")

        %{}

      true ->
        variants = [
          [id: "base", features: objective],
          [id: "bands_bo_simplex", features: bo_banded],
          [id: "bands_bo_signed", features: bo_banded, weight_normalize: :signed]
        ]

        by_id =
          Trainer.run_sweep(source_key, variants, seed: seed, sample: sample, max_concurrency: 4)
          |> Map.new(fn r -> {r.variant[:id], r} end)

        case by_id["base"] do
          nil ->
            unless json?,
              do: Mix.shell().info("  #{source_key}: base experiment failed — skipped")

            %{}

          base ->
            base_pr = base.metrics["pr_auc"]

            deltas =
              Map.new(@variant_ids, fn id ->
                {id,
                 by_id[id] && base_pr && Float.round(by_id[id].metrics["pr_auc"] - base_pr, 4)}
              end)

            deltas
            |> Map.put("base", base_pr)
            |> Map.put(:shape, shape_weights(by_id))
        end
    end
  end

  # Fitted revenue-band weights per band variant, ordered missing → b0..bN, for the shape check.
  defp shape_weights(by_id) do
    codes = DerivedFeatures.band_codes_for(@shape_prefix)

    Map.new(@variant_ids, fn id ->
      weights = (by_id[id] && by_id[id].weights) || %{}
      {id, Enum.map(codes, fn c -> {c, weights[c]} end)}
    end)
  end

  defp print_per_list(per_list) do
    Mix.shell().info("Δ PR-AUC vs objective-only baseline (per list):")
    Mix.shell().info(String.duplicate("-", 72))

    header =
      "list"
      |> String.pad_trailing(28)
      |> Kernel.<>("arch" |> String.pad_trailing(11))
      |> Kernel.<>("base" |> String.pad_leading(8))
      |> Kernel.<>(Enum.map_join(@variant_ids, "", &String.pad_leading(&1, 16)))

    Mix.shell().info(header)
    Mix.shell().info(String.duplicate("-", 72))

    per_list
    |> Enum.sort_by(fn {sk, _} -> {@archetype[sk] || "z", sk} end)
    |> Enum.each(fn {sk, m} ->
      arch = String.pad_trailing(@archetype[sk] || "—", 11)

      if m == %{} do
        Mix.shell().info("#{String.pad_trailing(sk, 28)}#{arch}(skipped)")
      else
        base = "#{m["base"]}" |> String.pad_leading(8)

        cells =
          Enum.map_join(@variant_ids, "", fn id ->
            d = m[id]
            txt = if is_nil(d), do: "—", else: Float.to_string(d)
            String.pad_leading(txt, 16)
          end)

        Mix.shell().info("#{String.pad_trailing(sk, 28)}#{arch}#{base}#{cells}")
      end
    end)

    Mix.shell().info("")
  end

  # The shape-sanity check (#1087): print fitted revenue-band weights so the curve is visible.
  # Rising across bins = monotonic-positive (expected for 1001_movies); a middle peak that falls at
  # the extremes = the inverted-U (expected for criterion/cult).
  defp print_shapes(per_list) do
    Mix.shell().info("Revenue-band weights (#{@shape_prefix}) — bands_bo_simplex (shape-sanity):")
    Mix.shell().info(String.duplicate("-", 72))

    per_list
    |> Enum.reject(fn {_sk, m} -> m == %{} end)
    |> Enum.sort_by(fn {sk, _} -> {@archetype[sk] || "z", sk} end)
    |> Enum.each(fn {sk, m} ->
      pairs = get_in(m, [:shape, "bands_bo_simplex"]) || []

      curve =
        Enum.map_join(pairs, "  ", fn {code, w} ->
          short = String.replace_prefix(code, "#{@shape_prefix}_", "")
          "#{short}=#{fmt_w(w)}"
        end)

      Mix.shell().info("#{String.pad_trailing(sk, 22)}#{curve}")
    end)

    Mix.shell().info("")
  end

  defp compute_survivors(per_list, threshold, min_lists) do
    Enum.filter(@variant_ids, fn id -> passes_count(per_list, id, threshold) >= min_lists end)
  end

  defp passes_count(per_list, id, threshold) do
    per_list
    |> Map.values()
    |> Enum.count(fn m -> is_number(m[id]) and m[id] >= threshold end)
  end

  defp print_decision(per_list, survivors, threshold, min_lists) do
    Mix.shell().info("Decision (threshold Δ ≥ #{threshold}, on ≥ #{min_lists} lists):")

    Enum.each(@variant_ids, fn id ->
      passes = passes_count(per_list, id, threshold)
      verdict = if id in survivors, do: "KEEP", else: "drop"
      Mix.shell().info("  #{String.pad_trailing(id, 14)} passes on #{passes} lists → #{verdict}")
    end)

    Mix.shell().info("\nRecommended band variants: #{inspect(survivors)}")

    if survivors == [] do
      Mix.shell().info("No band variant cleared the keep-criterion — banding signal is flat.\n")
    else
      Mix.shell().info(
        "Next (separate, reviewable migration): set band codes is_available = true AND set the " <>
          "replaced box-office raw codes #{inspect(@bo_raw)} is_available = false, then " <>
          "`mix predictions.matrix --sample 0` + `mix predictions.promote --commit`.\n"
      )
    end
  end

  defp emit_json(per_list, survivors, seed, threshold, min_lists) do
    payload = %{
      experiment: "1087_bands",
      seed: seed,
      threshold: threshold,
      min_lists: min_lists,
      raw_codes_replaced: @bo_raw,
      survivors: survivors,
      per_list:
        Map.new(per_list, fn {sk, m} ->
          {sk,
           m
           |> Map.drop([:shape])
           |> Map.put("archetype", @archetype[sk] || "—")
           |> Map.put("rev_band_weights", json_shape(m[:shape]))}
        end)
    }

    IO.puts(Jason.encode!(payload, pretty: true))
  end

  defp json_shape(nil), do: %{}

  defp json_shape(shape) do
    Map.new(shape, fn {variant, pairs} ->
      {variant, Map.new(pairs, fn {code, w} -> {code, w} end)}
    end)
  end

  defp fmt_w(nil), do: "—"
  defp fmt_w(w) when is_float(w), do: :erlang.float_to_binary(w, decimals: 3)
  defp fmt_w(w), do: to_string(w)
end
