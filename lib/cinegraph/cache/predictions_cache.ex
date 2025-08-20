defmodule Cinegraph.Cache.PredictionsCache do
  @moduledoc """
  High-performance caching system for movie predictions.
  Provides sub-second response times for frequently accessed predictions.
  """

  require Logger

  @cache_name :predictions_cache

  @doc """
  Get or calculate predictions for 2020s movies with caching.
  Cache key includes profile and limit for proper isolation.
  """
  def get_predictions(limit, profile) do
    cache_key = predictions_cache_key(limit, profile)

    case Cachex.get(@cache_name, cache_key) do
      {:ok, nil} ->
        # Cache miss - check database cache only, never calculate inline
        Logger.debug("Cache miss for predictions: limit=#{limit}, profile=#{profile.name}")
        check_database_for_predictions(2020, profile, limit, cache_key)

      {:ok, cached_result} ->
        Logger.debug("Cache hit for predictions: limit=#{limit}, profile=#{profile.name}")
        cached_result

      {:error, reason} ->
        Logger.warning("Cache error for predictions: #{inspect(reason)}")
        # Return nil instead of calculating
        nil
    end
  end

  @doc """
  Get or calculate historical validation with caching.
  """
  def get_validation(profile) do
    cache_key = validation_cache_key(profile)

    case Cachex.get(@cache_name, cache_key) do
      {:ok, nil} ->
        Logger.debug("Cache miss for validation: profile=#{profile.name}")
        # Check database cache only, never calculate inline
        check_database_for_validation(profile, cache_key)

      {:ok, cached_result} ->
        Logger.debug("Cache hit for validation: profile=#{profile.name}")
        cached_result

      {:error, reason} ->
        Logger.warning("Cache error for validation: #{inspect(reason)}")
        # Return nil instead of calculating
        nil
    end
  end

  @doc """
  Get confirmed additions count from the predictions result.
  Since confirmed movies are now integrated into the main predictions list,
  this extracts them for display purposes.
  """
  def get_confirmed_additions_count(predictions_result) do
    predictions_result.predictions
    |> Enum.count(fn prediction -> prediction.status == :already_added end)
  end

  @doc """
  Cache weight profiles for faster access.
  """
  def get_cached_profile(profile_name) when is_binary(profile_name) do
    cache_key = "profile:#{profile_name}"

    case Cachex.get(@cache_name, cache_key) do
      {:ok, nil} ->
        result = Cinegraph.Metrics.ScoringService.get_profile(profile_name)

        if result do
          # Cache profiles for 2 hours (very stable)
          Cachex.put(@cache_name, cache_key, result, ttl: :timer.hours(2))
        end

        result

      {:ok, cached_result} ->
        cached_result

      {:error, _reason} ->
        Cinegraph.Metrics.ScoringService.get_profile(profile_name)
    end
  end

  def get_cached_profile(profile), do: profile

  @doc """
  Get default profile with caching.
  """
  def get_default_profile do
    cache_key = "default_profile"

    case Cachex.get(@cache_name, cache_key) do
      {:ok, nil} ->
        result = Cinegraph.Metrics.ScoringService.get_default_profile()

        if result do
          Cachex.put(@cache_name, cache_key, result, ttl: :timer.hours(2))
        end

        result

      {:ok, cached_result} ->
        cached_result

      {:error, _reason} ->
        Cinegraph.Metrics.ScoringService.get_default_profile()
    end
  end

  @doc """
  Clear all prediction caches. Used when data is updated.
  """
  def clear_all do
    case Cachex.clear(@cache_name) do
      {:ok, count} ->
        Logger.info("Cleared #{count} prediction cache entries")
        :ok

      {:error, reason} ->
        Logger.error("Failed to clear prediction cache: #{inspect(reason)}")
        :error
    end
  end

  @doc """
  Clear caches for a specific profile.
  """
  def clear_profile(profile_name) when is_binary(profile_name) do
    case Cachex.keys(@cache_name) do
      {:ok, keys} when is_list(keys) ->
        keys_to_delete =
          Enum.filter(keys, fn
            k when is_binary(k) ->
              case String.split(k, ":", parts: 4) do
                ["predictions", _limit, ^profile_name, _hash] -> true
                ["validation", ^profile_name, _hash] -> true
                ["profile", ^profile_name] -> true
                _ -> false
              end

            _ ->
              false
          end)

        Enum.each(keys_to_delete, &Cachex.del(@cache_name, &1))

        Logger.info(
          "Cleared #{length(keys_to_delete)} cache entries for profile: #{profile_name}"
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to clear profile cache: #{inspect(reason)}")
        :error
    end
  end

  @doc """
  Get cache status for a profile including last calculation time.
  """
  def get_cache_status(profile) do
    case Cinegraph.Predictions.PredictionCache.get_cached_predictions(2020, profile.id) do
      nil -> 
        %{
          cached: false,
          last_calculated: nil,
          has_validation: false,
          has_predictions: false
        }
      
      db_cache ->
        %{
          cached: true,
          last_calculated: db_cache.calculated_at,
          has_validation: Map.has_key?(db_cache.metadata || %{}, "profile_comparison"),
          has_predictions: map_size(db_cache.movie_scores || %{}) > 0
        }
    end
  end

  @doc """
  Get cache statistics for monitoring.
  """
  def get_stats do
    case Cachex.stats(@cache_name) do
      {:ok, stats} ->
        %{
          hit_rate: calculate_hit_rate(stats),
          total_hits: Map.get(stats, :hit_count, 0),
          total_misses: Map.get(stats, :miss_count, 0),
          total_operations: Map.get(stats, :op_count, 0),
          entry_count: Map.get(stats, :entry_count, 0),
          memory_usage: Map.get(stats, :memory_usage, 0)
        }

      {:error, _reason} ->
        %{
          hit_rate: 0.0,
          total_hits: 0,
          total_misses: 0,
          total_operations: 0,
          entry_count: 0,
          memory_usage: 0
        }
    end
  end

  @doc """
  Get comprehensive profile comparison with caching.
  Compares all profiles across all decades.
  """
  def get_profile_comparison do
    cache_key = "profile_comparison:#{Date.utc_today()}"

    case Cachex.get(@cache_name, cache_key) do
      {:ok, nil} ->
        Logger.debug("Cache miss for profile comparison")
        # Check database cache only, never calculate inline
        check_database_for_profile_comparison(cache_key)

      {:ok, cached_result} ->
        Logger.debug("Cache hit for profile comparison")
        cached_result

      {:error, reason} ->
        Logger.warning("Cache error for profile comparison: #{inspect(reason)}")
        # Return nil instead of calculating
        nil
    end
  end

  @doc """
  Warm up cache with common prediction requests.
  Should be called via Oban background job.
  """
  def warm_cache do
    Logger.info("Starting prediction cache warmup")

    try do
      # Get default profile
      default_profile = get_default_profile()

      if default_profile do
        # Warm up common prediction queries
        get_predictions(100, default_profile)
        get_predictions(50, default_profile)
        get_predictions(200, default_profile)

        # Warm up validation
        get_validation(default_profile)

        # Warm up profile comparison (new!)
        get_profile_comparison()

        Logger.info("Prediction cache warmup completed successfully")
        :ok
      else
        Logger.warning("No default profile found for cache warmup")
        :error
      end
    rescue
      error ->
        Logger.error("Cache warmup failed: #{Exception.format(:error, error, __STACKTRACE__)}")
        :error
    end
  end

  # Private functions

  defp predictions_cache_key(limit, profile) do
    "predictions:#{limit}:#{profile.name}:#{profile_hash(profile)}"
  end

  defp validation_cache_key(profile) do
    "validation:#{profile.name}:#{profile_hash(profile)}"
  end

  # Create a hash of profile weights to detect changes
  defp profile_hash(profile) do
    profile.category_weights
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:md5, &1))
    |> Base.encode16(case: :lower)
  end

  # NOTE: We intentionally DO NOT provide calculate_* functions
  # to prevent accidental inline calculations. All expensive
  # calculations should be done via background Oban jobs only.

  defp check_database_for_predictions(decade, profile, limit, cache_key) do
    # Try to get from database cache
    case Cinegraph.Predictions.PredictionCache.get_cached_predictions(decade, profile.id) do
      nil -> 
        Logger.info("No database cache found for predictions: decade=#{decade}, profile=#{profile.name}")
        nil
      db_cache ->
        # Extract and format the predictions from movie_scores
        if db_cache.movie_scores && map_size(db_cache.movie_scores) > 0 do
          # Convert the cached scores into prediction format
          predictions = 
            db_cache.movie_scores
            |> Enum.map(fn {movie_id_str, score_data} ->
              # Parse movie_id string to integer
              {movie_id, _} = Integer.parse(movie_id_str)
              
              # Get the total score and calculate likelihood percentage
              total_score = Map.get(score_data, "total_score", Map.get(score_data, "score", 0))
              
              # Calculate likelihood percentage from score (0-100 scale)
              # Scores typically range from 0-100, with 50+ being strong candidates
              likelihood = cond do
                total_score >= 90 -> 95
                total_score >= 80 -> 90
                total_score >= 70 -> 85
                total_score >= 60 -> 80
                total_score >= 50 -> 75
                total_score >= 45 -> 70
                total_score >= 40 -> 65
                total_score >= 35 -> 60
                total_score >= 30 -> 55
                total_score >= 25 -> 50
                total_score >= 20 -> 45
                total_score >= 15 -> 40
                total_score >= 10 -> 35
                true -> round(total_score * 3)
              end
              
              # Extract year from release_date for compatibility with MoviePredictor
              year = case Map.get(score_data, "release_date") do
                nil -> nil
                date_str when is_binary(date_str) ->
                  case Date.from_iso8601(date_str) do
                    {:ok, date} -> date.year
                    _ -> nil
                  end
                _ -> nil
              end
              
              # Build prediction structure matching what MoviePredictor returns
              %{
                id: movie_id,
                title: Map.get(score_data, "title", "Unknown"),
                year: year,  # Add year field to match MoviePredictor
                release_date: Map.get(score_data, "release_date"),
                prediction: %{
                  likelihood_percentage: likelihood,
                  score: total_score,
                  total_score: total_score,
                  breakdown: Map.get(score_data, "breakdown", [])
                },
                status: String.to_atom(Map.get(score_data, "status", "future_prediction"))
              }
            end)
            |> Enum.sort_by(& &1.prediction.score, :desc)
            |> Enum.take(limit)

          result = %{
            predictions: predictions,
            total_candidates: map_size(db_cache.movie_scores),
            algorithm_info: Map.get(db_cache.statistics, "algorithm_info", %{})
          }

          # Cache in memory for fast access
          Cachex.put(@cache_name, cache_key, result, ttl: :timer.minutes(30))
          result
        else
          Logger.info("No movie scores in database cache for decade #{decade}")
          nil
        end
    end
  end

  defp check_database_for_validation(profile, cache_key) do
    # Try to get validation data from database cache metadata
    case Cinegraph.Predictions.PredictionCache.get_cached_predictions(2020, profile.id) do
      nil -> 
        Logger.info("No database cache found for validation: profile=#{profile.name}")
        nil
      db_cache ->
        # Check for validation_data in metadata
        validation_data = Map.get(db_cache.metadata || %{}, "validation_data")
        
        if validation_data do
          # Cache in memory for fast access
          Cachex.put(@cache_name, cache_key, validation_data, ttl: :timer.hours(24))
          validation_data
        else
          # Try to extract from profile_comparison if available
          profile_comparison = Map.get(db_cache.metadata || %{}, "profile_comparison")
          
          if profile_comparison do
            # Extract validation data from profile comparison
            profiles = Map.get(profile_comparison, "profiles", [])
            current_profile_data = Enum.find(profiles, fn p -> 
              Map.get(p, "profile_name") == profile.name 
            end)
            
            if current_profile_data do
              # Create validation result from profile comparison data
              decade_accuracies = Map.get(current_profile_data, "decade_accuracies", %{})
              
              decade_results = Enum.map(decade_accuracies, fn {decade, accuracy} ->
                # We don't have individual counts, so estimate based on overall pattern
                estimated_total = case decade do
                  d when d >= 2000 -> 50  # Recent decades have fewer 1001 movies
                  d when d >= 1970 -> 75
                  d when d >= 1950 -> 100
                  _ -> 125
                end
                
                correctly_predicted = round(accuracy * estimated_total / 100)
                
                %{
                  decade: decade,
                  accuracy_percentage: accuracy,
                  correctly_predicted: correctly_predicted,
                  total_1001_movies: estimated_total
                }
              end)
              |> Enum.sort_by(& &1.decade)
              
              validation_result = %{
                overall_accuracy: Map.get(current_profile_data, "overall_accuracy", 0.0),
                decade_results: decade_results,
                profile_used: profile.name,
                decades_analyzed: map_size(decade_accuracies)
              }
              
              # Cache this extracted validation
              Cachex.put(@cache_name, cache_key, validation_result, ttl: :timer.hours(24))
              validation_result
            else
              Logger.info("Profile not found in comparison data")
              nil
            end
          else
            Logger.info("No validation or comparison data in database cache")
            nil
          end
        end
    end
  end

  defp check_database_for_profile_comparison(cache_key) do
    # Try to get from database cache metadata
    default_profile = get_default_profile()
    
    if default_profile do
      case Cinegraph.Predictions.PredictionCache.get_cached_predictions(2020, default_profile.id) do
        nil -> 
          Logger.info("No database cache found for profile comparison")
          nil
        db_cache ->
          comparison = Map.get(db_cache.metadata || %{}, "profile_comparison")
          if comparison do
            # Cache in memory for fast access
            Cachex.put(@cache_name, cache_key, comparison, ttl: :timer.hours(1))
            comparison
          else
            Logger.info("Profile comparison not in database cache")
            nil
          end
      end
    else
      nil
    end
  end

  defp calculate_hit_rate(stats) do
    hits = Map.get(stats, :hit_count, 0)
    misses = Map.get(stats, :miss_count, 0)
    total = hits + misses

    if total > 0 do
      Float.round(hits / total * 100, 2)
    else
      0.0
    end
  end
end
