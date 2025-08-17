defmodule Cinegraph.Predictions.HistoricalValidator do
  @moduledoc """
  Validates prediction algorithm accuracy by backtesting against historical decades.
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Predictions.CriteriaScoring

  @doc """
  Backtest algorithm against all available historical decades.
  """
  def validate_all_decades(weights \\ nil) do
    decades = [1980, 1990, 2000, 2010]
    
    decade_results = 
      Enum.map(decades, fn decade ->
        validate_decade(decade, weights)
      end)
    
    overall_accuracy = calculate_overall_accuracy(decade_results)
    
    %{
      decade_results: decade_results,
      overall_accuracy: overall_accuracy,
      weights_used: weights || CriteriaScoring.get_default_weights()
    }
  end

  @doc """
  Backtest algorithm against a specific decade.
  """
  def validate_decade(decade, weights \\ nil) do
    # Get all movies from the decade that are on 1001 Movies list
    actual_1001_movies = get_decade_1001_movies(decade)
    
    # Get all movies from the decade (both on and not on 1001 list)
    all_decade_movies = get_all_decade_movies(decade)
    
    # Score all movies and rank them
    scored_movies = 
      all_decade_movies
      |> Enum.map(fn movie ->
        prediction = CriteriaScoring.calculate_movie_score(movie, weights)
        %{
          movie: movie,
          prediction: prediction,
          actually_on_1001: movie.id in Enum.map(actual_1001_movies, & &1.id)
        }
      end)
      |> Enum.sort_by(& &1.prediction.likelihood_percentage, :desc)
    
    # Calculate accuracy metrics
    total_1001_in_decade = length(actual_1001_movies)
    
    # Take top N predictions where N = number of actual 1001 movies
    top_predictions = Enum.take(scored_movies, total_1001_in_decade)
    correctly_predicted = Enum.count(top_predictions, & &1.actually_on_1001)
    
    accuracy_percentage = if total_1001_in_decade > 0 do
      Float.round(correctly_predicted / total_1001_in_decade * 100, 1)
    else
      0.0
    end
    
    # Find the misses (movies we didn't predict that made the list)
    predicted_ids = Enum.map(top_predictions, &(&1.movie.id))
    actual_ids = Enum.map(actual_1001_movies, & &1.id)
    missed_ids = actual_ids -- predicted_ids
    false_positive_ids = predicted_ids -- actual_ids
    
    missed_movies = get_movies_by_ids(missed_ids) |> add_prediction_scores(weights)
    false_positives = get_movies_by_ids(false_positive_ids) |> add_prediction_scores(weights)
    
    %{
      decade: decade,
      total_1001_movies: total_1001_in_decade,
      total_decade_movies: length(all_decade_movies),
      correctly_predicted: correctly_predicted,
      accuracy_percentage: accuracy_percentage,
      missed_movies: missed_movies,
      false_positives: false_positives,
      top_predictions: Enum.take(top_predictions, 10), # Sample for display
      weights_used: weights || CriteriaScoring.get_default_weights()
    }
  end

  @doc """
  Get detailed miss analysis for a specific decade.
  """
  def analyze_decade_misses(decade, weights \\ nil) do
    validation = validate_decade(decade, weights)
    
    %{
      decade: decade,
      missed_analysis: analyze_missed_movies(validation.missed_movies),
      false_positive_analysis: analyze_false_positives(validation.false_positives),
      improvement_suggestions: generate_improvement_suggestions(validation)
    }
  end

  @doc """
  Calculate optimal weights by testing different combinations against historical data.
  """
  def optimize_weights do
    # Test different weight combinations
    weight_combinations = generate_weight_combinations()
    
    results = 
      Enum.map(weight_combinations, fn weights ->
        validation = validate_all_decades(weights)
        %{
          weights: weights,
          overall_accuracy: validation.overall_accuracy
        }
      end)
      |> Enum.sort_by(& &1.overall_accuracy, :desc)
    
    best_weights = hd(results).weights
    
    %{
      optimal_weights: best_weights,
      best_accuracy: hd(results).overall_accuracy,
      tested_combinations: length(weight_combinations),
      top_10_results: Enum.take(results, 10)
    }
  end

  # Private functions

  defp get_decade_1001_movies(decade) do
    start_year = decade
    end_year = decade + 9
    
    query =
      from m in Movie,
        where: fragment("EXTRACT(YEAR FROM ?) >= ? AND EXTRACT(YEAR FROM ?) <= ?", 
               m.release_date, ^start_year, m.release_date, ^end_year),
        where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
        preload: [:external_metrics]

    Repo.all(query)
  end

  defp get_all_decade_movies(decade) do
    start_year = decade
    end_year = decade + 9
    
    query =
      from m in Movie,
        where: fragment("EXTRACT(YEAR FROM ?) >= ? AND EXTRACT(YEAR FROM ?) <= ?", 
               m.release_date, ^start_year, m.release_date, ^end_year),
        where: m.import_status == "full",
        preload: [:external_metrics]

    Repo.all(query)
  end

  defp get_movies_by_ids(ids) when length(ids) == 0, do: []
  defp get_movies_by_ids(ids) do
    query =
      from m in Movie,
        where: m.id in ^ids,
        preload: [:external_metrics]
    
    Repo.all(query)
  end

  defp add_prediction_scores(movies, weights) do
    Enum.map(movies, fn movie ->
      prediction = CriteriaScoring.calculate_movie_score(movie, weights)
      %{
        movie: movie,
        prediction: prediction
      }
    end)
  end

  defp calculate_overall_accuracy(decade_results) do
    total_movies = Enum.sum(Enum.map(decade_results, & &1.total_1001_movies))
    total_correct = Enum.sum(Enum.map(decade_results, & &1.correctly_predicted))
    
    if total_movies > 0 do
      Float.round(total_correct / total_movies * 100, 1)
    else
      0.0
    end
  end

  defp analyze_missed_movies(missed_movies) do
    if length(missed_movies) == 0 do
      %{common_patterns: [], improvement_areas: []}
    else
      # Analyze why we missed these movies
      low_scores = Enum.filter(missed_movies, &(&1.prediction.likelihood_percentage < 60))
      criteria_weaknesses = analyze_criteria_patterns(missed_movies)
      
      %{
        total_missed: length(missed_movies),
        low_scoring_misses: length(low_scores),
        criteria_weaknesses: criteria_weaknesses,
        sample_misses: Enum.take(missed_movies, 5)
      }
    end
  end

  defp analyze_false_positives(false_positives) do
    if length(false_positives) == 0 do
      %{common_patterns: [], over_weighted_areas: []}
    else
      # Analyze why we over-predicted these movies
      high_scores = Enum.filter(false_positives, &(&1.prediction.likelihood_percentage >= 80))
      criteria_overweights = analyze_criteria_patterns(false_positives)
      
      %{
        total_false_positives: length(false_positives),
        high_scoring_fps: length(high_scores),
        criteria_overweights: criteria_overweights,
        sample_fps: Enum.take(false_positives, 5)
      }
    end
  end

  defp analyze_criteria_patterns(movies) do
    if length(movies) == 0 do
      []
    else
      # Analyze which criteria are consistently high/low in these movies
      criteria_averages = 
        Enum.reduce(movies, %{}, fn movie, acc ->
          Enum.reduce(movie.prediction.criteria_scores, acc, fn {criterion, score}, inner_acc ->
            Map.update(inner_acc, criterion, [score], &[score | &1])
          end)
        end)
        |> Enum.map(fn {criterion, scores} ->
          avg = Enum.sum(scores) / length(scores)
          %{criterion: criterion, average_score: Float.round(avg, 1)}
        end)
        |> Enum.sort_by(& &1.average_score, :desc)
      
      criteria_averages
    end
  end

  defp generate_improvement_suggestions(validation) do
    suggestions = []
    
    # Low accuracy suggests algorithm tuning needed
    suggestions = if validation.accuracy_percentage < 80 do
      ["Consider adjusting criteria weights to improve accuracy" | suggestions]
    else
      suggestions
    end
    
    # High false positives suggests over-weighting certain criteria
    suggestions = if length(validation.false_positives) > validation.total_1001_movies * 0.3 do
      ["High false positive rate - consider reducing weights on over-represented criteria" | suggestions]
    else
      suggestions
    end
    
    # Add more suggestion logic as needed
    suggestions
  end

  defp generate_weight_combinations do
    # Generate different weight combinations for optimization
    # This is a simplified version - could be more sophisticated
    [
      %{critical_acclaim: 0.40, festival_recognition: 0.30, cultural_impact: 0.15, technical_innovation: 0.10, auteur_recognition: 0.05},
      %{critical_acclaim: 0.30, festival_recognition: 0.40, cultural_impact: 0.15, technical_innovation: 0.10, auteur_recognition: 0.05},
      %{critical_acclaim: 0.35, festival_recognition: 0.25, cultural_impact: 0.25, technical_innovation: 0.10, auteur_recognition: 0.05},
      %{critical_acclaim: 0.35, festival_recognition: 0.30, cultural_impact: 0.20, technical_innovation: 0.15, auteur_recognition: 0.00},
      # Add more combinations as needed
    ]
  end
end