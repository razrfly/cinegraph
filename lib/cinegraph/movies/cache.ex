defmodule Cinegraph.Movies.Cache do
  @moduledoc """
  Caching layer for Movies context to improve performance.

  Phase 1 implementation:
  - Filter options caching (genres, countries, languages, etc.)
  - 1 hour TTL for filter options (data rarely changes)
  - Manual invalidation support

  Phase 2 implementation:
  - Query result caching (search results by parameter hash)
  - Discovery score caching per movie
  - Cache warming for popular queries
  - Smart invalidation on data changes
  """

  require Logger

  @cache_name :movies_cache
  @filter_options_key "filter_options"
  @filter_options_ttl :timer.hours(1)
  @query_results_ttl :timer.minutes(15)
  @discovery_scores_ttl :timer.hours(24)

  @doc """
  Get cached filter options, or fetch and cache if not present.
  Returns the same structure as Search.get_filter_options/0.
  """
  def get_filter_options(fetch_fn) do
    case Cachex.get(@cache_name, @filter_options_key) do
      {:ok, nil} ->
        # Cache miss - fetch and store
        Logger.debug("[Movies.Cache] Filter options cache miss, fetching from database")
        options = fetch_fn.()

        case Cachex.put(@cache_name, @filter_options_key, options, ttl: @filter_options_ttl) do
          {:ok, true} ->
            :ok

          {:error, reason} ->
            Logger.warning("[Movies.Cache] Failed to cache filter options: #{inspect(reason)}")
        end

        options

      {:ok, cached_options} ->
        # Cache hit
        Logger.debug("[Movies.Cache] Filter options cache hit")
        cached_options

      {:error, reason} ->
        # Cache error - fall back to direct fetch
        Logger.warning(
          "[Movies.Cache] Error reading from cache: #{inspect(reason)}, falling back to database"
        )

        fetch_fn.()
    end
  end

  @doc """
  Invalidate the filter options cache.
  Call this when genres, countries, languages, or other filter data is updated.
  """
  def invalidate_filter_options do
    Logger.info("[Movies.Cache] Invalidating filter options cache")
    Cachex.del(@cache_name, @filter_options_key)
  end

  @doc """
  Clear all movies cache entries.
  """
  def clear_all do
    Logger.info("[Movies.Cache] Clearing all movies cache")
    Cachex.clear(@cache_name)
  end

  @doc """
  Get cache statistics for monitoring.
  """
  def stats do
    case Cachex.stats(@cache_name) do
      {:ok, stats} -> stats
      {:error, _} -> %{}
    end
  end

  @doc """
  Get cache size (number of entries).
  """
  def size do
    case Cachex.size(@cache_name) do
      {:ok, size} -> size
      {:error, _} -> 0
    end
  end

  # ============================================================================
  # Phase 2: Query Result Caching
  # ============================================================================

  @doc """
  Get cached search results, or fetch and cache if not present.

  ## Parameters
  - params: Map of search parameters
  - fetch_fn: Function to execute if cache misses

  ## Returns
  {:ok, {movies, meta}} or {:error, reason}
  """
  def get_search_results(params, fetch_fn) do
    cache_key = build_search_cache_key(params)

    case Cachex.get(@cache_name, cache_key) do
      {:ok, nil} ->
        # Cache miss - fetch and store
        Logger.debug("[Movies.Cache] Search results cache miss for key: #{cache_key}")

        case fetch_fn.() do
          {:ok, {movies, meta}} = result ->
            case Cachex.put(@cache_name, cache_key, {movies, meta}, ttl: @query_results_ttl) do
              {:ok, true} ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "[Movies.Cache] Failed to cache search results: #{inspect(reason)}"
                )
            end

            result

          error ->
            error
        end

      {:ok, cached_result} ->
        # Cache hit
        Logger.debug("[Movies.Cache] Search results cache hit for key: #{cache_key}")
        {:ok, cached_result}

      {:error, reason} ->
        # Cache error - fall back to direct fetch
        Logger.warning(
          "[Movies.Cache] Error reading search cache: #{inspect(reason)}, falling back"
        )

        fetch_fn.()
    end
  end

  @doc """
  Build a cache key from search parameters.
  Creates a hash of the parameters to use as cache key.
  """
  def build_search_cache_key(params) do
    # Sort keys for consistent hashing
    sorted_params =
      params
      |> Enum.sort()
      |> Enum.into(%{})

    # Create hash of parameters
    params_hash = :erlang.phash2(sorted_params)
    page = Map.get(params, "page", "1")

    "search:#{params_hash}:page:#{page}"
  end

  @doc """
  Invalidate all search result caches.
  Call this when movie data changes (imports, updates, etc.)
  """
  def invalidate_search_results do
    Logger.info("[Movies.Cache] Invalidating all search result caches")

    # Get all keys that match the search pattern
    case Cachex.keys(@cache_name) do
      {:ok, keys} ->
        search_keys = Enum.filter(keys, &String.starts_with?(&1, "search:"))
        Enum.each(search_keys, fn key -> Cachex.del(@cache_name, key) end)
        {:ok, length(search_keys)}

      {:error, reason} ->
        Logger.error("[Movies.Cache] Error invalidating search results: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Phase 2: Discovery Score Caching
  # ============================================================================

  @doc """
  Get cached discovery scores for a movie.

  ## Parameters
  - movie_id: Integer movie ID
  - fetch_fn: Function to calculate scores if cache misses

  ## Returns
  Map of discovery scores or nil
  """
  def get_discovery_scores(movie_id, fetch_fn) do
    cache_key = "movie:#{movie_id}:discovery_scores"

    case Cachex.get(@cache_name, cache_key) do
      {:ok, nil} ->
        # Cache miss - calculate and store
        Logger.debug("[Movies.Cache] Discovery scores cache miss for movie #{movie_id}")
        scores = fetch_fn.()

        if scores do
          case Cachex.put(@cache_name, cache_key, scores, ttl: @discovery_scores_ttl) do
            {:ok, true} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[Movies.Cache] Failed to cache discovery scores: #{inspect(reason)}"
              )
          end
        end

        scores

      {:ok, cached_scores} ->
        # Cache hit
        Logger.debug("[Movies.Cache] Discovery scores cache hit for movie #{movie_id}")
        cached_scores

      {:error, reason} ->
        # Cache error - fall back to direct calculation
        Logger.warning("[Movies.Cache] Error reading discovery scores cache: #{inspect(reason)}")
        fetch_fn.()
    end
  end

  @doc """
  Put discovery scores for a movie into cache.
  Used when scores are calculated outside the cache layer.
  """
  def put_discovery_scores(movie_id, scores) do
    cache_key = "movie:#{movie_id}:discovery_scores"
    Cachex.put(@cache_name, cache_key, scores, ttl: @discovery_scores_ttl)
  end

  @doc """
  Invalidate discovery scores for specific movies.
  Call this when movie metrics are updated.
  """
  def invalidate_discovery_scores(movie_ids) when is_list(movie_ids) do
    Logger.info("[Movies.Cache] Invalidating discovery scores for #{length(movie_ids)} movies")

    Enum.each(movie_ids, fn movie_id ->
      Cachex.del(@cache_name, "movie:#{movie_id}:discovery_scores")
    end)

    {:ok, length(movie_ids)}
  end

  def invalidate_discovery_scores(movie_id) when is_integer(movie_id) do
    invalidate_discovery_scores([movie_id])
  end

  @doc """
  Invalidate all discovery scores.
  Use when scoring algorithm changes or for full cache refresh.
  """
  def invalidate_all_discovery_scores do
    Logger.info("[Movies.Cache] Invalidating all discovery scores")

    case Cachex.keys(@cache_name) do
      {:ok, keys} ->
        score_keys = Enum.filter(keys, &String.contains?(&1, ":discovery_scores"))
        Enum.each(score_keys, fn key -> Cachex.del(@cache_name, key) end)
        {:ok, length(score_keys)}

      {:error, reason} ->
        Logger.error("[Movies.Cache] Error invalidating discovery scores: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Cache Warming (Phase 2)
  # ============================================================================

  @doc """
  Warm the cache with popular queries.
  This should be called by a background job.

  Returns a list of warmed cache keys.
  """
  def warm_popular_queries(search_fn) do
    Logger.info("[Movies.Cache] Starting cache warming for popular queries")

    popular_queries = [
      # Default homepage view
      %{},
      %{"page" => "1"},

      # Popular sort orders
      %{"sort" => "release_date_desc"},
      %{"sort" => "rating"},
      %{"sort" => "popularity"},
      %{"sort" => "popular_opinion"},

      # Common filters
      %{"decade" => "2020"},
      %{"decade" => "2010"},
      %{"rating_preset" => "highly_rated"}
    ]

    warmed_keys =
      Enum.map(popular_queries, fn params ->
        cache_key = build_search_cache_key(params)

        case search_fn.(params) do
          {:ok, {movies, meta}} ->
            Cachex.put(@cache_name, cache_key, {movies, meta}, ttl: @query_results_ttl)
            cache_key

          {:error, reason} ->
            Logger.warning(
              "[Movies.Cache] Failed to warm cache for #{cache_key}: #{inspect(reason)}"
            )

            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    Logger.info("[Movies.Cache] Cache warming complete: #{length(warmed_keys)} queries warmed")
    warmed_keys
  end
end
