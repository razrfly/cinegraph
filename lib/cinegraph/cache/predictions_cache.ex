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
  Uses database-backed cache first, then Cachex for hot data.
  """
  def get_predictions(limit, profile) do
    # First try in-memory cache for hot data
    cache_key = predictions_cache_key(limit, profile)

    case Cachex.get(@cache_name, cache_key) do
      {:ok, nil} ->
        # Try database cache for 2020s decade
        decade = 2020
        
        case Cinegraph.Predictions.PredictionCache.get_sorted_predictions(decade, profile.id, limit: limit) do
          [] ->
            # No database cache exists - return error instead of calculating
            Logger.info("No cache available for predictions: decade=#{decade}, profile=#{profile.name}")
            
            # Check if a calculation job is already running
            job_status = check_calculation_job_status(decade, profile.id)
            
            {:error, :cache_missing, job_status}
            
          db_predictions ->
            # Transform DB cache format to expected format
            Logger.debug("DB cache hit for predictions: decade=#{decade}, profile=#{profile.name}")
            
            result = %{
              predictions: transform_db_predictions(db_predictions, limit),
              total_candidates: length(db_predictions),
              algorithm_info: %{
                source: "database_cache",
                cached_at: get_cache_timestamp(decade, profile.id)
              }
            }
            
            # Cache in memory for hot access
            Cachex.put(@cache_name, cache_key, result, ttl: :timer.minutes(15))
            
            result
        end

      {:ok, cached_result} ->
        Logger.debug("Memory cache hit for predictions: limit=#{limit}, profile=#{profile.name}")
        cached_result

      {:error, reason} ->
        Logger.warning("Cache error for predictions: #{inspect(reason)}")
        # Return error instead of calculating
        {:error, :cache_error, reason}
    end
  end
  
  defp transform_db_predictions(db_predictions, limit) do
    db_predictions
    |> Enum.take(limit)
    |> Enum.map(fn movie_data ->
      %{
        id: movie_data.id,
        title: movie_data.title,
        release_date: movie_data.release_date,
        canonical_sources: movie_data.canonical_sources,
        prediction: %{
          likelihood_percentage: round(movie_data.score * 100),
          score: movie_data.score
        },
        status: if(movie_data.canonical_sources && map_size(movie_data.canonical_sources) > 0, 
                   do: :already_added, 
                   else: :predicted)
      }
    end)
  end
  
  defp get_cache_timestamp(decade, profile_id) do
    case Cinegraph.Predictions.PredictionCache.get_cached_predictions(decade, profile_id) do
      nil -> nil
      cache -> cache.calculated_at
    end
  end

  @doc """
  Get or calculate historical validation with caching.
  """
  def get_validation(profile) do
    cache_key = validation_cache_key(profile)

    case Cachex.get(@cache_name, cache_key) do
      {:ok, nil} ->
        Logger.info("No cache available for validation: profile=#{profile.name}")
        # Return error instead of calculating
        {:error, :cache_missing, :no_validation_cache}

      {:ok, cached_result} ->
        Logger.debug("Cache hit for validation: profile=#{profile.name}")
        cached_result

      {:error, reason} ->
        Logger.warning("Cache error for validation: #{inspect(reason)}")
        # Return error instead of calculating
        {:error, :cache_error, reason}
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
        result = calculate_profile_comparison()

        # Cache for 1 hour (comparison is expensive but stable)
        Cachex.put(@cache_name, cache_key, result, ttl: :timer.hours(1))

        result

      {:ok, cached_result} ->
        Logger.debug("Cache hit for profile comparison")
        cached_result

      {:error, reason} ->
        Logger.warning("Cache error for profile comparison: #{inspect(reason)}")
        calculate_profile_comparison()
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

  defp calculate_profile_comparison do
    Cinegraph.Predictions.HistoricalValidator.get_comprehensive_comparison()
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
  
  defp check_calculation_job_status(decade, profile_id) do
    # Check if there's an active or scheduled job for this decade/profile
    import Ecto.Query
    
    job = Cinegraph.Repo.one(
      from j in Oban.Job,
        where: j.worker == "Cinegraph.Workers.PredictionCalculator" and
               j.state in ["available", "executing", "scheduled"] and
               fragment("(? ->> 'decade')::int = ?", j.args, ^decade) and
               fragment("(? ->> 'profile_id')::int = ?", j.args, ^profile_id),
        order_by: [desc: j.inserted_at],
        limit: 1
    )
    
    case job do
      nil -> :no_job_running
      %{state: "executing"} -> :calculating
      %{state: "scheduled"} -> :scheduled
      %{state: "available"} -> :queued
      _ -> :no_job_running
    end
  end
end
