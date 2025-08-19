defmodule Cinegraph.Predictions.HistoricalValidator do
  @moduledoc """
  Validates prediction algorithm accuracy by backtesting against historical decades.
  Dynamically calculates decades based on actual movies in the 1001 Movies list.
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Metrics.ScoringService
  alias Cinegraph.Metrics.MetricWeightProfile

  @doc """
  Dynamically get all decades that have movies in the 1001 Movies list.
  """
  def get_all_decades do
    query =
      from m in Movie,
        where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
        where: not is_nil(m.release_date),
        select: fragment("FLOOR(EXTRACT(YEAR FROM ?) / 10) * 10", m.release_date),
        distinct: true,
        order_by: [asc: fragment("FLOOR(EXTRACT(YEAR FROM ?) / 10) * 10", m.release_date)]

    Repo.all(query)
    |> Enum.map(fn
      %Decimal{} = d -> Decimal.to_integer(d)
      n when is_number(n) -> trunc(n)
    end)

    # Convert to integers
    # Filter out very old/invalid decades
    |> Enum.filter(&(&1 >= 1920))
  end

  @doc """
  Backtest algorithm against all available historical decades.
  Uses database-driven weight profiles.
  """
  def validate_all_decades(profile_or_weights \\ nil) do
    profile = get_weight_profile(profile_or_weights)
    decades = get_all_decades()

    # Include ALL decades with data, including 2020s if they have confirmed additions
    # This gives us a complete picture of how well our algorithm works
    all_decades_with_data = decades

    decade_results =
      Enum.map(all_decades_with_data, fn decade ->
        validate_decade(decade, profile)
      end)

    overall_accuracy = calculate_overall_accuracy(decade_results)

    # Calculate the actual range dynamically
    min_decade =
      if length(all_decades_with_data) > 0, do: Enum.min(all_decades_with_data), else: 1920

    max_decade =
      if length(all_decades_with_data) > 0, do: Enum.max(all_decades_with_data), else: 2020

    %{
      decade_results: decade_results,
      overall_accuracy: overall_accuracy,
      profile_used: profile.name,
      weights_used: ScoringService.profile_to_discovery_weights(profile),
      decades_analyzed: length(all_decades_with_data),
      decade_range: "#{min_decade}s-#{max_decade}s"
    }
  end

  @doc """
  Backtest algorithm against a specific decade using database scoring.
  """
  def validate_decade(decade, profile_or_weights \\ nil) do
    profile = get_weight_profile(profile_or_weights)

    # Get all movies from the decade that are on 1001 Movies list
    actual_1001_movies = get_decade_1001_movies(decade)

    # Get all movies from the decade (limited sample for performance)
    all_decade_query = get_decade_movies_query(decade)

    # Apply scoring to all decade movies
    scored_query = ScoringService.apply_scoring(all_decade_query, profile, %{})
    all_decade_movies = Repo.all(scored_query)

    # Sort by score and take top N where N = number of actual 1001 movies
    total_1001_in_decade = length(actual_1001_movies)
    actual_1001_ids = MapSet.new(actual_1001_movies, & &1.id)

    # Take top predictions
    top_predictions =
      all_decade_movies
      |> Enum.sort_by(& &1.discovery_score, :desc)
      |> Enum.take(total_1001_in_decade)

    # Calculate accuracy
    correctly_predicted =
      Enum.count(top_predictions, fn movie ->
        MapSet.member?(actual_1001_ids, movie.id)
      end)

    accuracy_percentage =
      if total_1001_in_decade > 0 do
        Float.round(correctly_predicted / total_1001_in_decade * 100, 1)
      else
        0.0
      end

    # Find misses and false positives
    predicted_ids = MapSet.new(top_predictions, & &1.id)
    missed_ids = MapSet.difference(actual_1001_ids, predicted_ids) |> MapSet.to_list()
    false_positive_ids = MapSet.difference(predicted_ids, actual_1001_ids) |> MapSet.to_list()

    %{
      decade: decade,
      total_1001_movies: total_1001_in_decade,
      total_decade_movies: length(all_decade_movies),
      correctly_predicted: correctly_predicted,
      accuracy_percentage: accuracy_percentage,
      missed_count: length(missed_ids),
      false_positive_count: length(false_positive_ids),
      # Sample for display
      top_predictions: Enum.take(top_predictions, 10),
      profile_used: profile.name
    }
  end

  @doc """
  Get validation statistics by decade range (e.g., early cinema, golden age, modern).
  """
  def validate_by_era(profile_or_weights \\ nil) do
    profile = get_weight_profile(profile_or_weights)
    decades = get_all_decades() |> Enum.filter(&(&1 < 2020))

    eras = %{
      "Early Cinema (1920s-1940s)" => Enum.filter(decades, &(&1 >= 1920 and &1 <= 1940)),
      "Golden Age (1950s-1960s)" => Enum.filter(decades, &(&1 >= 1950 and &1 <= 1960)),
      "New Hollywood (1970s-1980s)" => Enum.filter(decades, &(&1 >= 1970 and &1 <= 1980)),
      "Modern Era (1990s-2010s)" => Enum.filter(decades, &(&1 >= 1990 and &1 <= 2010))
    }

    Enum.map(eras, fn {era_name, era_decades} ->
      results = Enum.map(era_decades, &validate_decade(&1, profile))

      total_correct = Enum.sum(Enum.map(results, & &1.correctly_predicted))
      total_movies = Enum.sum(Enum.map(results, & &1.total_1001_movies))

      accuracy =
        if total_movies > 0 do
          Float.round(total_correct / total_movies * 100, 1)
        else
          0.0
        end

      {era_name,
       %{
         decades: era_decades,
         total_1001_movies: total_movies,
         total_correct: total_correct,
         accuracy_percentage: accuracy
       }}
    end)
    |> Map.new()
  end

  @doc """
  Get detailed miss analysis for a specific decade.
  """
  def analyze_decade_misses(decade, profile_or_weights \\ nil) do
    validation = validate_decade(decade, profile_or_weights)

    %{
      decade: decade,
      accuracy: validation.accuracy_percentage,
      missed_count: validation.missed_count,
      false_positive_count: validation.false_positive_count,
      improvement_suggestions: generate_improvement_suggestions(validation)
    }
  end

  @doc """
  Calculate optimal weights by testing different profiles against historical data.
  Now includes all decades (including 2020s) for comprehensive comparison.
  """
  def compare_profiles do
    # Get all available profiles from database
    profiles = ScoringService.get_all_profiles()
    # Include ALL decades for full comparison
    decades = get_all_decades()

    results =
      Enum.map(profiles, fn profile ->
        validation = validate_all_decades(profile)

        %{
          profile_name: profile.name,
          description: profile.description,
          overall_accuracy: validation.overall_accuracy,
          decade_results: validation.decade_results,
          weights_used: validation.weights_used
        }
      end)
      |> Enum.sort_by(& &1.overall_accuracy, :desc)

    # Calculate per-decade winners
    decade_winners = calculate_decade_winners(results)

    case results do
      [best | _] ->
        %{
          best_profile: best.profile_name,
          best_accuracy: best.overall_accuracy,
          all_results: results,
          decades_tested: length(decades),
          decade_winners: decade_winners
        }

      [] ->
        %{
          best_profile: nil,
          best_accuracy: 0.0,
          all_results: [],
          decades_tested: length(decades),
          decade_winners: %{}
        }
    end
  end

  @doc """
  Compare all profiles and return detailed comparison data for UI display.
  Includes caching for performance.
  """
  def get_comprehensive_comparison do
    # This will be cached by PredictionsCache
    profiles = ScoringService.get_all_profiles()
    decades = get_all_decades()

    comparison_data =
      Enum.map(profiles, fn profile ->
        decade_accuracies =
          Enum.map(decades, fn decade ->
            result = validate_decade(decade, profile)
            {decade, result.accuracy_percentage}
          end)
          |> Map.new()

        overall = calculate_overall_from_decades(decade_accuracies)

        %{
          profile: profile,
          overall_accuracy: overall,
          decade_accuracies: decade_accuracies,
          strengths: identify_profile_strengths(decade_accuracies, decades)
        }
      end)

    %{
      profiles: comparison_data,
      best_overall: find_best_overall(comparison_data),
      best_per_decade: find_best_per_decade(comparison_data, decades),
      insights: generate_insights(comparison_data, decades)
    }
  end

  # Private functions

  defp get_weight_profile(nil), do: ScoringService.get_default_profile()

  defp get_weight_profile(%MetricWeightProfile{} = profile), do: profile

  defp get_weight_profile(profile_name) when is_binary(profile_name) do
    ScoringService.get_profile(profile_name) || ScoringService.get_default_profile()
  end

  defp get_weight_profile(weights) when is_map(weights) do
    # Convert custom weights to a profile
    %MetricWeightProfile{
      name: "Custom Validation",
      description: "Custom weights for validation",
      category_weights: convert_weights_to_categories(weights),
      active: true
    }
  end

  defp convert_weights_to_categories(weights) do
    # Map validation weights to database categories
    # Popular opinion now includes all rating sources (critical_acclaim merged in)
    %{
      "ratings" => Map.get(weights, :popular_opinion, 0.25) + Map.get(weights, :critical_acclaim, 0.0),
      "awards" => Map.get(weights, :industry_recognition, 0.25),
      "cultural" => Map.get(weights, :cultural_impact, 0.25),
      "people" => Map.get(weights, :people_quality, 0.25),
      "financial" => 0.0
    }
  end

  defp get_decade_1001_movies(decade) do
    start_year = decade
    end_year = decade + 9

    query =
      from m in Movie,
        where:
          fragment(
            "EXTRACT(YEAR FROM ?) >= ? AND EXTRACT(YEAR FROM ?) <= ?",
            m.release_date,
            ^start_year,
            m.release_date,
            ^end_year
          ),
        where: fragment("? \\? ?", m.canonical_sources, "1001_movies")

    Repo.all(query)
  end

  defp get_decade_movies_query(decade) do
    start_year = decade
    end_year = decade + 9

    from m in Movie,
      where:
        fragment(
          "EXTRACT(YEAR FROM ?) >= ? AND EXTRACT(YEAR FROM ?) <= ?",
          m.release_date,
          ^start_year,
          m.release_date,
          ^end_year
        ),
      where: m.import_status == "full",
      # Limit for performance
      limit: 1000
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

  defp generate_improvement_suggestions(validation) do
    suggestions = []

    # Low accuracy suggests algorithm tuning needed
    suggestions =
      if validation.accuracy_percentage < 50 do
        [
          "Consider using a different weight profile - current accuracy is below 50%"
          | suggestions
        ]
      else
        suggestions
      end

    # High false positives suggests over-weighting certain criteria
    false_positive_rate =
      if validation.total_1001_movies > 0 do
        validation.false_positive_count / validation.total_1001_movies
      else
        0
      end

    suggestions =
      if false_positive_rate > 0.5 do
        [
          "High false positive rate (#{Float.round(false_positive_rate * 100, 1)}%) - consider adjusting weights"
          | suggestions
        ]
      else
        suggestions
      end

    # Add decade-specific suggestions
    suggestions =
      if validation.decade < 1960 do
        [
          "Early cinema may require different weighting - consider 'Critics Choice' profile"
          | suggestions
        ]
      else
        suggestions
      end

    suggestions =
      if validation.decade >= 2000 do
        ["Modern era films may benefit from 'Balanced' or 'Crowd Pleaser' profiles" | suggestions]
      else
        suggestions
      end

    if length(suggestions) == 0 do
      ["Algorithm performing well for this decade"]
    else
      suggestions
    end
  end

  # New helper functions for comprehensive comparison

  defp calculate_decade_winners(results) do
    all_decades =
      results
      |> Enum.flat_map(& &1.decade_results)
      |> Enum.map(& &1.decade)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(all_decades, fn decade ->
      winner =
        results
        |> Enum.map(fn result ->
          decade_result = Enum.find(result.decade_results, fn dr -> dr.decade == decade end)
          {result.profile_name, (decade_result && decade_result.accuracy_percentage) || 0.0}
        end)
        |> Enum.max_by(fn {_name, accuracy} -> accuracy end, fn -> {"None", 0.0} end)

      {decade, winner}
    end)
    |> Map.new()
  end

  defp calculate_overall_from_decades(decade_accuracies) do
    values = Map.values(decade_accuracies)

    if length(values) > 0 do
      Float.round(Enum.sum(values) / length(values), 1)
    else
      0.0
    end
  end

  defp find_best_overall(comparison_data) do
    case Enum.max_by(comparison_data, & &1.overall_accuracy, fn -> nil end) do
      nil ->
        nil

      best ->
        %{
          profile_name: best.profile.name,
          accuracy: best.overall_accuracy,
          description: best.profile.description
        }
    end
  end

  defp find_best_per_decade(comparison_data, decades) do
    Enum.map(decades, fn decade ->
      best =
        comparison_data
        |> Enum.map(fn data ->
          accuracy = Map.get(data.decade_accuracies, decade, 0.0)
          {data.profile.name, accuracy}
        end)
        |> Enum.max_by(fn {_name, acc} -> acc end, fn -> {"None", 0.0} end)

      {decade, best}
    end)
    |> Map.new()
  end

  defp identify_profile_strengths(decade_accuracies, decades) do
    early_decades = Enum.filter(decades, &(&1 <= 1960))
    modern_decades = Enum.filter(decades, &(&1 >= 1990))

    early_avg = average_accuracy_for_decades(decade_accuracies, early_decades)
    modern_avg = average_accuracy_for_decades(decade_accuracies, modern_decades)

    cond do
      early_avg > modern_avg + 10 -> "Strong for classic cinema (pre-1960s)"
      modern_avg > early_avg + 10 -> "Strong for modern cinema (1990s+)"
      true -> "Consistent across all eras"
    end
  end

  defp average_accuracy_for_decades(decade_accuracies, decades) do
    accuracies = Enum.map(decades, &Map.get(decade_accuracies, &1, 0.0))

    if length(accuracies) > 0 do
      Float.round(Enum.sum(accuracies) / length(accuracies), 1)
    else
      0.0
    end
  end

  defp generate_insights(comparison_data, decades) do
    %{
      total_decades: length(decades),
      highest_variance: find_highest_variance_profile(comparison_data),
      most_consistent: find_most_consistent_profile(comparison_data),
      era_specialists: find_era_specialists(comparison_data, decades)
    }
  end

  defp find_highest_variance_profile(comparison_data) do
    scores =
      comparison_data
      |> Enum.map(fn data ->
        accuracies = Map.values(data.decade_accuracies)

        variance =
          if length(accuracies) > 0 do
            avg = Enum.sum(accuracies) / length(accuracies)
            Enum.sum(Enum.map(accuracies, fn x -> :math.pow(x - avg, 2) end)) / length(accuracies)
          else
            0.0
          end

        {data.profile.name, Float.round(:math.sqrt(variance), 1)}
      end)

    if scores == [] do
      {"None", 0.0}
    else
      Enum.max_by(scores, fn {_name, var} -> var end)
    end
  end

  defp find_most_consistent_profile(comparison_data) do
    scores =
      comparison_data
      |> Enum.map(fn data ->
        accuracies = Map.values(data.decade_accuracies)

        variance =
          if length(accuracies) > 0 do
            avg = Enum.sum(accuracies) / length(accuracies)
            Enum.sum(Enum.map(accuracies, fn x -> :math.pow(x - avg, 2) end)) / length(accuracies)
          else
            999.0
          end

        {data.profile.name, Float.round(:math.sqrt(variance), 1)}
      end)

    if scores == [] do
      {"None", 0.0}
    else
      Enum.min_by(scores, fn {_name, var} -> var end)
    end
  end

  defp find_era_specialists(comparison_data, decades) do
    %{
      classic_era: find_best_for_era(comparison_data, Enum.filter(decades, &(&1 <= 1960))),
      golden_age:
        find_best_for_era(comparison_data, Enum.filter(decades, &(&1 >= 1950 and &1 <= 1970))),
      modern_era: find_best_for_era(comparison_data, Enum.filter(decades, &(&1 >= 1990)))
    }
  end

  defp find_best_for_era(comparison_data, era_decades) do
    case comparison_data
         |> Enum.map(fn data ->
           avg = average_accuracy_for_decades(data.decade_accuracies, era_decades)
           {data.profile.name, avg}
         end)
         |> Enum.max_by(fn {_name, avg} -> avg end, fn -> {"None", 0.0} end) do
      {name, accuracy} -> %{profile: name, accuracy: accuracy}
    end
  end
end
