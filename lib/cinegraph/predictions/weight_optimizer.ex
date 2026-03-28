defmodule Cinegraph.Predictions.WeightOptimizer do
  @moduledoc """
  Learns optimal prediction weights for a given movie list via logistic regression.

  Uses Scholar.Linear.LogisticRegression on the 5 criteria scores
  (mob, critics, festival_recognition, cultural_impact, auteur_recognition) as
  features and list membership as the binary label.

  ## Usage

      WeightOptimizer.train("1001_movies")
      # => %{weights: %{...}, trained_accuracy: 61.2, baseline_accuracy: 55.8, ...}

      WeightOptimizer.train("1001_movies", save: true)
      # also persists weights to movie_lists.trained_weights

  """

  alias Cinegraph.Predictions.{CriteriaScoring, HistoricalValidator}
  alias Cinegraph.Movies.MovieLists

  require Logger

  @criteria CriteriaScoring.scoring_criteria()

  # Default weights for baseline comparison
  @default_weights CriteriaScoring.get_default_weights()

  @doc """
  Main entry point. Trains logistic regression weights for the given list key.

  ## Options
    * `:sample_ratio` - negatives-to-positives ratio for undersampling (default: 5)
    * `:save` - if true, persist weights to DB via MovieLists.save_trained_weights/2

  Returns a result map with:
    * `:weights` - %{mob: float, critics: float, ...} summing to 1.0
    * `:feature_importance` - [{:criterion, weight}, ...] sorted descending
    * `:baseline_accuracy` - overall accuracy with default weights
    * `:trained_accuracy` - leave-one-decade-out CV accuracy with new weights
    * `:cv_by_decade` - [%{decade: 1930, accuracy: 42.1}, ...]
  """
  def train(source_key, opts \\ []) do
    sample_ratio = Keyword.get(opts, :sample_ratio, 5)

    Logger.info("WeightOptimizer: building feature matrix for #{source_key}")
    {x_list, y_list} = build_feature_matrix(source_key, sample_ratio)

    n_pos = Enum.count(y_list, &(&1 == 1))
    n_neg = Enum.count(y_list, &(&1 == 0))
    Logger.info("WeightOptimizer: #{n_pos} positives, #{n_neg} negatives")

    Logger.info("WeightOptimizer: fitting logistic regression")
    weights = fit_model(x_list, y_list)

    Logger.info("WeightOptimizer: running true leave-one-decade-out cross-validation")
    {trained_accuracy, cv_by_decade} = true_loocv(source_key, sample_ratio)
    {baseline_accuracy, _} = decade_cross_validate(source_key, @default_weights)

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
      n_negatives: n_neg
    }

    if Keyword.get(opts, :save, false) do
      string_weights = Map.new(weights, fn {k, v} -> {Atom.to_string(k), v} end)

      case MovieLists.save_trained_weights(source_key, string_weights) do
        {:ok, _} -> Logger.info("WeightOptimizer: saved weights to DB for #{source_key}")
        {:error, reason} -> Logger.error("WeightOptimizer: failed to save — #{inspect(reason)}")
      end
    end

    result
  end

  @doc """
  Build X (feature matrix) and y (labels) from all historical decade data.

  For each decade, loads all movies via HistoricalValidator's slim query,
  scores them with CriteriaScoring.batch_score_movies/2, then undersamples
  negatives at `sample_ratio`:1 relative to positives.

  Returns `{x_list, y_list}` where each element is a list of 5 floats (0.0–1.0)
  and the corresponding 0/1 label.
  """
  def build_feature_matrix(source_key, sample_ratio \\ 5) do
    build_feature_matrix_for_decades(
      source_key,
      HistoricalValidator.get_all_decades(source_key),
      sample_ratio
    )
  end

  @doc """
  Fit logistic regression on the feature matrix. Returns weight map with atom keys.
  """
  def fit_model(x_list, y_list) do
    x_tensor = Nx.tensor(x_list, type: :f32)
    y_tensor = Nx.tensor(y_list, type: :u32)

    model =
      Scholar.Linear.LogisticRegression.fit(x_tensor, y_tensor,
        num_classes: 2,
        max_iterations: 1000
      )

    extract_weights(model)
  end

  @doc """
  Evaluates fixed weights per decade (no retraining). Used for baseline comparison.
  Returns {mean_accuracy, cv_by_decade}.
  """
  def decade_cross_validate(source_key, weights) do
    decades = HistoricalValidator.get_all_decades(source_key)

    cv_results =
      Enum.flat_map(decades, fn decade ->
        try do
          result = HistoricalValidator.validate_decade(decade, weights, source_key)
          [%{decade: decade, accuracy: result.accuracy_percentage}]
        rescue
          e ->
            Logger.warning("WeightOptimizer CV: skipping #{decade}s — #{Exception.message(e)}")
            []
        end
      end)

    mean =
      if cv_results == [] do
        0.0
      else
        sum = Enum.sum(Enum.map(cv_results, & &1.accuracy))
        Float.round(sum / length(cv_results), 1)
      end

    {mean, cv_results}
  end

  @doc """
  True leave-one-decade-out cross-validation: for each test decade, retrains on all
  other decades, then evaluates on the held-out decade. Returns {mean_accuracy, cv_by_decade}.
  """
  def true_loocv(source_key, sample_ratio \\ 5) do
    decades = HistoricalValidator.get_all_decades(source_key)

    cv_results =
      Enum.flat_map(decades, fn test_decade ->
        try do
          train_decades = Enum.reject(decades, &(&1 == test_decade))

          {x_train, y_train} =
            build_feature_matrix_for_decades(source_key, train_decades, sample_ratio)

          if length(y_train) < 10 do
            Logger.warning(
              "WeightOptimizer LOOCV: too few samples for #{test_decade}s fold, skipping"
            )

            []
          else
            fold_weights = fit_model(x_train, y_train)
            result = HistoricalValidator.validate_decade(test_decade, fold_weights, source_key)
            [%{decade: test_decade, accuracy: result.accuracy_percentage}]
          end
        rescue
          e ->
            Logger.warning(
              "WeightOptimizer LOOCV: skipping #{test_decade}s — #{Exception.message(e)}"
            )

            []
        end
      end)

    mean =
      if cv_results == [] do
        0.0
      else
        sum = Enum.sum(Enum.map(cv_results, & &1.accuracy))
        Float.round(sum / length(cv_results), 1)
      end

    {mean, cv_results}
  end

  @doc """
  Extract normalized positive-class weights from a fitted logistic regression model.
  Clamps negatives to 0, normalizes to sum to 1.0.
  """
  def extract_weights(model) do
    # coefficients shape: {num_features, num_classes}
    # Column 1 = positive class weights, one per feature
    pos_coeffs = model.coefficients[[.., 1]]

    # Clamp negatives to 0 — all 5 features should be positively predictive
    clamped = Nx.max(pos_coeffs, 0.0)

    total = Nx.sum(clamped) |> Nx.to_number()

    normalized =
      if total > 0.0 do
        Nx.divide(clamped, total)
      else
        # fallback: equal weights
        Nx.broadcast(Nx.tensor(1.0 / length(@criteria)), {length(@criteria)})
      end

    values = Nx.to_list(normalized)

    @criteria
    |> Enum.zip(values)
    |> Map.new()
  end

  # --- Private helpers ---

  defp build_feature_matrix_for_decades(source_key, decades, sample_ratio) do
    {x_reversed, y_reversed} =
      Enum.reduce(decades, {[], []}, fn decade, {xs, ys} ->
        try do
          {decade_x, decade_y} = extract_decade_features(source_key, decade)
          {[decade_x | xs], [decade_y | ys]}
        rescue
          e ->
            Logger.warning("WeightOptimizer: skipping #{decade}s — #{Exception.message(e)}")
            {xs, ys}
        end
      end)

    x_all = x_reversed |> Enum.reverse() |> Enum.concat()
    y_all = y_reversed |> Enum.reverse() |> Enum.concat()

    if x_all == [] do
      raise "no training data found for source_key=#{inspect(source_key)} — check that the list exists and has movies with import_status=\"full\""
    end

    positives = Enum.zip(x_all, y_all) |> Enum.filter(fn {_, y} -> y == 1 end)

    if positives == [] do
      raise "no positive labels found for source_key=#{inspect(source_key)} — none of the scored movies are members of this list"
    end
    negatives = Enum.zip(x_all, y_all) |> Enum.filter(fn {_, y} -> y == 0 end)

    n_pos = length(positives)
    n_keep = min(n_pos * sample_ratio, length(negatives))
    kept_negatives = Enum.take(Enum.shuffle(negatives), n_keep)

    combined = Enum.shuffle(positives ++ kept_negatives)
    {Enum.map(combined, &elem(&1, 0)), Enum.map(combined, &elem(&1, 1))}
  end

  defp extract_decade_features(source_key, decade) do
    query = get_decade_movies_query(decade)
    movies = Cinegraph.Repo.all(query, timeout: :timer.seconds(120))

    # Strip only the target list's own key from canonical_sources before scoring to prevent
    # data leakage: score_cultural_impact encodes canonical list membership (70/100 points).
    # Removing only the self-referential entry preserves signal from other canonical lists
    # (Sight & Sound, Criterion, etc.) while eliminating the circular label encoding.
    movies_for_scoring =
      Enum.map(movies, fn m ->
        Map.update(m, :canonical_sources, %{}, &Map.delete(&1, source_key))
      end)
    scored = CriteriaScoring.batch_score_movies(movies_for_scoring, @default_weights)

    # Zip originals back in so labels use real canonical_sources
    {xs, ys} =
      Enum.zip(movies, scored)
      |> Enum.reduce({[], []}, fn {original_movie, %{prediction: prediction}}, {xs, ys} ->
        scores = prediction.criteria_scores

        feature_row =
          Enum.map(@criteria, fn crit -> (Map.get(scores, crit, 0.0) || 0.0) / 100.0 end)

        label =
          case original_movie.canonical_sources do
            %{^source_key => _} -> 1
            _ -> 0
          end

        {[feature_row | xs], [label | ys]}
      end)

    {Enum.reverse(xs), Enum.reverse(ys)}
  end

  defp get_decade_movies_query(decade) do
    import Ecto.Query
    alias Cinegraph.Movies.Movie

    start_date = Date.new!(decade, 1, 1)
    end_date = Date.new!(decade + 9, 12, 31)

    from m in Movie,
      where: m.release_date >= ^start_date and m.release_date <= ^end_date,
      where: m.import_status == "full",
      select: %Movie{
        id: m.id,
        release_date: m.release_date,
        tmdb_data: m.tmdb_data,
        canonical_sources: m.canonical_sources
      }
  end
end
