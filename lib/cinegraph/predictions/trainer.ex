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

  Validation is scored against the **full decade pool** over the validation decades (#1055):
  members are ranked against EVERY movie in those decades (base rate ~1e-4), via
  `Credibility.evaluate/3`. Curated negative sets (the #1045 vote-gated/era-stratified universes)
  are selection-biased and gameable — a flexible model trivially separates arthouse canon from
  the curated competitors — so the honest metric ranks against everything. Training negatives are
  still undersampled from the train decades; only the *evaluation* uses the full pool.

  Promotion of a validated winner to an active model stays the separate `train(save: true)` path.

  ## Options
    * `:granularity` — `:data_point` (default) or `:lens`
    * `:sample_ratio` — negative undersampling ratio for training (default 5)
    * `:min_val_positives` — pool validation decades until ≥ this many positives (default 30)
    * `:weight_normalize` — `:simplex` (default) or `:signed`; `:alpha` — L2 strength (#1051 Stage B)
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
              fit_weights(granularity, source_key, labeled, ratio, codes, opts)

            spec = {granularity, stringify(weights), source_key}

            # Honest evaluation (#1055): rank members against the FULL decade pool over the
            # validation decades — `Credibility.evaluate` scores the whole decade(s) (base rate
            # ~1e-4), with no curated/selection-biased negatives that a flexible model could game.
            # `:sample` (iteration fast-mode) ranks members against all members + a seeded
            # non-member sample; defaults to 0 = full pool. The promotion path never sets it.
            report =
              Credibility.evaluate(spec, source_key, val_decades,
                seed: seed,
                sample: Keyword.get(opts, :sample, 0)
              )

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
               # Honest denominator (#1055): the FULL decade pool, not a curated negative set.
               # `n_evaluated` (above) = every movie in the validation decades.
               validation_universe: %{
                 "pool" => "full_decade",
                 "positives" => report["n_positives"],
                 "evaluated" => report["n_evaluated"]
               },
               feature_coverage:
                 feature_coverage(
                   granularity,
                   val_decade_members(source_key, val_decades),
                   source_key,
                   names
                 ),
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

    # Each variant evaluates against the full decade pool (#1055), so there is no shared curated
    # universe to prebuild — variants differ only in features/weight_normalize/alpha.
    variants
    |> Task.async_stream(
      fn variant -> {variant, run_experiment(source_key, Keyword.merge(opts, variant))} end,
      max_concurrency: max_conc,
      timeout: :timer.minutes(15),
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, {variant, {:ok, result}}} ->
        [Map.put(result, :variant, variant)]

      # Drop failures from the ranking, but log them — a silently-vanished variant could hide a
      # regression and bias the ranked output.
      {:ok, {variant, {:error, reason}}} ->
        Logger.warning("Trainer(sweep): variant #{inspect(variant)} failed: #{inspect(reason)}")
        []

      {:exit, reason} ->
        Logger.warning("Trainer(sweep): variant worker exited: #{inspect(reason)}")
        []
    end)
    |> Enum.sort_by(&(&1.metrics["pr_auc"] || -1.0), :desc)
  end

  @doc """
  Holdout-free evaluation of ONE backtest strategy, for the Stage C strategy auto-pick (#1051).

  Spends no sacred holdout and persists nothing: `"temporal"` uses the validation tier
  (`run_experiment`, holdout untouched); `"static"` uses the deterministic seeded member holdout
  (`evaluate_static`). Returns `{:ok, %{report, calibration}}` where `report` carries
  `recall_at_k`/`n_positives`/`n_evaluated`/`baselines` (calibration-grading shape, no `pairs`),
  or `{:error, reason}` when the strategy's split is invalid for this list. Pass `:sample` to
  speed up iteration (approximate); omit it for an exact projection.
  """
  def evaluate_strategy(source_key, strategy, opts \\ [])

  def evaluate_strategy(source_key, "static", opts) do
    ratio = Keyword.get(opts, :sample_ratio, 5)

    with {:ok, %{report: report}} <- evaluate_static(:data_point, source_key, ratio, opts) do
      pairs = report["pairs"] || []
      {scores, labels} = if pairs == [], do: {[], []}, else: Enum.unzip(pairs)

      {:ok,
       %{
         report: Map.delete(report, "pairs"),
         calibration: ProbabilityCalibration.fit(scores, labels)
       }}
    end
  end

  def evaluate_strategy(source_key, "temporal", opts) do
    case run_experiment(source_key, Keyword.put(opts, :granularity, :data_point)) do
      {:ok, result} ->
        report = %{
          "recall_at_k" => result.metrics["recall_at_k"],
          "precision_at_k" => result.metrics["precision_at_k"],
          "n_positives" => result.metrics["n_positives"],
          "n_evaluated" => result.metrics["n_evaluated"],
          "baselines" => result.metrics["baselines"]
        }

        {:ok, %{report: report, calibration: %{"method" => result.calibration}}}

      err ->
        err
    end
  end

  # List members in the validation decades (structs), for the experiment's per-feature coverage
  # diagnostic. The honest recall is computed over the full decade pool by `Credibility.evaluate`.
  defp val_decade_members(source_key, decades) do
    from(m in Movie,
      where: fragment("? \\? ?", m.canonical_sources, ^source_key),
      where: m.import_status == "full",
      select: %Movie{
        id: m.id,
        title: m.title,
        release_date: m.release_date,
        canonical_sources: m.canonical_sources
      }
    )
    |> maybe_decade_filter(decades)
    |> Repo.all()
  end

  # Map a feature-set selector to data-point codes. `data_point_codes/1` is raw+derived minus target.
  defp resolve_codes(source_key, :all), do: data_point_codes(source_key)

  defp resolve_codes(source_key, :raw),
    do: data_point_codes(source_key) -- DerivedFeatures.supported_codes()

  defp resolve_codes(source_key, :derived),
    do: Enum.filter(data_point_codes(source_key), &(&1 in DerivedFeatures.supported_codes()))

  # The two ablation buckets (#1051 A4/C). `objective_only` = the surface MINUS the canon-overlap
  # crutch (other lists' membership + canonical_contribution + auteur_track_record + list_appearances);
  # it's the honest "independent signal" set. `canon_overlap` is that crutch alone.
  defp resolve_codes(source_key, :canon_overlap),
    do: Enum.filter(data_point_codes(source_key), &(&1 in canon_overlap_codes(source_key)))

  defp resolve_codes(source_key, :objective_only),
    do: data_point_codes(source_key) -- canon_overlap_codes(source_key)

  defp resolve_codes(_source_key, codes) when is_list(codes), do: codes

  @canon_derived_codes ~w(canonical_contribution auteur_track_record list_appearances)

  @doc """
  The canon-overlap codes for a target (#1051): every OTHER canonical list's membership code
  (`source_key` columns in `movie_lists`, the target excluded) plus the derived canon features
  (`canonical_contribution`, `auteur_track_record`, `list_appearances`). These encode "already
  canonized elsewhere" — real but circular signal; the ablation measures the surface without them.
  """
  def canon_overlap_codes(source_key) do
    list_codes =
      Repo.all(from l in "movie_lists", where: not is_nil(l.source_key), select: l.source_key)

    ((list_codes -- [source_key]) ++ @canon_derived_codes) |> Enum.uniq()
  end

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

  # Per-feature coverage over the evaluated (candidate-universe) set: fraction of movies with a
  # nonzero value for each code. Lens features are always present, so coverage only applies to
  # data_point. `movies` is the already-loaded universe (members ++ negatives) — reusing it keeps
  # this cheap and consistent with what was actually scored.
  defp feature_coverage(:data_point, movies, source_key, codes) do
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

  defp feature_coverage(_granularity, _movies, _source_key, _codes), do: %{}

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

  # ── static: full-pool eval with a seeded member holdout (#1055) ──
  #
  # Static lists lack temporal spread, so we can't reserve a holdout decade. Instead hold out a
  # random fraction of MEMBERS, train on the rest + undersampled non-members, and rank the held-out
  # members against the FULL pool of the list's member-decades (every eligible film in those decades,
  # base rate ~1e-4) — the honest, un-gameable metric. Trained members are excluded from the eval
  # pool (no leakage). Replaces the curated vote-gated k-fold, which a flexible model could game.
  @default_holdout_fraction 0.25

  defp evaluate_static(granularity, source_key, ratio, opts) do
    seed = Keyword.get(opts, :seed, 20_260_603)
    frac = Keyword.get(opts, :holdout_fraction, @default_holdout_fraction)
    :rand.seed(:exsss, {seed, seed, seed})

    members = member_structs(source_key)
    decades = member_decades(members)

    if length(members) < 4 or decades == [] do
      {:error, :insufficient_members}
    else
      member_id_set = MapSet.new(members, & &1.id)

      non_members =
        decade_pool_structs(decades)
        |> Enum.reject(&MapSet.member?(member_id_set, &1.id))
        # `:sample` (iteration fast-mode) caps the non-member pool via the seed set above. 0 = full
        # pool (exact) — the promotion path passes no sample, so promoted grades stay exact.
        |> maybe_sample_nonmembers(Keyword.get(opts, :sample, 0))

      if non_members == [] do
        {:error, :empty_candidate_universe}
      else
        n_test = max(1, round(length(members) * frac))
        {test_members, train_members} = members |> Enum.shuffle() |> Enum.split(n_test)

        Logger.info(
          "Trainer(static): #{granularity}/#{source_key} #{length(members)} members " <>
            "(#{length(test_members)} held out), full pool #{length(non_members)} non-members " <>
            "over decades #{inspect(decades)} (seed #{seed})"
        )

        neg_labeled = Enum.map(non_members, &{&1.id, 0})

        # Eval model — trained WITHOUT the held-out members; scored on the full pool.
        {weights, _, _} =
          fit_weights(
            granularity,
            source_key,
            Enum.map(train_members, &{&1.id, 1}) ++ neg_labeled,
            ratio,
            nil,
            opts
          )

        eval = Enum.map(test_members, &{&1, 1}) ++ Enum.map(non_members, &{&1, 0})
        scored = Credibility.score_labeled({granularity, stringify(weights), source_key}, eval)
        rp = Credibility.recall_precision_at_k(scored)

        # Serving model — fit on ALL members + undersampled non-members.
        {fweights, feature_set, names} =
          fit_weights(
            granularity,
            source_key,
            Enum.map(members, &{&1.id, 1}) ++ neg_labeled,
            ratio,
            nil,
            opts
          )

        report = %{
          "recall_at_k" => rp["recall_at_k"],
          "precision_at_k" => rp["precision_at_k"],
          "n_positives" => rp["n_positives"],
          "n_evaluated" => length(eval),
          "seed" => seed,
          "holdout_fraction" => frac,
          "worst_miss" => Credibility.worst_miss(scored),
          "baselines" => static_baselines(source_key, test_members, non_members),
          "pairs" => Enum.map(scored, fn s -> {s.score, s.label} end)
        }

        {:ok,
         %{weights: fweights, feature_set: feature_set, feature_names: names, report: report}}
      end
    end
  end

  # Uses the :rand stream already seeded at the top of evaluate_static, so it's deterministic.
  defp maybe_sample_nonmembers(nm, sample) when sample in [nil, 0], do: nm
  defp maybe_sample_nonmembers(nm, sample) when length(nm) <= sample, do: nm
  defp maybe_sample_nonmembers(nm, sample), do: Enum.take(Enum.shuffle(nm), sample)

  defp member_structs(source_key) do
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
  end

  defp member_decades(members) do
    members
    |> Enum.reduce([], fn
      %{release_date: %Date{year: y}}, acc -> [div(y, 10) * 10 | acc]
      _, acc -> acc
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp decade_pool_structs(decades) do
    Enum.flat_map(decades, fn d ->
      Repo.all(Cinegraph.Movies.decade_movies_query(d), timeout: :timer.seconds(120))
    end)
  end

  defp maybe_decade_filter(query, nil), do: query

  defp maybe_decade_filter(query, decades),
    do: from(q in query, where: ^decade_date_filter(decades))

  # Sargable OR of per-decade date ranges over `release_date` (matches `decade_movies_query/1`),
  # correct for any decade set rather than assuming contiguity.
  defp decade_date_filter(decades) do
    Enum.reduce(decades, dynamic(false), fn d, acc ->
      s = Date.new!(d, 1, 1)
      e = Date.new!(d + 9, 12, 31)
      dynamic([m], ^acc or (m.release_date >= ^s and m.release_date <= ^e))
    end)
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

  # ── fitting (shared by temporal + static) ──

  # `codes` (#1040 S3) lets a sweep restrict the data-point feature set; nil ⇒ the full default set.
  # `opts` (#1051 Stage B) carries `:alpha` (L2) + `:weight_normalize` (:simplex|:signed) for the
  # data-point fit; the lens path ignores them (keeps its byte-stable :simplex behavior).
  defp fit_weights(granularity, source_key, labeled, ratio, codes \\ nil, opts \\ [])

  defp fit_weights(:data_point, source_key, labeled, ratio, codes, opts) do
    codes = codes || data_point_codes(source_key)
    kept = undersample_ids(labeled, ratio)
    ids = Enum.map(kept, &elem(&1, 0))
    # Derived features need movie structs (canonical_sources / release_date), so load them for the
    # (small, undersampled) kept set and assemble via the shared load_for path.
    feats = DataPointFeatures.load_for(load_movie_structs(ids), codes, source_key)
    x = Enum.map(kept, fn {id, _y} -> vectorize(Map.get(feats, id, %{}), codes) end)
    y = Enum.map(kept, &elem(&1, 1))

    fit_opts = Keyword.take(opts, [:alpha, :max_iterations])
    normalize = Keyword.get(opts, :weight_normalize, :simplex)

    weights =
      WeightOptimizer.fit_raw(x, y, fit_opts)
      |> WeightOptimizer.extract_weights(codes, normalize: normalize)

    {weights, %{"granularity" => "data_point", "features" => codes}, codes}
  end

  defp fit_weights(:lens, source_key, labeled, ratio, _codes, _opts) do
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

  # Movie structs (with the fields DerivedFeatures needs) for an explicit id set — same select
  # shape as `decade_movies_query`, so the feature assembly matches the training/eval path. Derived
  # financials (budget/revenue) resolve from `external_metrics` via `FeatureResolver` (#1042), so
  # the `tmdb_data` blob is intentionally not read here.
  defp load_movie_structs([]), do: []

  defp load_movie_structs(ids) do
    query =
      from m in Movie,
        where: m.id in ^ids,
        select: %Movie{
          id: m.id,
          title: m.title,
          release_date: m.release_date,
          canonical_sources: m.canonical_sources
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

    # Derived codes are gated by catalog availability too (#1051 A4): a derived feature catalogued
    # `is_available: false` (e.g. a not-yet-vetted missingness indicator) must not enter the default
    # feature set. Intersect available-derived with what DerivedFeatures can actually emit.
    available_derived =
      Metrics.list_metric_definitions(only_available: true, kind: "derived")
      |> Enum.map(& &1.code)
      |> Enum.filter(&(&1 in DerivedFeatures.supported_codes()))

    (raw ++ available_derived)
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
        {:ok, _list} ->
          model

        {:error, {:insufficient_reliability, _}} ->
          # Honest-failure path (#1051 Stage 0): the model is still SAVED as a record of
          # the attempt, but it must not become the serving pointer. Don't roll back —
          # just leave the list's active model unchanged and warn.
          Logger.warning(
            "Trainer: #{source_key} model #{model.id} graded :insufficient — saved but NOT activated"
          )

          model

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp stringify(weights), do: Map.new(weights, fn {k, v} -> {to_string(k), v} end)
end
