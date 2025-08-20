defmodule Cinegraph.Workers.PredictionsWorker do
  @moduledoc """
  Worker that handles individual prediction calculation tasks.
  Each task is small enough to complete without timeout.
  """
  
  use Oban.Worker, queue: :predictions, max_attempts: 3
  
  require Logger
  
  alias Cinegraph.Repo
  alias Cinegraph.Predictions.{MoviePredictor, PredictionCache, HistoricalValidator}
  alias Cinegraph.Metrics.{MetricWeightProfile, ScoringService}
  
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => "calculate_predictions", "profile_id" => profile_id, "decade" => decade}}) do
    Logger.info("Calculating #{decade}s predictions for profile #{profile_id}")
    
    profile = Repo.get!(MetricWeightProfile, profile_id)
    
    # Use the generic decade predictor
    predictions_result = MoviePredictor.predict_decade_movies(decade, 1000, profile)
    
    # Transform and save immediately
    movie_scores = 
      Enum.reduce(predictions_result.predictions, %{}, fn pred, acc ->
        Map.put(acc, to_string(pred.id), %{
          "title" => pred.title,
          "score" => pred.prediction.likelihood_percentage,
          "release_date" => Date.to_iso8601(pred.release_date),
          "year" => pred.year,
          "status" => Atom.to_string(pred.status),
          "canonical_sources" => pred.movie.canonical_sources || %{},
          "total_score" => pred.prediction.total_score,
          "breakdown" => format_breakdown(pred.prediction.breakdown)
        })
      end)
    
    statistics = calculate_statistics(predictions_result.predictions)
    
    # Save to database immediately
    {:ok, _cache} = PredictionCache.upsert_cache(%{
      decade: decade,
      profile_id: profile_id,
      movie_scores: movie_scores,
      statistics: statistics,
      calculated_at: DateTime.utc_now(),
      metadata: %{
        "algorithm_info" => predictions_result.algorithm_info,
        "total_candidates" => predictions_result.total_candidates,
        "calculation_timestamp" => DateTime.utc_now()
      }
    })
    
    Logger.info("Successfully cached #{map_size(movie_scores)} predictions for decade #{decade}, profile #{profile_id}")
    :ok
  end
  
  def perform(%Oban.Job{args: %{"action" => "calculate_validation", "profile_id" => profile_id, "decade" => decade}}) do
    Logger.info("Calculating validation for decade #{decade}, profile #{profile_id}")
    
    profile = Repo.get!(MetricWeightProfile, profile_id)
    
    # Calculate validation for just this decade
    validation_result = HistoricalValidator.validate_decade(decade, profile)
    
    # Store in a temporary table or cache for later aggregation
    # For now, we'll store in Cachex with a specific key
    cache_key = "validation:#{profile_id}:#{decade}"
    Cachex.put(:predictions_cache, cache_key, validation_result, ttl: :timer.hours(1))
    
    Logger.info("Cached validation for decade #{decade}, accuracy: #{validation_result.accuracy_percentage}%")
    :ok
  end
  
  def perform(%Oban.Job{args: %{"action" => "aggregate_validation", "profile_id" => profile_id}}) do
    Logger.info("Aggregating validation results for profile #{profile_id}")
    
    profile = Repo.get!(MetricWeightProfile, profile_id)
    decades = [1920, 1930, 1940, 1950, 1960, 1970, 1980, 1990, 2000, 2010, 2020]
    
    # Collect all decade results from cache
    decade_results = Enum.map(decades, fn decade ->
      cache_key = "validation:#{profile_id}:#{decade}"
      case Cachex.get(:predictions_cache, cache_key) do
        {:ok, nil} -> 
          # If not in cache, calculate it (shouldn't happen normally)
          HistoricalValidator.validate_decade(decade, profile)
        {:ok, result} -> 
          result
      end
    end)
    
    # Calculate overall accuracy
    total_movies = Enum.sum(Enum.map(decade_results, & &1.total_1001_movies))
    total_correct = Enum.sum(Enum.map(decade_results, & &1.correctly_predicted))
    
    overall_accuracy = if total_movies > 0 do
      Float.round(total_correct / total_movies * 100, 1)
    else
      0.0
    end
    
    aggregated_validation = %{
      decade_results: sanitize_decade_results(decade_results),
      overall_accuracy: overall_accuracy,
      profile_used: profile.name,
      decades_analyzed: length(decades)
    }
    
    # Update the database cache with validation data
    case PredictionCache.get_cached_predictions(2020, profile_id) do
      nil ->
        Logger.warning("No prediction cache found for profile #{profile_id}")
      
      db_cache ->
        updated_metadata = Map.put(db_cache.metadata || %{}, "validation_data", aggregated_validation)
        PredictionCache.upsert_cache(%{
          decade: 2020,
          profile_id: profile_id,
          movie_scores: db_cache.movie_scores,
          statistics: db_cache.statistics,
          calculated_at: db_cache.calculated_at,
          metadata: updated_metadata
        })
        
        # Also cache in memory for fast access
        validation_cache_key = "validation:#{profile.name}:#{profile_hash(profile)}"
        Cachex.put(:predictions_cache, validation_cache_key, aggregated_validation, ttl: :timer.hours(24))
        
        Logger.info("Aggregated and cached validation data, overall accuracy: #{overall_accuracy}%")
    end
    
    :ok
  end
  
  def perform(%Oban.Job{args: %{"action" => "calculate_comparison", "profile_id" => _profile_id}}) do
    Logger.info("Calculating profile comparison")
    
    # Get only ACTIVE profiles to reduce workload
    profiles = ScoringService.get_all_profiles() |> Enum.filter(& &1.active)
    decades = [1920, 1930, 1940, 1950, 1960, 1970, 1980, 1990, 2000, 2010, 2020]
    
    # Use simpler comparison data - just collect what we have cached
    comparison_data = Enum.map(profiles, fn profile ->
      # Only use cached data - don't recalculate
      decade_accuracies = Enum.map(decades, fn decade ->
        cache_key = "validation:#{profile.id}:#{decade}"
        accuracy = case Cachex.get(:predictions_cache, cache_key) do
          {:ok, nil} -> 0.0
          {:ok, result} -> result.accuracy_percentage || 0.0
        end
        {decade, accuracy}
      end)
      |> Map.new()
      
      overall_accuracy = if map_size(decade_accuracies) > 0 do
        Float.round(Enum.sum(Map.values(decade_accuracies)) / map_size(decade_accuracies), 1)
      else
        0.0
      end
      
      %{
        profile_name: profile.name,
        profile_id: profile.id,
        profile_description: profile.description,
        overall_accuracy: overall_accuracy,
        decade_accuracies: decade_accuracies,
        strengths: identify_profile_strengths(decade_accuracies, decades)
      }
    end)
    
    # Find best overall and per decade
    best_overall = Enum.max_by(comparison_data, & &1.overall_accuracy, fn -> nil end)
    
    best_per_decade = Enum.map(decades, fn decade ->
      best = comparison_data
        |> Enum.map(fn data ->
          accuracy = Map.get(data.decade_accuracies, decade, 0.0)
          [data.profile_name, accuracy]
        end)
        |> Enum.max_by(fn [_name, acc] -> acc end, fn -> ["None", 0.0] end)
      
      {decade, best}
    end)
    |> Map.new()
    
    profile_comparison = %{
      profiles: comparison_data,
      best_overall: if best_overall do
        %{
          profile_name: best_overall.profile_name,
          accuracy: best_overall.overall_accuracy,
          description: best_overall.profile_description
        }
      end,
      best_per_decade: best_per_decade,
      insights: %{
        total_decades: length(decades),
        profiles_compared: length(profiles)
      }
    }
    
    # Cache the comparison
    cache_key = "profile_comparison:#{Date.utc_today()}"
    Cachex.put(:predictions_cache, cache_key, profile_comparison, ttl: :timer.hours(24))
    
    # Also update database cache for persistence
    # We'll add it to the default profile's cache
    default_profile = ScoringService.get_default_profile()
    case PredictionCache.get_cached_predictions(2020, default_profile.id) do
      nil ->
        Logger.warning("No prediction cache found for default profile")
      
      db_cache ->
        updated_metadata = Map.put(db_cache.metadata || %{}, "profile_comparison", profile_comparison)
        PredictionCache.upsert_cache(%{
          decade: 2020,
          profile_id: default_profile.id,
          movie_scores: db_cache.movie_scores,
          statistics: db_cache.statistics,
          calculated_at: db_cache.calculated_at,
          metadata: updated_metadata
        })
    end
    
    Logger.info("Successfully calculated and cached profile comparison")
    :ok
  end
  
  @impl Oban.Worker
  def timeout(%Oban.Job{args: %{"action" => "calculate_comparison"}}), do: :timer.seconds(120) # 2 minutes for comparison
  def timeout(_job), do: :timer.seconds(60) # 1 minute timeout for other pieces
  
  # Helper functions
  
  defp profile_hash(profile) do
    profile.category_weights
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:md5, &1))
    |> Base.encode16(case: :lower)
  end
  
  defp calculate_statistics(predictions) do
    scores = Enum.map(predictions, & &1.prediction.likelihood_percentage)
    
    %{
      "total_predictions" => length(predictions),
      "average_score" => calculate_average(scores),
      "median_score" => calculate_median(scores),
      "high_confidence_count" => Enum.count(scores, & &1 >= 80),
      "medium_confidence_count" => Enum.count(scores, & &1 >= 50 and &1 < 80),
      "low_confidence_count" => Enum.count(scores, & &1 < 50),
      "already_added_count" => Enum.count(predictions, & &1.status == :already_added),
      "future_prediction_count" => Enum.count(predictions, & &1.status == :future_prediction)
    }
  end
  
  defp calculate_average([]), do: 0
  defp calculate_average(scores) do
    Float.round(Enum.sum(scores) / length(scores), 2)
  end
  
  defp calculate_median([]), do: 0
  defp calculate_median(scores) do
    sorted = Enum.sort(scores)
    mid = div(length(sorted), 2)
    
    if rem(length(sorted), 2) == 0 do
      Float.round((Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2, 2)
    else
      Float.round(Enum.at(sorted, mid), 2)
    end
  end
  
  defp format_breakdown(breakdown) when is_list(breakdown) do
    Enum.map(breakdown, fn item ->
      %{
        "criterion" => Atom.to_string(item.criterion),
        "raw_score" => to_float(item.raw_score),
        "weight" => to_float(item.weight),
        "weighted_points" => to_float(item.weighted_points)
      }
    end)
  end
  defp format_breakdown(_), do: []
  
  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp to_float(value) when is_number(value), do: value
  defp to_float(nil), do: 0.0
  defp to_float(_), do: 0.0
  
  defp sanitize_decade_results(decade_results) do
    Enum.map(decade_results, &sanitize_decade_result/1)
  end
  
  defp sanitize_decade_result(%{} = result) do
    result
    |> Enum.map(fn {key, value} -> {key, sanitize_value(value)} end)
    |> Map.new()
  end
  defp sanitize_decade_result(result), do: result
  
  defp sanitize_value(%Decimal{} = value), do: Decimal.to_float(value)
  defp sanitize_value(value) when is_list(value), do: Enum.map(value, &sanitize_value/1)
  defp sanitize_value(value) when is_tuple(value) do
    # Convert tuples to lists for JSON compatibility
    value
    |> Tuple.to_list()
    |> Enum.map(&sanitize_value/1)
  end
  defp sanitize_value(%{__struct__: _} = struct) do
    # Handle structs (like Movie) - convert to map and sanitize
    struct
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> {k, sanitize_value(v)} end)
  end
  defp sanitize_value(%{} = value), do: Map.new(value, fn {k, v} -> {k, sanitize_value(v)} end)
  defp sanitize_value(value), do: value
  
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
end