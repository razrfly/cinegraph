defmodule Cinegraph.Predictions.WeightOptimizer do
  @moduledoc """
  Learns optimal prediction weights for a given movie list via logistic regression.

  Uses Scholar.Linear.LogisticRegression on the 6 lens scores
  (mob, critics, festival_recognition, time_machine, auteurs, box_office) as
  features and list membership as the binary label.

  ## Usage

      WeightOptimizer.train("1001_movies")
      # => %{weights: %{...}, trained_accuracy: 61.2, baseline_accuracy: 55.8, ...}

      WeightOptimizer.train("1001_movies", save: true)
      # also persists a prediction_models artifact, sets movie_lists.active_prediction_model_id,
      # and refreshes the derived movie_lists.trained_weights cache (#1036 Session 2)

  """

  alias Cinegraph.Predictions.{LensScoring, HistoricalValidator}

  require Logger

  @criteria LensScoring.scoring_criteria()

  # Default weights for baseline comparison
  @default_weights LensScoring.get_default_weights()

  @doc """
  Main entry point. Trains logistic regression weights for the given list key.

  ## Options
    * `:sample_ratio` - negatives-to-positives ratio for undersampling (default: 5)
    * (analysis-only: this optimizer no longer persists — use `Cinegraph.Predictions.Trainer`,
      which enforces pre-registration, to train and save an active model)

  Returns a result map with:
    * `:weights` - %{mob: float, critics: float, ...} summing to 1.0
    * `:feature_importance` - [{:criterion, weight}, ...] sorted descending
    * `:baseline_accuracy` - overall accuracy with default weights
    * `:trained_accuracy` - leave-one-decade-out CV accuracy with new weights
    * `:cv_by_decade` - [%{decade: 1930, accuracy: 42.1}, ...]
    * `:timings` - %{data_load_ms: int, model_fit_ms: int, loocv_ms: int, baseline_cv_ms: int}
  """
  def train(source_key, opts \\ []) do
    sample_ratio = Keyword.get(opts, :sample_ratio, 5)
    decades = HistoricalValidator.get_all_decades(source_key)

    # Phase 1: parallel DB — load all decades once
    Logger.info("WeightOptimizer: loading #{length(decades)} decades in parallel")
    {decade_data, load_ms} = timed(fn -> load_decade_data_parallel(source_key, decades) end)

    # Phase 2: assemble full feature matrix from cache
    {x_list, y_list} = assemble_and_undersample(decade_data, decades, sample_ratio)

    n_pos = Enum.count(y_list, &(&1 == 1))
    n_neg = Enum.count(y_list, &(&1 == 0))
    Logger.info("WeightOptimizer: #{n_pos} positives, #{n_neg} negatives")

    # Phase 3: EXLA-accelerated model fit
    Logger.info("WeightOptimizer: fitting logistic regression")
    {weights, fit_ms} = timed(fn -> fit_model(x_list, y_list) end)

    # Phase 4: parallel LOOCV — no DB for training folds, DB only for validation
    Logger.info("WeightOptimizer: running true leave-one-decade-out cross-validation")

    {{trained_accuracy, cv_by_decade}, loocv_ms} =
      timed(fn -> true_loocv_from_cache(source_key, decade_data, decades, sample_ratio) end)

    # Phase 5: parallel baseline CV
    Logger.info("WeightOptimizer: running baseline cross-validation")

    {{baseline_accuracy, _}, baseline_cv_ms} =
      timed(fn -> decade_cross_validate(source_key, @default_weights) end)

    feature_importance =
      weights
      |> Enum.sort_by(fn {_k, v} -> v end, :desc)

    result = %{
      weights: weights,
      feature_importance: feature_importance,
      baseline_accuracy: baseline_accuracy,
      trained_accuracy: trained_accuracy,
      cv_by_decade: cv_by_decade,
      n_positives: n_pos,
      n_negatives: n_neg,
      timings: %{
        data_load_ms: load_ms,
        model_fit_ms: fit_ms,
        loocv_ms: loocv_ms,
        baseline_cv_ms: baseline_cv_ms
      }
    }

    # NOTE: this 6-lens optimizer is now analysis-only. Persisting a model is the integrity
    # protocol's job (`Cinegraph.Predictions.Trainer`, which requires a pre-registration);
    # a `:save` option here is intentionally ignored so no path can write a non-protocol model.
    result
  end

  @doc """
  Build X (feature matrix) and y (labels) from all historical decade data.

  For each decade, loads all movies via HistoricalValidator's slim query,
  scores them with LensScoring.batch_score_movies/3, then undersamples
  negatives at `sample_ratio`:1 relative to positives.

  Returns `{x_list, y_list}` where each element is a list of 6 floats (0.0–1.0)
  and the corresponding 0/1 label.
  """
  def build_feature_matrix(source_key, sample_ratio \\ 5) do
    decades = HistoricalValidator.get_all_decades(source_key)
    decade_data = load_decade_data_parallel(source_key, decades)
    assemble_and_undersample(decade_data, decades, sample_ratio)
  end

  @doc """
  Fit logistic regression on the feature matrix. Returns weight map with atom keys.
  """
  def fit_model(x_list, y_list) do
    x_list |> fit_raw(y_list) |> extract_weights()
  end

  @doc """
  Fit logistic regression and return the raw Scholar model (coefficients intact), so callers
  can extract weights over an arbitrary feature list via `extract_weights/2,3`.

  ## Options (#1051 Stage B)
    * `:alpha` — L2 regularization strength passed to `Scholar.Linear.LogisticRegression`
      (default `1.0`). Higher shrinks all coefficients; lower lets dominant features keep magnitude.
    * `:max_iterations` — gradient-descent iterations (default `1000`).
  """
  def fit_raw(x_list, y_list, opts \\ []) do
    x_tensor = Nx.tensor(x_list, type: :f32)
    y_tensor = Nx.tensor(y_list, type: :u32)

    Scholar.Linear.LogisticRegression.fit(x_tensor, y_tensor,
      num_classes: 2,
      max_iterations: Keyword.get(opts, :max_iterations, 1000),
      alpha: Keyword.get(opts, :alpha, 1.0)
    )
  end

  @doc """
  Evaluates fixed weights per decade (no retraining). Used for baseline comparison.
  Returns {mean_accuracy, cv_by_decade}.
  """
  def decade_cross_validate(source_key, weights) do
    decades = HistoricalValidator.get_all_decades(source_key)
    pool_size = Cinegraph.Repo.config()[:pool_size] || 10

    cv_results =
      Task.async_stream(
        decades,
        fn decade ->
          try do
            result = HistoricalValidator.validate_decade(decade, weights, source_key)
            {:ok, %{decade: decade, accuracy: result.accuracy_percentage}}
          rescue
            e ->
              Logger.warning("WeightOptimizer CV: skipping #{decade}s — #{Exception.message(e)}")
              :skip
          end
        end,
        max_concurrency: max(1, min(length(decades), min(pool_size, 4))),
        timeout: :timer.minutes(5),
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, entry}} ->
          [entry]

        {:ok, :skip} ->
          []

        {:exit, reason} ->
          Logger.warning("WeightOptimizer CV: task exited — #{inspect(reason)}")
          []
      end)

    if cv_results == [] do
      raise "WeightOptimizer CV: all folds failed or were skipped for source_key=#{source_key} — check that movies exist with import_status=\"full\""
    end

    {compute_mean_accuracy(cv_results), cv_results}
  end

  @doc """
  True leave-one-decade-out cross-validation: for each test decade, retrains on all
  other decades, then evaluates on the held-out decade. Returns {mean_accuracy, cv_by_decade}.
  """
  def true_loocv(source_key, sample_ratio \\ 5) do
    decades = HistoricalValidator.get_all_decades(source_key)
    decade_data = load_decade_data_parallel(source_key, decades)
    true_loocv_from_cache(source_key, decade_data, decades, sample_ratio)
  end

  @doc """
  Extract positive-class weights from a fitted model over the 6 lens atoms (`:simplex` strategy).
  """
  def extract_weights(model), do: extract_weights(model, @criteria, [])

  def extract_weights(model, feature_names), do: extract_weights(model, feature_names, [])

  @doc """
  Generalized weight extraction over an arbitrary ordered feature list (atoms or strings,
  e.g. data-point `metric_code`s). Column order MUST match the feature matrix used to fit.

  ## `:normalize` (#1051 Stage B)
    * `:simplex` (default) — clamp negative coefficients to 0, normalize to sum 1.0 (uniform
      `1/n` if all non-positive). The lens path keeps this for back-compat / byte-stability.
    * `:signed` — keep raw signed coefficients, scaled by their L2 norm (zeros if the norm is 0).
      Preserves sign and *relative magnitude*, so a dominant feature isn't diluted by adding many
      weak ones — the fix for the `full < canon` collapse. The bus serves signed weights directly;
      recall@K is rank-invariant and Platt calibration absorbs the scale.
  """
  def extract_weights(model, feature_names, opts) do
    pos_coeffs = model.coefficients[[.., 1]]
    n = length(feature_names)

    weights =
      case Keyword.get(opts, :normalize, :simplex) do
        :signed -> signed_l2_weights(pos_coeffs, n)
        _ -> simplex_weights(pos_coeffs, n)
      end

    feature_names
    |> Enum.zip(weights)
    |> Map.new()
  end

  # clamp ≥0, normalize to sum 1.0 (uniform if degenerate)
  defp simplex_weights(pos_coeffs, n) do
    clamped = Nx.max(pos_coeffs, 0.0)
    total = Nx.sum(clamped) |> Nx.to_number()

    if total > 0.0,
      do: Nx.to_list(Nx.divide(clamped, total)),
      else: List.duplicate(1.0 / n, n)
  end

  # raw signed coefficients scaled by L2 norm (zeros if degenerate)
  defp signed_l2_weights(pos_coeffs, n) do
    norm = Nx.sum(Nx.multiply(pos_coeffs, pos_coeffs)) |> Nx.to_number() |> :math.sqrt()

    if norm > 0.0,
      do: Nx.to_list(Nx.divide(pos_coeffs, norm)),
      else: List.duplicate(0.0, n)
  end

  @doc """
  Random weight sweep: loads decade data once, then evaluates `n_samples` random
  weight vectors entirely in memory (no DB calls per vector). Includes all named
  profiles in the search. Returns results sorted by overall accuracy descending.

  ## Options
    * `:top` - how many results to return (default: 20)

  ## Example

      WeightOptimizer.sweep("1001_movies", 1000)
      # => [%{weights: %{...}, accuracy: 51.2, rank: 1}, ...]

  """
  def sweep(source_key, n_samples \\ 500, opts \\ []) do
    decades = HistoricalValidator.get_all_decades(source_key)
    Logger.info("WeightOptimizer.sweep: loading #{length(decades)} decades")
    {decade_data, load_ms} = timed(fn -> load_decade_data_parallel(source_key, decades) end)

    Logger.info(
      "WeightOptimizer.sweep: data loaded in #{load_ms}ms, evaluating #{n_samples} weight vectors"
    )

    # Named profiles always included
    named_vectors =
      LensScoring.get_named_profiles()
      |> Enum.map(fn p ->
        vec = Enum.map(@criteria, &Map.get(p.weights, &1, 0.0))
        {vec, p.name}
      end)

    # Random vectors on the probability simplex
    random_vectors =
      for _ <- 1..n_samples do
        {random_simplex_point(length(@criteria)), nil}
      end

    n_criteria = length(@criteria)

    {results, eval_ms} =
      timed(fn ->
        (named_vectors ++ random_vectors)
        |> Enum.map(fn {vec, label} ->
          acc = fast_evaluate(vec, decade_data, decades, n_criteria)
          weight_map = @criteria |> Enum.zip(vec) |> Map.new()
          %{weights: weight_map, accuracy: acc, label: label}
        end)
        |> Enum.sort_by(& &1.accuracy, :desc)
      end)

    Logger.info("WeightOptimizer.sweep: #{length(results)} vectors evaluated in #{eval_ms}ms")

    top = Keyword.get(opts, :top, 20)

    top_results =
      Enum.take(results, top)
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} -> Map.put(r, :rank, i) end)

    # Sweep is exploration-only: it ranks weight vectors but never persists. Promoting a
    # vector to an active model must go through the integrity protocol (Trainer + prereg).
    top_results
  end

  # Evaluate a weight vector against all cached decade data entirely in memory.
  # Accuracy = total_correct / total_positives across all decades (weighted by decade size).
  defp fast_evaluate(weight_vec, decade_data, decades, n_criteria) do
    {total_correct, total_pos} =
      Enum.reduce(decades, {0, 0}, fn decade, {tc, tp} ->
        case Map.get(decade_data, decade) do
          nil ->
            {tc, tp}

          {xs, ys} ->
            n_pos = Enum.count(ys, &(&1 == 1))

            if n_pos == 0 do
              {tc, tp}
            else
              correct =
                Enum.zip(xs, ys)
                |> Enum.map(fn {features, label} ->
                  score =
                    0..(n_criteria - 1)
                    |> Enum.reduce(0.0, fn i, acc ->
                      acc + Enum.at(features, i) * Enum.at(weight_vec, i)
                    end)

                  {score, label}
                end)
                |> Enum.sort_by(&elem(&1, 0), :desc)
                |> Enum.take(n_pos)
                |> Enum.count(fn {_, y} -> y == 1 end)

              {tc + correct, tp + n_pos}
            end
        end
      end)

    if total_pos == 0, do: 0.0, else: Float.round(total_correct / total_pos * 100, 1)
  end

  # Sample a uniform random point on the (n-1)-simplex via the exponential method.
  defp random_simplex_point(n) do
    raw = for _ <- 1..n, do: -:math.log(:rand.uniform_real())
    total = Enum.sum(raw)
    Enum.map(raw, &(&1 / total))
  end

  # --- Private helpers ---

  defp load_decade_data_parallel(source_key, decades) do
    pool_size = Cinegraph.Repo.config()[:pool_size] || 10

    Task.async_stream(
      decades,
      fn d -> {d, extract_decade_features(source_key, d)} end,
      max_concurrency: max(1, min(length(decades), min(pool_size, 8))),
      timeout: :timer.minutes(5),
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce(%{}, fn
      {:ok, {d, data}}, acc ->
        Map.put(acc, d, data)

      {:exit, reason}, acc ->
        Logger.warning("WeightOptimizer: decade load task exited — #{inspect(reason)}")
        acc
    end)
  end

  defp assemble_and_undersample(decade_data, decades, sample_ratio) do
    {x_reversed, y_reversed} =
      Enum.reduce(decades, {[], []}, fn decade, {xs, ys} ->
        case Map.get(decade_data, decade) do
          nil ->
            {xs, ys}

          {decade_x, decade_y} ->
            {[decade_x | xs], [decade_y | ys]}
        end
      end)

    x_all = x_reversed |> Enum.reverse() |> Enum.concat()
    y_all = y_reversed |> Enum.reverse() |> Enum.concat()

    if x_all == [] do
      raise "no training data found for decades #{inspect(decades)} — check that the list exists and has movies with import_status=\"full\""
    end

    undersample(x_all, y_all, sample_ratio)
  end

  defp undersample(x_all, y_all, sample_ratio) do
    positives = Enum.zip(x_all, y_all) |> Enum.filter(fn {_, y} -> y == 1 end)

    if positives == [] do
      raise "no positive labels found — none of the scored movies are members of this list"
    end

    negatives = Enum.zip(x_all, y_all) |> Enum.filter(fn {_, y} -> y == 0 end)

    n_pos = length(positives)
    n_keep = min(n_pos * sample_ratio, length(negatives))
    kept_negatives = Enum.take(Enum.shuffle(negatives), n_keep)

    combined = Enum.shuffle(positives ++ kept_negatives)
    {Enum.map(combined, &elem(&1, 0)), Enum.map(combined, &elem(&1, 1))}
  end

  defp true_loocv_from_cache(source_key, decade_data, decades, sample_ratio) do
    pool_size = Cinegraph.Repo.config()[:pool_size] || 10

    cv_results =
      Task.async_stream(
        decades,
        fn test_decade ->
          try do
            train_decades = Enum.reject(decades, &(&1 == test_decade))

            {x_train, y_train} =
              assemble_and_undersample(decade_data, train_decades, sample_ratio)

            if length(y_train) < 10 do
              Logger.warning(
                "WeightOptimizer LOOCV: too few samples for #{test_decade}s fold, skipping"
              )

              :skip
            else
              fold_weights = fit_model(x_train, y_train)
              result = HistoricalValidator.validate_decade(test_decade, fold_weights, source_key)
              {:ok, %{decade: test_decade, accuracy: result.accuracy_percentage}}
            end
          rescue
            e ->
              Logger.warning(
                "WeightOptimizer LOOCV: skipping #{test_decade}s — #{Exception.message(e)}"
              )

              :skip
          end
        end,
        max_concurrency: max(1, min(length(decades), min(pool_size, 4))),
        timeout: :timer.minutes(5),
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, entry}} ->
          [entry]

        {:ok, :skip} ->
          []

        {:exit, reason} ->
          Logger.warning("WeightOptimizer LOOCV: task exited — #{inspect(reason)}")
          []
      end)

    if cv_results == [] do
      raise "WeightOptimizer LOOCV: no successful folds for source_key=#{inspect(source_key)} — all folds failed or were skipped"
    end

    {compute_mean_accuracy(cv_results), cv_results}
  end

  defp compute_mean_accuracy([]), do: 0.0

  defp compute_mean_accuracy(cv_results) do
    sum = Enum.sum(Enum.map(cv_results, & &1.accuracy))
    Float.round(sum / length(cv_results), 1)
  end

  defp timed(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    elapsed = System.monotonic_time(:millisecond) - start
    {result, elapsed}
  end

  defp extract_decade_features(source_key, decade) do
    query = get_decade_movies_query(decade)
    movies = Cinegraph.Repo.all(query, timeout: :timer.seconds(120))

    # LensScoring strips `source_key` internally (canonical count + director track
    # record), so features are leakage-free. Labels read the movie's REAL
    # canonical_sources (the scored result carries the original movie struct).
    scored = LensScoring.batch_score_movies(movies, @default_weights, source_key)

    {xs, ys} =
      Enum.reduce(scored, {[], []}, fn %{movie: movie, prediction: prediction}, {xs, ys} ->
        scores = prediction.criteria_scores

        feature_row =
          Enum.map(@criteria, fn lens -> (Map.get(scores, lens, 0.0) || 0.0) / 100.0 end)

        label = if Map.has_key?(movie.canonical_sources || %{}, source_key), do: 1, else: 0

        {[feature_row | xs], [label | ys]}
      end)

    {Enum.reverse(xs), Enum.reverse(ys)}
  end

  defp get_decade_movies_query(decade), do: Cinegraph.Movies.decade_movies_query(decade)
end
