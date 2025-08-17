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
    end)  # Convert to integers
    |> Enum.filter(& &1 >= 1920)  # Filter out very old/invalid decades
  end

  @doc """
  Backtest algorithm against all available historical decades.
  Uses database-driven weight profiles.
  """
  def validate_all_decades(profile_or_weights \\ nil) do
    profile = get_weight_profile(profile_or_weights)
    decades = get_all_decades()
    
    # Only validate decades before 2020 (since 2020s are our prediction target)
    historical_decades = Enum.filter(decades, & &1 < 2020)
    
    decade_results = 
      Enum.map(historical_decades, fn decade ->
        validate_decade(decade, profile)
      end)
    
    overall_accuracy = calculate_overall_accuracy(decade_results)
    
    %{
      decade_results: decade_results,
      overall_accuracy: overall_accuracy,
      profile_used: profile.name,
      weights_used: ScoringService.profile_to_discovery_weights(profile),
      decades_analyzed: length(historical_decades),
      decade_range: "#{Enum.min(historical_decades, fn -> 1920 end)}s-#{Enum.max(historical_decades, fn -> 2010 end)}s"
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
    
    accuracy_percentage = if total_1001_in_decade > 0 do
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
      top_predictions: Enum.take(top_predictions, 10), # Sample for display
      profile_used: profile.name
    }
  end

  @doc """
  Get validation statistics by decade range (e.g., early cinema, golden age, modern).
  """
  def validate_by_era(profile_or_weights \\ nil) do
    profile = get_weight_profile(profile_or_weights)
    decades = get_all_decades() |> Enum.filter(& &1 < 2020)
    
    eras = %{
      "Early Cinema (1920s-1940s)" => Enum.filter(decades, & &1 >= 1920 and &1 <= 1940),
      "Golden Age (1950s-1960s)" => Enum.filter(decades, & &1 >= 1950 and &1 <= 1960),
      "New Hollywood (1970s-1980s)" => Enum.filter(decades, & &1 >= 1970 and &1 <= 1980),
      "Modern Era (1990s-2010s)" => Enum.filter(decades, & &1 >= 1990 and &1 <= 2010)
    }
    
    Enum.map(eras, fn {era_name, era_decades} ->
      results = Enum.map(era_decades, &validate_decade(&1, profile))
      
      total_correct = Enum.sum(Enum.map(results, & &1.correctly_predicted))
      total_movies = Enum.sum(Enum.map(results, & &1.total_1001_movies))
      
      accuracy = if total_movies > 0 do
        Float.round(total_correct / total_movies * 100, 1)
      else
        0.0
      end
      
      {era_name, %{
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
  """
  def compare_profiles do
    # Get all available profiles from database
    profiles = ScoringService.get_all_profiles()
    decades = get_all_decades() |> Enum.filter(& &1 < 2020)
    
    results = 
      Enum.map(profiles, fn profile ->
        validation = validate_all_decades(profile)
        %{
          profile_name: profile.name,
          description: profile.description,
          overall_accuracy: validation.overall_accuracy,
          decade_results: validation.decade_results
        }
      end)
      |> Enum.sort_by(& &1.overall_accuracy, :desc)
    
    %{
      best_profile: hd(results).profile_name,
      best_accuracy: hd(results).overall_accuracy,
      all_results: results,
      decades_tested: length(decades)
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
    %{
      "ratings" => (Map.get(weights, :critical_acclaim, 0.2) + Map.get(weights, :popular_opinion, 0.2)) / 2,
      "awards" => Map.get(weights, :industry_recognition, 0.2),
      "cultural" => Map.get(weights, :cultural_impact, 0.2),
      "people" => Map.get(weights, :people_quality, 0.2),
      "financial" => 0.0
    }
  end

  defp get_decade_1001_movies(decade) do
    start_year = decade
    end_year = decade + 9
    
    query =
      from m in Movie,
        where: fragment("EXTRACT(YEAR FROM ?) >= ? AND EXTRACT(YEAR FROM ?) <= ?", 
               m.release_date, ^start_year, m.release_date, ^end_year),
        where: fragment("? \\? ?", m.canonical_sources, "1001_movies")

    Repo.all(query)
  end

  defp get_decade_movies_query(decade) do
    start_year = decade
    end_year = decade + 9
    
    from m in Movie,
      where: fragment("EXTRACT(YEAR FROM ?) >= ? AND EXTRACT(YEAR FROM ?) <= ?", 
             m.release_date, ^start_year, m.release_date, ^end_year),
      where: m.import_status == "full",
      limit: 1000  # Limit for performance
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
    suggestions = if validation.accuracy_percentage < 50 do
      ["Consider using a different weight profile - current accuracy is below 50%" | suggestions]
    else
      suggestions
    end
    
    # High false positives suggests over-weighting certain criteria
    false_positive_rate = if validation.total_1001_movies > 0 do
      validation.false_positive_count / validation.total_1001_movies
    else
      0
    end
    
    suggestions = if false_positive_rate > 0.5 do
      ["High false positive rate (#{Float.round(false_positive_rate * 100, 1)}%) - consider adjusting weights" | suggestions]
    else
      suggestions
    end
    
    # Add decade-specific suggestions
    suggestions = if validation.decade < 1960 do
      ["Early cinema may require different weighting - consider 'Critics Choice' profile" | suggestions]
    else
      suggestions
    end
    
    suggestions = if validation.decade >= 2000 do
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
end