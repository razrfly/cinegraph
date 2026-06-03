defmodule Cinegraph.Predictions.Trainer do
  @moduledoc """
  Integrity-enforcing training orchestrator (#1036 Session 3).

  One flow for both granularities (`:lens` and `:data_point`), wired to the Layer-2 `Bus` and
  the credibility engine, enforcing the Prediction Integrity Protocol:

    1. **Pre-registration required to save** — `train(save: true)` refuses without a prereg
       (`{:error, :prereg_required}`); the prereg fixes the hypothesis + `failure_threshold`
       before any result is seen.
    2. **Sacred holdout** — the latest decade is reserved, never trained on, and scored exactly
       once; `holdout_spent_at` is stamped on the persisted model.
    3. **Honest verdict** — recall@K / precision@K / Brier / per-decade / worst-miss / dumb
       baselines on the holdout, written to `integrity_report`; calibration to `calibration`.
       The model "passes" only if it beats the popularity baseline AND clears the
       pre-registered `failure_threshold` — otherwise it's recorded as a failure, not hidden.

  Low-level fitting (`fit_model`, `extract_weights`) is reused from `WeightOptimizer`; the
  6-lens `WeightOptimizer.train/sweep` remain for back-compat.
  """

  import Ecto.Query

  alias Cinegraph.Metrics
  alias Cinegraph.Movies.{Movie, MovieLists}

  alias Cinegraph.Predictions.{
    Credibility,
    HistoricalValidator,
    LensScoring,
    Model,
    PreRegistration,
    ProbabilityCalibration,
    WeightOptimizer
  }

  alias Cinegraph.Repo
  alias Cinegraph.Scoring.{DataPointFeatures, DerivedFeatures, LensConfig}

  require Logger

  @lens_criteria LensScoring.scoring_criteria()
  @default_weights LensScoring.get_default_weights()

  @doc """
  Train + evaluate a model under the integrity protocol.

  ## Options
    * `:granularity` — `:lens` (default) or `:data_point`
    * `:save` — persist the artifact + set it active (requires a prereg)
    * `:prereg` — a `%PreRegistration{}` (required when `save: true`)
    * `:sample_ratio` — negative undersampling ratio (default 5)
    * `:backtest_strategy` — recorded on the model (default `"temporal"`)

  Returns `{:ok, summary}` or `{:error, reason}`.
  """
  def train(source_key, opts \\ []) do
    granularity = Keyword.get(opts, :granularity, :lens)
    save = Keyword.get(opts, :save, false)
    sample_ratio = Keyword.get(opts, :sample_ratio, 5)
    strategy = Keyword.get(opts, :backtest_strategy, "temporal")
    prereg = Keyword.get(opts, :prereg)

    cond do
      save and is_nil(prereg) ->
        {:error, :prereg_required}

      save and holdout_spent?(prereg) ->
        # A pre-registration buys exactly ONE sacred-holdout evaluation. Re-running against
        # the same prereg would re-spend the holdout — register a fresh hypothesis instead.
        {:error, :holdout_already_spent}

      true ->
        do_train(source_key, granularity, save, sample_ratio, strategy, prereg)
    end
  end

  defp holdout_spent?(nil), do: false

  defp holdout_spent?(prereg) do
    Repo.exists?(
      from m in Model, where: m.prereg_id == ^prereg.id and not is_nil(m.holdout_spent_at)
    )
  end

  defp do_train(source_key, granularity, save, sample_ratio, strategy, prereg) do
    result =
      cond do
        granularity == :data_point and data_point_codes(source_key) == [] ->
          # No usable features → fitting would crash inside Nx; fail with a clear reason.
          {:error, :no_data_point_features}

        strategy == "static" ->
          evaluate_static(granularity, source_key, sample_ratio, [])

        true ->
          evaluate_temporal(granularity, source_key, sample_ratio)
      end

    with {:ok,
          %{weights: weights, feature_set: feature_set, feature_names: names, report: report}} <-
           result do
      pairs = report["pairs"] || []
      {scores, labels} = if pairs == [], do: {[], []}, else: Enum.unzip(pairs)
      calibration = ProbabilityCalibration.fit(scores, labels)
      brier = Credibility.brier_calibrated(pairs, calibration)

      integrity =
        report
        |> Map.delete("pairs")
        |> Map.merge(%{
          "brier" => brier,
          "backtest_strategy" => strategy,
          "granularity" => to_string(granularity)
        })

      summary = %{
        source_key: source_key,
        granularity: granularity,
        weights: weights,
        feature_names: names,
        integrity_report: integrity,
        calibration: calibration,
        verdict: verdict(integrity, prereg)
      }

      if save do
        case persist(source_key, weights, feature_set, integrity, calibration, prereg, strategy) do
          {:ok, model} -> {:ok, Map.put(summary, :model_id, model.id)}
          {:error, reason} -> {:error, reason}
        end
      else
        {:ok, summary}
      end
    end
  end

  @doc """
  Run a **holdout-free experiment** (#1040 Session 1) — the iteration sandbox.

  Fits on the train decades and evaluates on the **validation** decades, NEVER touching the
  sacred holdout (the latest decade) and requiring no pre-registration. Returns smooth tuning
  metrics (PR-AUC, log-loss) alongside recall@K, plus per-feature coverage and importance, so
  feature/weight variants can be compared without spending the holdout.

  Promotion of a validated winner to an active model stays the separate `train(save: true)` path.

  ## Options
    * `:granularity` — `:data_point` (default) or `:lens`
    * `:sample_ratio` — negative undersampling ratio (default 5)
    * `:min_val_positives` — pool validation decades until ≥ this many positives (default 30)
  """
  def run_experiment(source_key, opts \\ []) do
    granularity = Keyword.get(opts, :granularity, :data_point)
    ratio = Keyword.get(opts, :sample_ratio, 5)
    seed = Keyword.get(opts, :seed, 1337)
    features = Keyword.get(opts, :features, :all)
    codes = if granularity == :data_point, do: resolve_codes(source_key, features)

    cond do
      granularity == :data_point and codes == [] ->
        {:error, :no_data_point_features}

      true ->
        # Seed the undersample shuffles so sweep variants are compared on the same negative draw.
        :rand.seed(:exsss, {seed, seed, seed})
        decades = HistoricalValidator.get_all_decades(source_key) |> Enum.sort()

        case split_train_val_holdout(source_key, decades, opts) do
          {:error, reason} ->
            {:error, reason}

          {train_decades, val_decades, holdout_decades} ->
            Logger.info(
              "Trainer(experiment): #{granularity}/#{source_key} features=#{inspect(features)} " <>
                "train #{inspect(train_decades)} val #{inspect(val_decades)} " <>
                "(holdout #{inspect(holdout_decades)} UNTOUCHED)"
            )

            labeled = labeled_from_decades(source_key, train_decades)

            {weights, feature_set, names} =
              fit_weights(granularity, source_key, labeled, ratio, codes)

            spec = {granularity, stringify(weights), source_key}

            report = Credibility.evaluate(spec, source_key, val_decades)
            pairs = report["pairs"] || []
            {scores, labels} = if pairs == [], do: {[], []}, else: Enum.unzip(pairs)

            # Smooth tuning metrics. PR-AUC is rank-based (no calibration). Log-loss needs
            # probabilities, so fit Platt on the validation pairs and apply — in-sample, but
            # computed identically across experiments, so it is a consistent relative metric.
            calib = ProbabilityCalibration.fit(scores, labels)
            probs = Enum.map(scores, &ProbabilityCalibration.apply_calibration(calib, &1))

            {:ok,
             %{
               source_key: source_key,
               granularity: to_string(granularity),
               features: features,
               sample_ratio: ratio,
               seed: seed,
               backtest_strategy: "temporal-validation",
               train_decades: train_decades,
               validation_decades: val_decades,
               holdout_decades: holdout_decades,
               weights: stringify(weights),
               feature_set: feature_set,
               calibration: calib["method"],
               metrics: %{
                 "recall_at_k" => report["recall_at_k"],
                 "precision_at_k" => report["precision_at_k"],
                 "pr_auc" => Credibility.pr_auc(scores, labels),
                 "log_loss" => Credibility.log_loss(probs, labels),
                 "n_positives" => report["n_positives"],
                 "n_evaluated" => report["n_evaluated"],
                 "baselines" => report["baselines"]
               },
               feature_coverage: feature_coverage(granularity, source_key, val_decades, names),
               feature_importance: stringify(weights)
             }}
        end
    end
  end

  @doc """
  Run several experiment variants and return them ranked by validation PR-AUC (#1040 Session 3).

  `variants` is a list of keyword lists merged onto `opts` (e.g. `[[features: :raw], [features: :all]]`).
  Runs concurrently under `Task.async_stream` bounded by `:max_concurrency` (default 4) — this is the
  loop that exploits the box's cores to search the surface area. Each variant is holdout-free.
  """
  def run_sweep(source_key, variants, opts \\ []) do
    max_conc = Keyword.get(opts, :max_concurrency, 4)

    variants
    |> Task.async_stream(
      fn variant -> {variant, run_experiment(source_key, Keyword.merge(opts, variant))} end,
      max_concurrency: max_conc,
      timeout: :timer.minutes(15),
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, {variant, {:ok, result}}} -> [Map.put(result, :variant, variant)]
      {:ok, {_variant, {:error, _}}} -> []
      {:exit, _} -> []
    end)
    |> Enum.sort_by(&(&1.metrics["pr_auc"] || -1.0), :desc)
  end

  # Map a feature-set selector to data-point codes. `data_point_codes/1` is raw+derived minus target.
  defp resolve_codes(source_key, :all), do: data_point_codes(source_key)

  defp resolve_codes(source_key, :raw),
    do: data_point_codes(source_key) -- DerivedFeatures.supported_codes()

  defp resolve_codes(source_key, :derived),
    do: Enum.filter(data_point_codes(source_key), &(&1 in DerivedFeatures.supported_codes()))

  defp resolve_codes(_source_key, codes) when is_list(codes), do: codes

  # Three-way temporal split (#1040): sacred holdout = latest decade (NEVER returned for use here);
  # validation = decades just before it, pooled until ≥ min positives; train = the rest. Needs ≥3
  # decades so train and validation are both non-empty with the holdout reserved.
  @default_min_val_positives 30

  def split_train_val_holdout(source_key, decades, opts \\ []) do
    min_pos = Keyword.get(opts, :min_val_positives, @default_min_val_positives)
    split_decades(decades, member_counts_by_decade(source_key), min_pos)
  end

  @doc """
  Pure 3-way split given per-decade member `counts` (DB-free, for testing): holdout = last decade,
  validation = decades just before it pooled until ≥ `min_pos` positives, train = the rest. Returns
  `{train, validation, holdout}` or `{:error, :insufficient_decades}` (needs ≥ 3 decades).
  """
  def split_decades(decades, counts, min_pos) when length(decades) >= 3 do
    holdout = [List.last(decades)]
    rest = Enum.drop(decades, -1)
    {val, train} = pool_validation(rest, counts, min_pos)
    if train == [], do: {:error, :insufficient_decades}, else: {train, val, holdout}
  end

  def split_decades(_decades, _counts, _min_pos), do: {:error, :insufficient_decades}

  # Walk `rest` from its latest decade backward, moving decades into validation until they hold
  # ≥ min_pos positives — but always leave ≥1 decade for training.
  defp pool_validation(rest, counts, min_pos) do
    {val_rev, _acc, _remaining} =
      rest
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0, length(rest)}, fn d, {val, acc, remaining} ->
        cond do
          remaining <= 1 -> {:halt, {val, acc, remaining}}
          acc >= min_pos -> {:halt, {val, acc, remaining}}
          true -> {:cont, {[d | val], acc + Map.get(counts, d, 0), remaining - 1}}
        end
      end)

    val = Enum.sort(val_rev)
    {val, rest -- val}
  end

  defp member_counts_by_decade(source_key) do
    Repo.all(
      from m in Movie,
        where: fragment("? \\? ?", m.canonical_sources, ^source_key),
        where: not is_nil(m.release_date),
        group_by: fragment("FLOOR(EXTRACT(YEAR FROM ?) / 10) * 10", m.release_date),
        select: {fragment("FLOOR(EXTRACT(YEAR FROM ?) / 10) * 10", m.release_date), count(m.id)}
    )
    |> Map.new(fn {d, c} -> {to_decade_int(d), c} end)
  end

  defp to_decade_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_decade_int(n) when is_number(n), do: trunc(n)

  # Per-feature coverage over the evaluated (validation) set: fraction of movies with a nonzero
  # value for each code. Lens features are always present, so coverage only applies to data_point.
  defp feature_coverage(:data_point, source_key, val_decades, codes) do
    movies = Enum.flat_map(val_decades, &decade_movie_structs/1)
    feats = DataPointFeatures.load_for(movies, codes, source_key)
    n = length(movies)

    if n == 0 do
      %{}
    else
      Map.new(codes, fn code ->
        nonzero =
          Enum.count(movies, fn m -> (get_in(feats, [m.id, code]) || 0.0) != 0.0 end)

        {code, Float.round(nonzero / n, 4)}
      end)
    end
  end

  defp feature_coverage(_granularity, _source_key, _val_decades, _codes), do: %{}

  # ── temporal: train on all-but-the-latest decade, score the latest as the sacred holdout ──

  defp evaluate_temporal(granularity, source_key, ratio) do
    decades = HistoricalValidator.get_all_decades(source_key) |> Enum.sort()

    case split_holdout(decades) do
      {:error, reason} ->
        {:error, reason}

      {train_decades, holdout_decades} ->
        Logger.info(
          "Trainer(temporal): #{granularity}/#{source_key} train #{inspect(train_decades)} holdout #{inspect(holdout_decades)}"
        )

        labeled = labeled_from_decades(source_key, train_decades)
        {weights, feature_set, names} = fit_weights(granularity, source_key, labeled, ratio)
        spec = {granularity, stringify(weights), source_key}

        report =
          Credibility.evaluate(spec, source_key, holdout_decades)
          |> Map.merge(%{"train_decades" => train_decades, "holdout_decades" => holdout_decades})

        {:ok, %{weights: weights, feature_set: feature_set, feature_names: names, report: report}}
    end
  end

  # Sacred holdout = the latest decade; train on the rest.
  defp split_holdout(decades) when length(decades) >= 2,
    do: {Enum.drop(decades, -1), [List.last(decades)]}

  defp split_holdout(_), do: {:error, :insufficient_decades}

  defp labeled_from_decades(source_key, decades) do
    Enum.flat_map(decades, fn d ->
      Repo.all(Cinegraph.Movies.decade_movies_query(d), timeout: :timer.seconds(120))
      |> Enum.map(&{&1.id, label(&1, source_key)})
    end)
  end

  # ── static: seeded k-fold over members against a pinned candidate universe ──

  @default_k 5

  defp evaluate_static(granularity, source_key, ratio, opts) do
    seed = Keyword.get(opts, :seed, 20_260_603)
    k = Keyword.get(opts, :k, @default_k)
    :rand.seed(:exsss, {seed, seed, seed})

    {members, negs} = candidate_universe(source_key, opts)

    cond do
      length(members) < k ->
        {:error, :insufficient_members}

      negs == [] ->
        {:error, :empty_candidate_universe}

      true ->
        Logger.info(
          "Trainer(static): #{granularity}/#{source_key} #{length(members)} members, #{length(negs)} negatives, #{k}-fold (seed #{seed})"
        )

        neg_train = Enum.map(negs, &{&1.id, 0})
        neg_eval = Enum.map(negs, &{&1, 0})
        member_by_id = Map.new(members, &{&1.id, &1})
        folds = kfold(Enum.map(members, & &1.id), k)

        fold_results =
          Enum.map(folds, fn {train_ids, test_ids} ->
            {weights, _, _} =
              fit_weights(
                granularity,
                source_key,
                Enum.map(train_ids, &{&1, 1}) ++ neg_train,
                ratio
              )

            eval = Enum.map(test_ids, &{member_by_id[&1], 1}) ++ neg_eval

            scored =
              Credibility.score_labeled({granularity, stringify(weights), source_key}, eval)

            %{rp: Credibility.recall_precision_at_k(scored), scored: scored, n: length(test_ids)}
          end)

        all_scored = Enum.flat_map(fold_results, & &1.scored)

        hits =
          Enum.sum(Enum.map(fold_results, fn r -> round((r.rp["recall_at_k"] || 0.0) * r.n) end))

        total = Enum.sum(Enum.map(fold_results, & &1.n))
        pooled = if total > 0, do: Float.round(hits / total, 4), else: nil

        # Final model for serving: fit on the full membership + negatives.
        {weights, feature_set, names} =
          fit_weights(granularity, source_key, Enum.map(members, &{&1.id, 1}) ++ neg_train, ratio)

        report = %{
          "recall_at_k" => pooled,
          "precision_at_k" => pooled,
          "n_positives" => length(members),
          "n_evaluated" => length(members) + length(negs),
          "k_folds" => k,
          "seed" => seed,
          "by_fold" =>
            Enum.map(fold_results, fn r -> %{"recall_at_k" => r.rp["recall_at_k"], "n" => r.n} end),
          "worst_miss" => Credibility.worst_miss(all_scored),
          "baselines" => static_baselines(source_key, members, negs),
          "pairs" => Enum.map(all_scored, fn s -> {s.score, s.label} end)
        }

        {:ok, %{weights: weights, feature_set: feature_set, feature_names: names, report: report}}
    end
  end

  # Pinned universe: list members (positives) + the most-voted non-members (the strongest
  # competitors), min-evidence gated + capped. Deterministic (votes-desc order); the only
  # randomness is the seeded fold split + negative undersampling.
  defp candidate_universe(source_key, opts) do
    min_votes = Keyword.get(opts, :min_votes, 1000)

    members =
      Repo.all(
        from m in Movie,
          where: fragment("? \\? ?", m.canonical_sources, ^source_key),
          where: m.import_status == "full",
          select: %Movie{
            id: m.id,
            title: m.title,
            release_date: m.release_date,
            canonical_sources: m.canonical_sources
          }
      )

    cap = Keyword.get(opts, :universe_cap, max(5000, length(members) * 25))

    negs =
      Repo.all(
        from(m in Movie,
          join: em in "external_metrics",
          on:
            em.movie_id == m.id and em.source == "tmdb" and em.metric_type == "rating_votes" and
              em.value >= ^min_votes,
          where: m.import_status == "full",
          where: not fragment("? \\? ?", m.canonical_sources, ^source_key),
          # asc: m.id breaks vote-count ties deterministically (so the universe is reproducible)
          order_by: [desc: em.value, asc: m.id],
          limit: ^cap,
          select: %Movie{
            id: m.id,
            title: m.title,
            release_date: m.release_date,
            canonical_sources: m.canonical_sources
          }
        ),
        timeout: :timer.seconds(120)
      )

    {members, negs}
  end

  defp static_baselines(source_key, members, negs) do
    universe = Enum.map(members, &{&1, 1}) ++ Enum.map(negs, &{&1, 0})
    pop_spec = {:data_point, %{"tmdb_popularity_score" => 1.0}, source_key}

    pop =
      Credibility.recall_precision_at_k(Credibility.score_labeled(pop_spec, universe))[
        "recall_at_k"
      ]

    rand_scored =
      Enum.map(universe, fn {m, l} ->
        %{movie_id: m.id, title: m.title, score: :rand.uniform(), label: l}
      end)

    rand = Credibility.recall_precision_at_k(rand_scored)["recall_at_k"]
    total = length(members) + length(negs)

    %{
      "popularity" => pop,
      "random" => rand,
      "prior_rate" => if(total > 0, do: Float.round(length(members) / total, 4), else: nil)
    }
  end

  defp kfold(ids, k) do
    chunks = chunk_into(Enum.shuffle(ids), k)

    Enum.map(0..(k - 1), fn i ->
      {chunks |> List.delete_at(i) |> List.flatten(), Enum.at(chunks, i)}
    end)
  end

  defp chunk_into(list, k) do
    n = length(list)
    size = div(n, k)
    extra = rem(n, k)

    {chunks, _} =
      Enum.reduce(0..(k - 1), {[], list}, fn i, {acc, remaining} ->
        {chunk, rest} = Enum.split(remaining, size + if(i < extra, do: 1, else: 0))
        {[chunk | acc], rest}
      end)

    Enum.reverse(chunks)
  end

  # ── fitting (shared by temporal + static) ──

  # `codes` (#1040 S3) lets a sweep restrict the data-point feature set; nil ⇒ the full default set.
  defp fit_weights(granularity, source_key, labeled, ratio, codes \\ nil)

  defp fit_weights(:data_point, source_key, labeled, ratio, codes) do
    codes = codes || data_point_codes(source_key)
    kept = undersample_ids(labeled, ratio)
    ids = Enum.map(kept, &elem(&1, 0))
    # Derived features need movie structs (canonical_sources / tmdb_data / release_date), so load
    # them for the (small, undersampled) kept set and assemble via the shared load_for path.
    feats = DataPointFeatures.load_for(load_movie_structs(ids), codes, source_key)
    x = Enum.map(kept, fn {id, _y} -> vectorize(Map.get(feats, id, %{}), codes) end)
    y = Enum.map(kept, &elem(&1, 1))
    weights = WeightOptimizer.fit_raw(x, y) |> WeightOptimizer.extract_weights(codes)
    {weights, %{"granularity" => "data_point", "features" => codes}, codes}
  end

  defp fit_weights(:lens, source_key, labeled, ratio, _codes) do
    kept = undersample_ids(labeled, ratio)
    preds = lens_predictions(Enum.map(kept, &elem(&1, 0)), source_key)

    rows =
      Enum.map(kept, fn {id, lbl} ->
        feats =
          case preds[id] do
            nil -> List.duplicate(0.0, length(@lens_criteria))
            p -> Enum.map(@lens_criteria, &((p.criteria_scores[&1] || 0.0) / 100.0))
          end

        {feats, lbl}
      end)

    weights =
      WeightOptimizer.fit_raw(Enum.map(rows, &elem(&1, 0)), Enum.map(rows, &elem(&1, 1)))
      |> WeightOptimizer.extract_weights(@lens_criteria)

    names = Enum.map(@lens_criteria, &to_string/1)
    {weights, %{"granularity" => "lens", "features" => names}, names}
  end

  defp lens_predictions(ids, source_key) do
    from(m in Movie,
      where: m.id in ^ids,
      select: %Movie{
        id: m.id,
        canonical_sources: m.canonical_sources
      }
    )
    |> Repo.all()
    |> LensScoring.batch_score_movies(@default_weights, source_key)
    |> Map.new(fn %{movie: m, prediction: p} -> {m.id, p} end)
  end

  defp undersample_ids(labeled, ratio) do
    {pos, neg} = Enum.split_with(labeled, fn {_id, y} -> y == 1 end)
    if pos == [], do: raise("no positive labels for training — none are members")
    n_keep = min(length(pos) * ratio, length(neg))
    Enum.shuffle(pos ++ Enum.take(Enum.shuffle(neg), n_keep))
  end

  defp vectorize(vec, codes), do: Enum.map(codes, fn code -> vec[code] || 0.0 end)

  defp decade_movie_structs(decade),
    do: Repo.all(Cinegraph.Movies.decade_movies_query(decade), timeout: :timer.seconds(120))

  # Movie structs (with the fields DerivedFeatures needs) for an explicit id set — same select
  # shape as `decade_movies_query`, so the feature assembly matches the training/eval path.
  defp load_movie_structs([]), do: []

  defp load_movie_structs(ids) do
    query =
      from m in Movie,
        where: m.id in ^ids,
        select: %Movie{
          id: m.id,
          title: m.title,
          release_date: m.release_date,
          canonical_sources: m.canonical_sources,
          tmdb_data:
            fragment(
              "jsonb_build_object('budget', ?->'budget', 'revenue', ?->'revenue')",
              m.tmdb_data,
              m.tmdb_data
            )
        }

    Repo.all(query, timeout: :timer.seconds(120))
  end

  @doc """
  Data-point feature codes for a list (#1040): the raw, cleanly-normalized catalog codes
  (excludes `custom` normalizations that yield NULL in the view) PLUS the derived canon-taste
  codes `DerivedFeatures` emits — MINUS the target list's own code (leakage: a model predicting
  `L` must not see membership in `L`).

  `canonical_contribution` stays IN despite being "about" canonical membership: it is
  leakage-stripped (the target list is removed before counting), which is exactly its value.
  """
  def data_point_codes(source_key) do
    raw =
      Metrics.list_metric_definitions(only_available: true, kind: "raw")
      |> Enum.reject(&(&1.normalization_type == "custom"))
      |> Enum.map(& &1.code)

    (raw ++ DerivedFeatures.supported_codes())
    |> Enum.reject(&(&1 == source_key))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp label(movie, source_key) do
    if Map.has_key?(movie.canonical_sources || %{}, source_key), do: 1, else: 0
  end

  # ── verdict ──────────────────────────────────────────────────────────────────

  defp verdict(integrity, prereg) do
    recall = integrity["recall_at_k"]
    pop = get_in(integrity, ["baselines", "popularity"])
    threshold = prereg && PreRegistration.threshold_value(prereg)

    beats_baseline = is_number(recall) and is_number(pop) and recall > pop
    clears_threshold = is_nil(threshold) or (is_number(recall) and recall >= threshold)

    %{
      "passed" => beats_baseline and clears_threshold,
      "beats_popularity" => beats_baseline,
      "clears_failure_threshold" => clears_threshold,
      "recall_at_k" => recall,
      "popularity_baseline" => pop,
      "failure_threshold" => threshold
    }
  end

  # ── persistence ──────────────────────────────────────────────────────────────

  defp persist(source_key, weights, feature_set, integrity, calibration, prereg, strategy) do
    string_weights = stringify(weights)
    lens_config_hash = if feature_set["granularity"] == "lens", do: LensConfig.lens_config_hash()
    model_version = 1

    weights_hash =
      LensConfig.weights_hash(feature_set, string_weights, model_version, lens_config_hash)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      model =
        %Model{}
        |> Model.changeset(%{
          source_key: source_key,
          feature_set: feature_set,
          weights: string_weights,
          weights_hash: weights_hash,
          model_version: model_version,
          lens_config_hash: lens_config_hash,
          backtest_strategy: strategy,
          metrics: Map.take(integrity, ["recall_at_k", "precision_at_k", "brier"]),
          integrity_report: integrity,
          calibration: calibration,
          holdout_spent_at: now,
          prereg_id: prereg.id
        })
        |> Repo.insert(
          on_conflict:
            {:replace,
             [
               :metrics,
               :integrity_report,
               :calibration,
               :holdout_spent_at,
               :prereg_id,
               :feature_set,
               :lens_config_hash,
               :updated_at
             ]},
          conflict_target: [:source_key, :weights_hash, :model_version, :prereg_id],
          returning: true
        )
        |> case do
          {:ok, model} -> model
          {:error, changeset} -> Repo.rollback(changeset)
        end

      case MovieLists.set_active_prediction_model(source_key, model.id, string_weights) do
        {:ok, _list} -> model
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp stringify(weights), do: Map.new(weights, fn {k, v} -> {to_string(k), v} end)
end
